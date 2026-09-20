import XCTest
import KoffeeLidCore

/// Runs the real helper text under `/bin/sh` against a throwaway folder. The three tools it would call on a real Mac
/// (`open`, `ps`, `launchctl`) are stand-ins written by the test, which the helper takes from its environment.
final class UpdateInstallScriptTests: XCTestCase {
    private var root: URL!
    private var destination: URL { root.appendingPathComponent("Applications/Probe.app") }
    private var staged: URL { root.appendingPathComponent("updates/staged/Probe.app") }
    private var backup: URL { root.appendingPathComponent("updates/previous/Probe.app") }
    private var resultFile: URL { root.appendingPathComponent("updates/result") }
    private var logFile: URL { root.appendingPathComponent("updates/install.log") }
    private var calls: URL { root.appendingPathComponent("calls.txt") }
    private var processList: URL { root.appendingPathComponent("ps.txt") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallScriptTests-\(UUID().uuidString)")
        try makeBundle(at: destination, marker: "old")
        try makeBundle(at: staged, marker: "new")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeTool("open", "echo \"open $*\" >> \"$CALLS\"; exit ${OPEN_EXIT:-0}")
        try writeTool("ps", "cat \"$PS_OUTPUT\" 2>/dev/null; exit 0")
        try writeTool("launchctl", "echo \"launchctl $*\" >> \"$CALLS\"; exit ${LAUNCHCTL_EXIT:-0}")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeBundle(at url: URL, marker: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: macOS.appendingPathComponent("Probe"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("Probe").path)
        try marker.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }
    private func writeTool(_ name: String, _ body: String) throws {
        let url = root.appendingPathComponent("tools/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func marker(of bundle: URL) -> String? { try? String(contentsOf: bundle.appendingPathComponent("Contents/marker"), encoding: .utf8) }
    private func recordedCalls() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// A pid nothing runs under any more.
    private func deadPid() throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        return p.processIdentifier
    }
    private func plan(pid: Int32, service: String? = nil) -> UpdateInstallPlan {
        UpdateInstallPlan(pid: pid, destination: destination, staged: staged, backup: backup, resultFile: resultFile, logFile: logFile,
                          executableName: "Probe", version: "1.2.0", launchdService: service, quitWait: 1, launchWait: 1, settle: 0)
    }
    private func run(_ plan: UpdateInstallPlan, newVersionStarts: Bool, environment extra: [String: String] = [:]) throws {
        let script = root.appendingPathComponent("install.sh")
        try UpdateInstallScript.text.write(to: script, atomically: true, encoding: .utf8)
        try (newVersionStarts ? plan.destination.appendingPathComponent("Contents/MacOS/Probe").path + "\n" : "")
            .write(to: processList, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + plan.arguments
        p.environment = ["PATH": "/usr/bin:/bin", "CALLS": calls.path, "PS_OUTPUT": processList.path,
                         "UPDATE_HELPER_OPEN": root.appendingPathComponent("tools/open").path,
                         "UPDATE_HELPER_PS": root.appendingPathComponent("tools/ps").path,
                         "UPDATE_HELPER_LAUNCHCTL": root.appendingPathComponent("tools/launchctl").path].merging(extra) { $1 }
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    private func result() -> UpdateResult? {
        (try? String(contentsOf: resultFile, encoding: .utf8)).flatMap { UpdateResult(line: $0) }
    }

    // MARK: The install

    func testPutsTheNewVersionInPlaceStartsItAndClearsThePreviousOne() throws {
        try run(plan(pid: deadPid()), newVersionStarts: true)
        XCTAssertEqual(marker(of: destination), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(result(), .installed(version: "1.2.0"))
        XCTAssertEqual(recordedCalls(), ["open \(destination.path)"])
    }
    func testTouchesNothingWhileTheAppIsStillRunning() throws {
        try run(plan(pid: getpid()), newVersionStarts: true)
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertEqual(marker(of: staged), "new")
        XCTAssertNil(result(), "the app that never quit is still there to say so itself")
        XCTAssertEqual(recordedCalls(), [])
    }
    func testAMissingNewVersionLeavesThePreviousOneInPlaceAndStartsItAgain() throws {
        try FileManager.default.removeItem(at: staged)
        try run(plan(pid: deadPid()), newVersionStarts: true)
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertEqual(result(), .failed(version: "1.2.0", reason: .replace))
        XCTAssertEqual(recordedCalls(), ["open \(destination.path)"])
    }
    func testANewVersionThatNeverStartsIsRolledBackAndThePreviousOneStarted() throws {
        try run(plan(pid: deadPid()), newVersionStarts: false)
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(result(), .failed(version: "1.2.0", reason: .launch))
        XCTAssertEqual(recordedCalls(), ["open \(destination.path)", "open \(destination.path)"])
    }
    func testANewVersionThatCannotBeOpenedIsRolledBackAtOnce() throws {
        try run(plan(pid: deadPid()), newVersionStarts: true, environment: ["OPEN_EXIT": "1"])
        XCTAssertEqual(marker(of: destination), "old")
        XCTAssertEqual(result(), .failed(version: "1.2.0", reason: .launch))
    }

    // MARK: An app that runs as a launchd job

    func testAJobIsStartedThroughLaunchd() throws {
        try run(plan(pid: deadPid(), service: "gui/501/io.example.agent"), newVersionStarts: true)
        XCTAssertEqual(marker(of: destination), "new")
        XCTAssertEqual(recordedCalls(), ["launchctl kickstart gui/501/io.example.agent"])
    }
    func testAJobLaunchdWillNotStartIsOpenedInstead() throws {
        try run(plan(pid: deadPid(), service: "gui/501/io.example.agent"), newVersionStarts: true, environment: ["LAUNCHCTL_EXIT": "113"])
        XCTAssertEqual(marker(of: destination), "new")
        XCTAssertEqual(recordedCalls(), ["launchctl kickstart gui/501/io.example.agent", "open \(destination.path)"])
        XCTAssertEqual(result(), .installed(version: "1.2.0"))
    }

    // MARK: The result line

    func testResultLinesRoundTrip() {
        for value in [UpdateResult.installed(version: "1.2.0"), .failed(version: "1.2.0", reason: .replace), .failed(version: "1.2.0", reason: .launch)] {
            XCTAssertEqual(UpdateResult(line: value.line + "\n"), value)
        }
        XCTAssertNil(UpdateResult(line: ""))
        XCTAssertNil(UpdateResult(line: "installed"))
        XCTAssertNil(UpdateResult(line: "failed 1.2.0 weather"))
    }

    // MARK: Paths with spaces

    func testPathsWithSpacesSurvive() throws {
        let spaced = root.appendingPathComponent("My Apps/Probe.app")
        try makeBundle(at: spaced, marker: "old")
        var plan = plan(pid: try deadPid())
        plan.destination = spaced
        try run(plan, newVersionStarts: true)
        XCTAssertEqual(marker(of: spaced), "new")
        XCTAssertEqual(recordedCalls(), ["open \(spaced.path)"])
    }
}
