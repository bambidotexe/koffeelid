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
        // Stand-ins for the prefixes that must never run for real in a test.
        try write("bin/sudo", "#!/bin/sh\nexit 0\n")
        try write("bin/caffeinate", "#!/bin/sh\nexit 0\n")
        try write("bin/bash", "#!/bin/sh\nexit 0\n")
        try ShellInit.zsh(hookPath: hook).write(to: dir.appendingPathComponent("init.zsh"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    /// Every hook invocation the commands made, in order, without the load's release of the shell's slot
    /// (`testTheLoadReleasesTheShellsSlot` holds that one).
    func zsh(_ commands: String, preamble: String = "") throws -> [String] {
        var calls = try zshCalls(commands, preamble: preamble)
        if calls.first?.hasPrefix("job end --id zsh-") == true { calls.removeFirst() }
        return calls
    }
    /// Every hook invocation the snippet made, in order, the load's own included, and every line the
    /// script itself wrote to the log.
    func zshCalls(_ commands: String, preamble: String = "") throws -> [String] {
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
    /// The shell's pid, written by the script before it sources the snippet.
    let printPid = #"print -r -- "pid $$" >> $KOFFEELID_LOG"#
    func pid(in calls: [String]) throws -> String {
        try XCTUnwrap(calls.first { $0.hasPrefix("pid ") }).dropFirst(4).description
    }
    func assertEveryBeginIsEnded(_ calls: [String], file: StaticString = #filePath, line: UInt = #line) {
        var open: String?
        for call in calls {
            if call.hasPrefix("job begin") {
                XCTAssertNil(open, "a job began while \(open ?? "") was still open: \(calls)", file: file, line: line)
                open = call
            } else if call.hasPrefix("job end") { open = nil }
        }
        XCTAssertNil(open, "left open: \(calls)", file: file, line: line)
    }
    func testResourcingTheSnippetKeepsTheRunningJob() throws {
        let calls = try zshCalls("source \(dir.appendingPathComponent("init.zsh").path)\ntrue", preamble: printPid)
        let pid = try pid(in: calls)
        let end = "job end --id zsh-\(pid)"
        XCTAssertEqual(calls, ["pid \(pid)",
                               end,                                                       // the first load
                               "job begin --id zsh-\(pid) --pid \(pid) --label source",
                               end,                                                       // the load inside `source`
                               end,                                                       // precmd: the job variable survived
                               "job begin --id zsh-\(pid) --pid \(pid) --label true",
                               end])
    }
    func testTheLoadReleasesTheShellsSlot() throws {
        let calls = try zshCalls("true", preamble: printPid)
        let pid = try pid(in: calls)
        XCTAssertEqual(calls.dropFirst().first, "job end --id zsh-\(pid)", "\(calls)")
        // `exec zsh` keeps the pid, and the new image's first call releases the slot the old one held.
        let snippet = dir.appendingPathComponent("init.zsh").path
        // With `zsh` off the skip list, `exec zsh` begins a job that the old image never ends.
        let exec = try zshCalls("exec /bin/zsh -f -i\n\(printPid)\nsource \(snippet)\ntrue", preamble: "KOFFEELID_SKIP=(vim)\n" + printPid)
        let pids = exec.filter { $0.hasPrefix("pid ") }
        XCTAssertEqual(pids.count, 2, "\(exec)"); XCTAssertEqual(Set(pids).count, 1, "exec keeps the pid: \(exec)")
        XCTAssertEqual(exec.filter { $0.hasPrefix("job begin") && $0.hasSuffix("--label zsh") }.count, 1, "\(exec)")
        let second = try XCTUnwrap(exec.lastIndex { $0.hasPrefix("pid ") })
        XCTAssertEqual(exec.dropFirst(second + 1).first, "job end --id zsh-\(try self.pid(in: exec))", "\(exec)")
        assertEveryBeginIsEnded(exec)
    }
    func testPrefixesAreSkippedBeforeTheHead() throws {
        // `env -i` clears PATH: the stand-in is named by its path, so no real vim ever runs.
        let stub = "'\(dir.appendingPathComponent("bin/vim").path)'"
        for line in ["sudo -n vim", "sudo -n -E vim", "FOO=1 vim", "FOO=1 BAR='a b' vim", "time vim", "env vim", "command vim",
                     "nice vim", "noglob vim", "caffeinate vim", "true && sudo vim", "builtin vim", "nohup vim",
                     "env -i \(stub)", "env -i FOO=1 \(stub)", "env -u HOME vim", "nice -n 10 vim", "caffeinate -i vim",
                     "sudo -u root vim", "sudo --chdir=/tmp vim", "sudo -u root nice -n 5 vim", "exec vim"] {
            XCTAssertEqual(try zsh(line).filter { $0.hasPrefix("job begin") }, [], line)
        }
        for line in ["sudo make", "sudo -u root make"] {
            let make = try zsh(line)
            XCTAssertEqual(make.count, 2, "\(make)"); XCTAssertTrue(make.first?.hasPrefix("job begin") == true, "\(make)")
            XCTAssertTrue(make.first?.contains("--label make") == true, "\(line): \(make)")
        }
        let assigned = try zsh("FOO=1 true")
        XCTAssertTrue(assigned.first?.contains("--label true") == true, "\(assigned)")
    }
    func testALineOfPrefixesAloneBeginsNothing() throws {
        XCTAssertEqual(try zsh("sudo -i"), [], "the root shell it opens is interactive")
        XCTAssertEqual(try zsh("sudo -s"), [])
        XCTAssertEqual(try zsh("sudo -i && true"), [], "the line waits on the root shell")
        XCTAssertEqual(try zsh("FOO=1"), [], "an assignment runs nothing")
    }
    func testAShellCountsOnlyWhenItRunsAScript() throws {
        XCTAssertEqual(try zsh("bash -l"), [], "interactive: every word after it is a flag")
        XCTAssertEqual(try zsh("zsh -f -i"), [])
        XCTAssertEqual(try zsh("bash"), [])
        for (line, label) in [("bash build.sh", "bash"), ("sh -c true", "sh"), ("zsh -f -c true", "zsh"), ("true && bash build.sh", "true")] {
            let calls = try zsh(line)
            XCTAssertEqual(calls.count, 2, "\(line): \(calls)")
            XCTAssertTrue(calls.first?.contains("--label \(label)") == true, "\(line): \(calls)")
        }
        XCTAssertEqual(try zsh("su"), [], "su and login stay plain skips")
        XCTAssertEqual(try zsh("login -f x"), [])
    }
    func testTheSkipListIsTheUsersToReplace() throws {
        XCTAssertEqual(try zsh("true", preamble: "KOFFEELID_SKIP=(true)"), [])
    }
    // MARK: the ~/.zshrc block (pure string logic, no zsh needed)
    /// The block KoffeeLid writes into ~/.zshrc documents how to exclude a command from auto-arm, since the
    /// mechanism (KOFFEELID_SKIP) is otherwise invisible. The line must be shown below the block, where it
    /// extends the shipped defaults instead of pre-seeding and replacing them.
    func testTheBlockDocumentsHowToSkipACommand() throws {
        let added = try XCTUnwrap(ShellInit.zshrcAppending("EVAL_LINE", to: ""))
        XCTAssertTrue(added.contains("KOFFEELID_SKIP+=("), "the block should show the skip syntax")
        XCTAssertTrue(ShellInit.zshrcDescription.contains { $0.contains("KOFFEELID_SKIP") }, "the doc lives in the description, so it is removed with the block")
    }


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
