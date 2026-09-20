import XCTest
import KoffeeLidCore

final class DetachedProcessTests: XCTestCase {
    private func waitForContents(of url: URL, seconds: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") { return text }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func testTheChildRunsInAProcessGroupOfItsOwnWithTheGivenEnvironmentOnly() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("DetachedProcessTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let pid = try DetachedProcess.spawn(executable: "/bin/sh",
                                            arguments: ["-c", "echo \"$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ') $PROBE ${HOME:-nohome}\" > \"$0\"", out.path],
                                            environment: ["PROBE": "seen"])
        let fields = try XCTUnwrap(waitForContents(of: out)).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(Int32(fields[0]), pid, "pgid == its own pid: launchd's sweep of the app's group cannot reach it")
        XCTAssertNotEqual(Int32(fields[0]), getpgrp())
        XCTAssertEqual(fields[1], "seen")
        XCTAssertEqual(fields[2], "nohome", "nothing of the app's environment leaks into the helper")
    }
    func testAMissingExecutableThrows() {
        XCTAssertThrowsError(try DetachedProcess.spawn(executable: "/nonexistent/tool", arguments: [], environment: [:]))
    }
}
