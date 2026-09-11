import XCTest
import KoffeeLidCore

/// The snippet is a contract nothing compiles, so it is exercised in a real interactive zsh against a
/// stub hook binary that records its argv. A string comparison with itself would prove nothing.
final class ShellInitTests: XCTestCase {
    var dir: URL!
    var hook: String { dir.appendingPathComponent("bin/KoffeeLidHook").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try write("bin/KoffeeLidHook", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$KOFFEELID_LOG\"\n")
        try write("bin/vim", "#!/bin/sh\nexit 0\n")
        try ShellInit.zsh(hookPath: hook).write(to: dir.appendingPathComponent("init.zsh"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    /// Every hook invocation the snippet made, in order.
    func zsh(_ commands: String, preamble: String = "") throws -> [String] {
        let log = dir.appendingPathComponent("log")
        try? FileManager.default.removeItem(at: log)
        let script = """
        export KOFFEELID_LOG=\(log.path)
        export PATH=\(dir.appendingPathComponent("bin").path):$PATH
        \(preamble)
        source \(dir.appendingPathComponent("init.zsh").path)
        \(commands)
        """
        try shell(["-f", "-i"], stdin: script)
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    @discardableResult
    func shell(_ arguments: [String], stdin: String) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = arguments
        let input = Pipe(); p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); input.fileHandleForWriting.write(Data(stdin.utf8)); try input.fileHandleForWriting.close(); p.waitUntilExit()
        return p.terminationStatus
    }

    func testSnippetIsValidZshAndCallsTheBinaryByAbsolutePath() throws {
        XCTAssertEqual(try shell(["-n"], stdin: ShellInit.zsh(hookPath: hook)), 0)
        let text = ShellInit.zsh(hookPath: "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook")
        XCTAssertTrue(text.contains("'/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook' job begin"), text)
        XCTAssertFalse(text.contains("command KoffeeLidHook"))
    }
    func testACommandBeginsAndEndsAJobWithTheShellPidAndNoArmAfterByDefault() throws {
        let calls = try zsh("true")
        XCTAssertEqual(calls.count, 2, "\(calls)")
        XCTAssertTrue(calls[0].hasPrefix("job begin --id zsh-"), calls[0])
        XCTAssertTrue(calls[0].contains("--pid "), calls[0]); XCTAssertTrue(calls[0].contains("--label true"), calls[0])
        XCTAssertFalse(calls[0].contains("--arm-after"), "the app applies its own preference when the user set nothing")
        XCTAssertTrue(calls[1].hasPrefix("job end --id zsh-"), calls[1])
    }
    func testArmAfterIsForwardedWhenTheUserSetIt() throws {
        let calls = try zsh("true", preamble: "KOFFEELID_ARM_AFTER=12")
        XCTAssertTrue(calls[0].contains("--arm-after 12"), calls[0])
    }
    func testTheJobIdIsStableForOneShell() throws {
        let ids = try zsh("true\ntrue").compactMap { $0.split(separator: " ").dropFirst(3).first.map(String.init) }
        XCTAssertEqual(Set(ids).count, 1)
    }
    func testInteractiveProgramsAreSkippedWhereverTheySitOnTheLine() throws {
        XCTAssertEqual(try zsh("vim"), [])
        XCTAssertEqual(try zsh("cd '\(dir.path)' && vim"), [])
        XCTAssertEqual(try zsh("'\(dir.appendingPathComponent("bin/vim").path)'"), [], "quotes stripped, basename matched")
        XCTAssertEqual(try zsh("(vim)"), [], "the subshell is not the command")
        XCTAssertEqual(try zsh("true vim").count, 2, "an argument is not a command")
        XCTAssertEqual(try zsh("cd '\(dir.path)' && true").count, 2)
    }
    func testTheSkipListIsTheUsersToReplace() throws {
        XCTAssertEqual(try zsh("true", preamble: "KOFFEELID_SKIP=(true)"), [])
    }
    // MARK: the ~/.zshrc block (pure string logic, no zsh needed)

    let line = #"eval "$(koffeelid shell-init zsh)""#
    var block: String { ([ShellInit.zshrcHeader] + ShellInit.zshrcDescription + [line, ShellInit.zshrcHeader]).joined(separator: "\n") + "\n" }
    let sidepulse = "# ---------- SidePulse ----------\n" + #"command -v sidepulse >/dev/null 2>&1 && eval "$(sidepulse shell-init zsh)""# + "\nSIDEPULSE_SKIP+=(cswap)\n"

    func testANewZshrcStartsAndEndsWithTheHeader() {
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: ""), block)
        XCTAssertTrue(block.hasPrefix("# ---------- KoffeeLid ----------\n")); XCTAssertTrue(block.hasSuffix("\n# ---------- KoffeeLid ----------\n"))
        XCTAssertTrue(block.contains("is removed by"), "the block warns what Remove deletes")
    }
    func testAFileWithoutATrailingNewlineGetsABlankLineFirst() {
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: "export A=1"), "export A=1\n\n" + block)
    }
    func testAFileEndingInANewlineGetsTheSameResult() {
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: "export A=1\n"), "export A=1\n\n" + block)
    }
    func testTheHeaderOrTheOldMarkerMeansAlreadyInstalled() {
        XCTAssertNil(ShellInit.zshrcAppending(line, to: "export A=1\n\n" + block))
        XCTAssertNil(ShellInit.zshrcAppending(line, to: "export A=1\n\n" + ShellInit.zshrcMarker + "\n" + line + "\n"))
    }
    func testACommentedOutEvalLineDoesNotCount() {
        let existing = "# " + line + "\n"
        XCTAssertFalse(ShellInit.zshrcSourcesSnippet(existing))
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: existing), existing + "\n" + block)
    }
    func testAnotherToolsShellInitLineIsNotOurs() {
        XCTAssertFalse(ShellInit.zshrcSourcesSnippet(sidepulse))
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: sidepulse), sidepulse + "\n" + block)
        XCTAssertNil(ShellInit.zshrcRemoving(from: sidepulse), "nothing of ours to remove")
    }
    func testRemovingUndoesAppending() {
        for original in ["", "export A=1", "export A=1\n", "# a comment\nexport A=1\n", sidepulse] {
            let added = ShellInit.zshrcAppending(line, to: original)!
            let expected = original.isEmpty ? "" : (original.hasSuffix("\n") ? original : original + "\n")
            XCTAssertEqual(ShellInit.zshrcRemoving(from: added), expected, "round trip for \(original.debugDescription)")
        }
    }
    func testRemovingLeavesSidePulseAloneWhereverTheBlocksSit() {
        let text = sidepulse + "\n" + block + "\nexport B=2\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text), sidepulse + "\nexport B=2\n")
        let text2 = block + "\n" + sidepulse
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text2), sidepulse)
    }
    func testRemovingTakesEverythingBetweenTheTwoHeaders() {
        let text = "export A=1\n\n" + ShellInit.zshrcHeader + "\n" + line + "\nKOFFEELID_SKIP+=(cswap)\n" + ShellInit.zshrcHeader + "\n\nexport B=2\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text), "export A=1\n\nexport B=2\n", "the block's own comment says so")
    }
    func testRemovingKeepsAForeignLineAfterAnUnclosedHeader() {
        let text = "export A=1\n\n" + ShellInit.zshrcHeader + "\n" + line + "\nexport MINE=1\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text), "export A=1\n\nexport MINE=1\n", "only the header and our line go")
    }
    func testRemovingHandlesTheOldMarkerBlockAndAHandWrittenLine() {
        let old = "export A=1\n\n" + ShellInit.zshrcMarker + "\n" + #"eval "$("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" shell-init zsh)""# + "\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: old), "export A=1\n")
        let hand = "export A=1\n" + line + "\n# " + line + "\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: hand), "export A=1\n# " + line + "\n", "a commented copy stays")
        XCTAssertNil(ShellInit.zshrcRemoving(from: "export A=1\n"), "nothing to remove")
    }
    func testAnUncommentedKoffeeLidEvalLineCountsEvenWithoutTheHeader() {
        let existing = #"eval "$("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" shell-init zsh)""# + "\n"
        XCTAssertTrue(ShellInit.zshrcSourcesSnippet(existing))
        XCTAssertNil(ShellInit.zshrcAppending(line, to: existing))
    }
    func testTheCommandsExitStatusSurvivesOurPrecmd() throws {
        let calls = try zsh("""
        _probe() { printf 'probe %s\\n' "$?" >> $KOFFEELID_LOG }
        add-zsh-hook precmd _probe
        (exit 3)
        """)
        XCTAssertTrue(calls.contains("probe 3"), "\(calls)")
    }
}
