# Auto-arm on Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** KoffeeLid arms itself while a Claude Code session or a terminal command runs, and disarms itself (after a hold-off) once nothing runs, using its own Claude Code hooks and zsh hooks.

**Architecture:** A slim `KoffeeLidHook` tool (Core only, embedded in the bundle) appends trimmed hook events and job begin/end lines to `~/Library/Application Support/KoffeeLid/activity.jsonl`. The app tails that journal into two pure stores (`ActivitySessionStore`, `ActivityJobStore`, ported from MySidepulse's working-verdict rules), and `ActivityArmPolicy` turns the aggregate running/not-running edges into arm/disarm decisions with ownership rules and a hold-off. `KoffeeLidController` gains `ArmSource.activity`.

**Tech Stack:** Swift 5 / SwiftPM (`KoffeeLidCore`, XCTest), Xcode tool target via `project.yml` (xcodegen), AppKit UI via `SettingsForm`, Darwin `sysctl` / kqueue `DispatchSource`.

**Spec:** `docs/superpowers/specs/2026-09-11-activity-auto-arm-design.md` — read it first; every constant and rule below comes from it.

## Global Constraints

- `Sources/KoffeeLidCore` imports **Foundation only** (Darwin is part of Foundation on macOS). No AppKit in Core or in the hook tool.
- Every user-visible string goes through `L("literal key")` and gets an `fr` entry in `App/Resources/Localizable.xcstrings`. No interpolation inside `L()`.
- Treat compiler warnings as failures. `swift build` and `swift test` must stay warning-free; the app is built with `xcodebuild` (see CLAUDE.md "Commands").
- The hook binary **never blocks, never exits non-zero on `hook`, never launches the app**. `KOFFEELID_DISABLE=1` exits immediately.
- Never quit or reinstall `/Applications/KoffeeLid.app` without `"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status` first; `script/install.sh` refuses while armed. Runtime smokes use the Debug build from `DerivedData` with `KOFFEELID_DISABLE_ACTIVITY=1` in its environment.
- Commit subjects `feat|fix|build|docs(scope): …`; every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not push or tag.
- `swift test`, `swift build` and `xcodebuild` write to SwiftPM/Xcode caches under `~/Library`, which the Bash sandbox denies ("Invalid manifest" / "authorization denied"). Run those commands with `dangerouslyDisableSandbox: true`; that is expected on this machine, not a fault.
- Log through `DiagnosticLog.shared.log` in the app; keep the exact log phrasings listed in spec §10.
- Timings (spec §4–6), never retune: helper silence 240 s; hold grace 90 s; hold TTL 30 min; done→idle 20 min; staleness 2 h; idle_prompt min quiet 50 s; abandon quiet 20 s; abandon recheck 15 s; hooks-silent warning 300 s; dialog-answer stamp lead 2 s; job arm-after default 5 s; disarm hold-off default 60 s; hook stdin cap 8 MB; journal line cap 4 KB; metadata clamp 200 chars; background ids 16 × 40 chars; raw prefix 300 chars; label 60 chars; rotation 5 MB idle / 20 MB hard.

## File map

| File | Responsibility |
|---|---|
| `Sources/KoffeeLidCore/ActivityConstants.swift` | every timing/cap above, with its evidence |
| `Sources/KoffeeLidCore/ActivityEvent.swift` | `ActivityEventName`, `ActivityEvent` (Codable, snake_case keys), `ActivityCodec` |
| `Sources/KoffeeLidCore/ActivityTrim.swift` | hook payload → `ActivityEvent`; `cappedLine` |
| `Sources/KoffeeLidCore/ActivityJournalWriter.swift` | one `O_APPEND` write; `readAll` |
| `Sources/KoffeeLidCore/ActivitySessionStore.swift` | per-session state machine (spec §4) |
| `Sources/KoffeeLidCore/ActivityJobStore.swift` | job slots (spec §5) |
| `Sources/KoffeeLidCore/ActivityArmPolicy.swift` | edges → arm/disarm (spec §6) |
| `Sources/KoffeeLidCore/ClaudeRegistryRecord.swift` | parse `<config>/sessions/<pid>.json` |
| `Sources/KoffeeLidCore/HookConfig.swift` | settings.json `hooks` transform |
| `Sources/KoffeeLidCore/HookSettingsFile.swift` | strict load/backup/write of settings.json |
| `Sources/KoffeeLidCore/ShellInit.swift` | zsh snippet template |
| `Sources/KoffeeLidCore/ProcWalk.swift` | sysctl ancestor chain, Claude detection, env read |
| `Sources/KoffeeLidCore/PidFileRecord.swift` | add `AppSupport.activityJournalURL` / `activityJournalRotatedURL` |
| `Hook/Sources/main.swift` | the `KoffeeLidHook` tool |
| `App/Sources/ActivityJournalTailer.swift` | vnode DispatchSource tailer |
| `App/Sources/ActivityProcessWatcher.swift` | kqueue EVFILT_PROC |
| `App/Sources/ClaudeProcessRegistry.swift` | reads the registry file for a pid |
| `App/Sources/ActivityMonitor.swift` | owns stores; replay, tailing, ticks, rotation, registry checks; `onChange` |
| `App/Sources/HookInstaller.swift` | install/uninstall hooks, hook binary path, snippet printing |
| `App/Sources/KoffeeLidController.swift` | `ArmSource.activity`, policy wiring, status line |
| `App/Sources/CommandServer.swift` | CLI verbs `install-hooks`, `uninstall-hooks`, `shell-init zsh` |
| `App/Sources/Preferences.swift` | `armOnActivity`, `activityDisarmHoldOffSeconds`, `activityJobArmAfterSeconds` |
| `App/Sources/UI/SettingsViewController.swift`, `AdvancedViewController.swift` | switch, install controls, sliders, live line |
| `project.yml` | `KoffeeLidHook` tool target, embedded like the watchdog |
| `docs/*.md`, `CLAUDE.md`, `README.md` | documentation |

---

### Task 1: Constants, event type, codec, journal writer

**Files:**
- Create: `Sources/KoffeeLidCore/ActivityConstants.swift`
- Create: `Sources/KoffeeLidCore/ActivityEvent.swift`
- Create: `Sources/KoffeeLidCore/ActivityJournalWriter.swift`
- Modify: `Sources/KoffeeLidCore/PidFileRecord.swift` (add two URLs to `AppSupport`)
- Test: `Tests/KoffeeLidCoreTests/ActivityEventTests.swift`

**Interfaces:**
- Produces: `ActivityConstants` (static lets named below), `ActivityEventName` (raw values are Claude Code's event names plus `ParseError`, `JobBegin`, `JobEnd`), `ActivityEvent(loggedAt:event:)` with optional fields `sessionId, agentId, toolName, notificationType, source, backgroundTaskIds: [String]?, claudePid: Int32?, rawPrefix, jobId, jobPid: Int32?, jobLabel, jobArmAfterSeconds: Double?`, `ActivityCodec.encodeLine(_:) throws -> Data`, `ActivityCodec.decodeLine(_:) -> ActivityEvent?`, `ActivityJournalWriter.append(_ line: Data, to: URL) -> Bool`, `ActivityJournalWriter.readAll(url:) -> [ActivityEvent]`, `AppSupport.activityJournalURL`, `AppSupport.activityJournalRotatedURL`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KoffeeLidCoreTests/ActivityEventTests.swift
import XCTest
import KoffeeLidCore

final class ActivityEventTests: XCTestCase {
    func testRoundTripsEveryFieldWithSnakeCaseKeys() throws {
        var e = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1_700_000_000.25), event: .preToolUse)
        e.sessionId = "s1"; e.agentId = "a1"; e.toolName = "Bash"; e.notificationType = "idle_prompt"
        e.source = "startup"; e.backgroundTaskIds = ["b1"]; e.claudePid = 42; e.rawPrefix = "x"
        e.jobId = "zsh-7"; e.jobPid = 7; e.jobLabel = "make"; e.jobArmAfterSeconds = 5
        let data = try ActivityCodec.encodeLine(e)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"session_id\":\"s1\""), text)
        XCTAssertTrue(text.contains("\"claude_pid\":42"), text)
        XCTAssertTrue(text.contains("\"logged_at\":\"2023-11-14T22:13:20.250Z\""), text)
        XCTAssertFalse(text.contains("\n"), "one line, no newline inside")
        XCTAssertEqual(ActivityCodec.decodeLine(data), e)
    }
    func testUnknownEventNameFailsToDecodeInsteadOfCrashing() {
        XCTAssertNil(ActivityCodec.decodeLine(Data("{\"event\":\"Whatever\",\"logged_at\":\"2023-11-14T22:13:20Z\"}".utf8)))
    }
    func testDecodesDatesWithoutFractionalSeconds() {
        let e = ActivityCodec.decodeLine(Data("{\"event\":\"Stop\",\"logged_at\":\"2023-11-14T22:13:20Z\"}".utf8))
        XCTAssertEqual(e?.event, .stop)
        XCTAssertEqual(e?.loggedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
    func testJournalWriterAppendsOneLinePerCallAndReadAllDecodesThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1), event: .stop)
        let b = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 2), event: .jobBegin)
        XCTAssertTrue(ActivityJournalWriter.append(try ActivityCodec.encodeLine(a), to: url))
        XCTAssertTrue(ActivityJournalWriter.append(try ActivityCodec.encodeLine(b), to: url))
        XCTAssertEqual(ActivityJournalWriter.readAll(url: url), [a, b])
        XCTAssertEqual(ActivityJournalWriter.readAll(url: url.appendingPathExtension("missing")), [])
    }
    func testConstantsKeepTheirCalibratedValues() {
        XCTAssertEqual(ActivityConstants.agentStaleSeconds, 240)
        XCTAssertEqual(ActivityConstants.holdGraceSeconds, 90)
        XCTAssertEqual(ActivityConstants.holdTTLSeconds, 1800)
        XCTAssertEqual(ActivityConstants.staleSeconds, 7200)
        XCTAssertEqual(ActivityConstants.idleSignalMinQuietSeconds, 50)
        XCTAssertEqual(ActivityConstants.abandonQuietSeconds, 20)
        XCTAssertEqual(ActivityConstants.abandonRecheckSeconds, 15)
        XCTAssertEqual(ActivityConstants.jobArmAfterDefaultSeconds, 5)
        XCTAssertEqual(ActivityConstants.disarmHoldOffDefaultSeconds, 60)
        XCTAssertEqual(ActivityConstants.journalLineMaxBytes, 4096)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/Rubens/Projects/koffeelid && swift test --filter ActivityEventTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'ActivityEvent' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ActivityConstants.swift
import Foundation

/// Every timing and cap of the activity feature. The values marked "SidePulse" were sized from a
/// recorded journal of real Claude Code sessions (MySidepulse v1.5.2, 2026-08-26); retune them only
/// against fresh evidence, never from taste.
public enum ActivityConstants {
    // Hook ingestion caps (SidePulse §2).
    public static let hookStdinMaxBytes = 8 * 1024 * 1024
    /// One O_APPEND write of at most this many bytes stays atomic on APFS in practice.
    public static let journalLineMaxBytes = 4096
    public static let metadataMaxChars = 200
    public static let backgroundIdMaxCount = 16
    public static let backgroundIdMaxChars = 40
    public static let rawPrefixMaxChars = 300
    public static let labelMaxChars = 60

    // Session truth (SidePulse §3).
    /// A helper that stops reporting for this long no longer holds a finished turn. Claude Code drops
    /// SubagentStop often (19 of 44 helpers never got one); the longest quiet gap before a real
    /// SubagentStop in the recorded journal was 202.4 s.
    public static let agentStaleSeconds: TimeInterval = 240
    /// After the last helper/background shell clears, a held Stop becomes done this much later.
    public static let holdGraceSeconds: TimeInterval = 90
    /// A held Stop with no event at all for this long becomes done regardless.
    public static let holdTTLSeconds: TimeInterval = 30 * 60
    public static let doneVisibleSeconds: TimeInterval = 20 * 60
    /// A session with no event for this long is dropped.
    public static let staleSeconds: TimeInterval = 2 * 3600
    /// idle_prompt fires ~60 s after a quiet turn (median exactly 60 s); one over fresher main-agent
    /// activity is a glitch. 50 s leaves headroom below 60, not above.
    public static let idleSignalMinQuietSeconds: TimeInterval = 50
    /// Quiet before a working session is checked against Claude Code's registry (Esc/Ctrl-C fire no hook).
    public static let abandonQuietSeconds: TimeInterval = 20
    public static let abandonRecheckSeconds: TimeInterval = 15
    /// Registry busy but no hook for this long: hooks for that session are dead; log once.
    public static let hooksSilentWarnSeconds: TimeInterval = 300
    /// A registry stamp this much newer than a dialog's start means the dialog was answered without a hook.
    public static let dialogAnswerMinStampLeadSeconds: TimeInterval = 2

    // Jobs (SidePulse §7).
    public static let jobStaleSeconds: TimeInterval = 2 * 3600
    /// Commands shorter than this never count (KoffeeLid: never arm).
    public static let jobArmAfterDefaultSeconds: TimeInterval = 5

    // KoffeeLid's own.
    /// Between "nothing runs any more" and the auto-disarm; covers the next prompt being typed.
    public static let disarmHoldOffDefaultSeconds: TimeInterval = 60

    // Journal rotation.
    public static let journalRotateIdleBytes = 5 * 1024 * 1024
    public static let journalRotateHardBytes = 20 * 1024 * 1024
}
```

```swift
// Sources/KoffeeLidCore/ActivityEvent.swift
import Foundation

/// Claude Code hook event names, plus KoffeeLid's own line kinds.
public enum ActivityEventName: String, Codable, Equatable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied", notification = "Notification"
    case stop = "Stop", stopFailure = "StopFailure", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
    case preCompact = "PreCompact", postCompact = "PostCompact"
    case parseError = "ParseError"
    case jobBegin = "JobBegin", jobEnd = "JobEnd"

    /// The 15 Claude Code events the hook subscribes to, in the order `install-hooks` writes them.
    public static let claudeCodeEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .permissionRequest, .permissionDenied, .notification, .stop, .stopFailure, .subagentStart, .subagentStop,
        .preCompact, .postCompact,
    ]
}

/// One trimmed journal line. Bodies (tool input/output, prompts, messages) never reach this type.
public struct ActivityEvent: Codable, Equatable {
    public var loggedAt: Date
    public var event: ActivityEventName
    public var sessionId: String?
    public var agentId: String?
    public var toolName: String?
    public var notificationType: String?
    public var source: String?
    public var backgroundTaskIds: [String]?
    public var claudePid: Int32?
    public var rawPrefix: String?
    public var jobId: String?
    public var jobPid: Int32?
    public var jobLabel: String?
    public var jobArmAfterSeconds: Double?

    public init(loggedAt: Date, event: ActivityEventName) { self.loggedAt = loggedAt; self.event = event }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at", event, sessionId = "session_id", agentId = "agent_id", toolName = "tool_name"
        case notificationType = "notification_type", source, backgroundTaskIds = "background_task_ids"
        case claudePid = "claude_pid", rawPrefix = "raw_prefix", jobId = "job_id", jobPid = "job_pid"
        case jobLabel = "job_label", jobArmAfterSeconds = "job_arm_after_seconds"
    }
}

public enum ActivityCodec {
    static let isoMs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in var c = enc.singleValueContainer(); try c.encode(isoMs.string(from: date)) }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = isoMs.date(from: s) ?? iso.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "unparseable date: \(s)"))
            }
            return date
        }
        return d
    }()
    public static func encodeLine(_ e: ActivityEvent) throws -> Data { try encoder.encode(e) }
    public static func decodeLine(_ data: Data) -> ActivityEvent? { try? decoder.decode(ActivityEvent.self, from: data) }
}
```

```swift
// Sources/KoffeeLidCore/ActivityJournalWriter.swift
import Foundation

public enum ActivityJournalWriter {
    /// One open + one write(2) on an O_APPEND descriptor. Lines are capped upstream, so concurrent hook
    /// processes append atomically in practice. O_CREAT means rotation needs no coordination.
    @discardableResult
    public static func append(_ line: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = line; data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, buf.count)
        }
        return written == data.count
    }

    public static func readAll(url: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { ActivityCodec.decodeLine(Data($0)) }
    }
}
```

Add to `AppSupport` in `Sources/KoffeeLidCore/PidFileRecord.swift`:

```swift
    public static var activityJournalURL: URL { directory.appendingPathComponent("activity.jsonl") }
    public static var activityJournalRotatedURL: URL { directory.appendingPathComponent("activity.1.jsonl") }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ActivityEventTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KoffeeLidCore/ActivityConstants.swift Sources/KoffeeLidCore/ActivityEvent.swift Sources/KoffeeLidCore/ActivityJournalWriter.swift Sources/KoffeeLidCore/PidFileRecord.swift Tests/KoffeeLidCoreTests/ActivityEventTests.swift
git commit -m "feat(activity): journal event type, codec, constants and append-only writer"
```
(append the two attribution lines from Global Constraints to every commit message in this plan.)

---

### Task 2: Hook payload trimming

**Files:**
- Create: `Sources/KoffeeLidCore/ActivityTrim.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivityTrimTests.swift`

**Interfaces:**
- Consumes: `ActivityEvent`, `ActivityCodec`, `ActivityConstants` (Task 1).
- Produces: `ActivityTrim.event(fromHookPayload: Data, loggedAt: Date) -> ActivityEvent`, `ActivityTrim.cappedLine(_ e: ActivityEvent) throws -> Data`, `ActivityTrim.clampLabel(_:) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KoffeeLidCoreTests/ActivityTrimTests.swift
import XCTest
import KoffeeLidCore

final class ActivityTrimTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func payload(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    func testKeepsMetadataDropsBodies() {
        let e = ActivityTrim.event(fromHookPayload: payload([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": String(repeating: "x", count: 100_000)],
            "prompt": "secret", "last_assistant_message": "secret", "agent_id": "a1", "source": "startup",
            "notification_type": "idle_prompt",
        ]), loggedAt: now)
        XCTAssertEqual(e.event, .preToolUse); XCTAssertEqual(e.sessionId, "s1"); XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.agentId, "a1"); XCTAssertEqual(e.source, "startup"); XCTAssertEqual(e.notificationType, "idle_prompt")
        let text = String(decoding: try! ActivityCodec.encodeLine(e), as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertLessThan(text.utf8.count, 400)
    }
    func testClampsMetadataTo200Chars() {
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": String(repeating: "s", count: 500)]), loggedAt: now)
        XCTAssertEqual(e.sessionId?.count, 200)
    }
    func testBackgroundTasksKeepOnlyShellOrUntypedIdsCapped() {
        var tasks: [Any] = [["id": "shell-1", "type": "shell"], ["id": "agent-1", "type": "subagent"], ["task_id": "untyped"], "plain-string"]
        tasks += (0..<20).map { ["id": "extra-\($0)-" + String(repeating: "y", count: 60), "type": "shell"] }
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertTrue(ids.contains("shell-1")); XCTAssertTrue(ids.contains("untyped")); XCTAssertTrue(ids.contains("plain-string"))
        XCTAssertFalse(ids.contains("agent-1"))
        XCTAssertLessThanOrEqual(ids.count, 16)
        XCTAssertTrue(ids.allSatisfy { $0.count <= 40 })
    }
    func testAbsentBackgroundTasksLeavesNil() {
        XCTAssertNil(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s"]), loggedAt: now).backgroundTaskIds)
    }
    func testGarbageBecomesParseErrorWithPrefix() {
        let e = ActivityTrim.event(fromHookPayload: Data(String(repeating: "junk", count: 200).utf8), loggedAt: now)
        XCTAssertEqual(e.event, .parseError); XCTAssertEqual(e.rawPrefix?.count, 300)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Unknown"]), loggedAt: now).event, .parseError)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "JobBegin"]), loggedAt: now).event, .parseError,
                       "our own line kinds must not be injectable through a hook payload")
    }
    func testCappedLineNeverExceeds4KB() throws {
        var e = ActivityEvent(loggedAt: now, event: .stop)
        e.sessionId = String(repeating: "s", count: 200)
        e.rawPrefix = String(repeating: "r", count: 300)
        e.backgroundTaskIds = (0..<16).map { _ in String(repeating: "b", count: 40) }
        e.jobLabel = String(repeating: "l", count: 60)
        XCTAssertLessThanOrEqual(try ActivityTrim.cappedLine(e).count, ActivityConstants.journalLineMaxBytes)
        // A pathological event still yields a decodable line with event + time + session id.
        var huge = e; huge.jobLabel = String(repeating: "L", count: 10_000)
        let line = try ActivityTrim.cappedLine(huge)
        XCTAssertLessThanOrEqual(line.count, ActivityConstants.journalLineMaxBytes)
        XCTAssertEqual(ActivityCodec.decodeLine(line)?.event, .stop)
    }
    func testLabelIsTrimmedTo60() {
        XCTAssertEqual(ActivityTrim.clampLabel(String(repeating: "a", count: 100)).count, 60)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ActivityTrimTests 2>&1 | tail -3` → `cannot find 'ActivityTrim' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ActivityTrim.swift
import Foundation

/// Reduces a raw Claude Code hook payload to one journal line. Bodies are dropped here so the journal
/// stays small and appends stay atomic; every copied string is clamped at ingestion.
public enum ActivityTrim {
    public static func event(fromHookPayload data: Data, loggedAt: Date) -> ActivityEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let event = ActivityEventName(rawValue: name),
              ActivityEventName.claudeCodeEvents.contains(event)
        else {
            var e = ActivityEvent(loggedAt: loggedAt, event: .parseError)
            e.rawPrefix = String(String(decoding: data, as: UTF8.self).prefix(ActivityConstants.rawPrefixMaxChars))
            return e
        }
        var e = ActivityEvent(loggedAt: loggedAt, event: event)
        e.sessionId = clamp(obj["session_id"])
        e.agentId = clamp(obj["agent_id"])
        e.toolName = clamp(obj["tool_name"])
        e.notificationType = clamp(obj["notification_type"])
        e.source = clamp(obj["source"])
        if let tasks = obj["background_tasks"] { e.backgroundTaskIds = taskIds(tasks) }
        return e
    }

    static func clamp(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return String(text.prefix(ActivityConstants.metadataMaxChars))
    }

    public static func clampLabel(_ label: String) -> String { String(label.prefix(ActivityConstants.labelMaxChars)) }

    /// Only background shells hold a turn. Subagents have their own events; monitor-type entries never
    /// report completion, so either would hold the arm long after the turn ended.
    static func taskIds(_ raw: Any) -> [String]? {
        guard let arr = raw as? [Any] else { return nil }
        let n = ActivityConstants.backgroundIdMaxChars
        return arr.prefix(ActivityConstants.backgroundIdMaxCount).compactMap { item -> String? in
            if let s = item as? String { return String(s.prefix(n)) }
            guard let d = item as? [String: Any] else { return nil }
            if let type = d["type"] as? String, type != "shell" { return nil }
            for key in ["id", "task_id", "shell_id", "bash_id"] { if let v = d[key] as? String { return String(v.prefix(n)) } }
            return nil
        }
    }

    /// Encode with a guaranteed cap: full line, then drastic cuts, then a minimal line that always fits.
    public static func cappedLine(_ event: ActivityEvent) throws -> Data {
        let cap = ActivityConstants.journalLineMaxBytes
        var e = event
        var data = try ActivityCodec.encodeLine(e)
        if data.count > cap {
            e.rawPrefix = e.rawPrefix.map { String($0.prefix(100)) }
            e.backgroundTaskIds = e.backgroundTaskIds.map { Array($0.prefix(4)) }
            e.jobLabel = e.jobLabel.map(clampLabel)
            data = try ActivityCodec.encodeLine(e)
        }
        if data.count > cap {
            var minimal = ActivityEvent(loggedAt: event.loggedAt, event: event.event)
            minimal.sessionId = event.sessionId.map { String($0.prefix(64)) }
            minimal.jobId = event.jobId.map { String($0.prefix(64)) }
            data = try ActivityCodec.encodeLine(minimal)
        }
        return data
    }
}
```

- [ ] **Step 4: Run the tests** — `swift test --filter ActivityTrimTests 2>&1 | tail -3` → 7 tests, 0 failures.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ActivityTrim.swift Tests/KoffeeLidCoreTests/ActivityTrimTests.swift && git commit -m "feat(activity): trim hook payloads to capped journal lines"`

---

### Task 3: Session store — event transitions

**Files:**
- Create: `Sources/KoffeeLidCore/ActivitySessionStore.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivitySessionStoreTests.swift`

**Interfaces:**
- Consumes: `ActivityEvent`, `ActivityConstants`.
- Produces: `ActivitySessionState { idle, working, waiting, done }`, `ActivitySession` (fields in spec §4), `ActivitySessionStore` with `sessions: [String: ActivitySession]`, `apply(_ e: ActivityEvent)`, `processExited(pid:)`, `pruneDead(isAlive:)`, `trackedPids: Set<Int32>`, `isRunning: Bool`, `workingCount: Int`. Task 4 adds the time-based API to the same type.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ActivitySessionStoreTests.swift
import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()

    func ev(_ name: ActivityEventName, _ sid: String = "s1", at dt: TimeInterval = 0, tool: String? = nil, agent: String? = nil,
            notif: String? = nil, source: String? = nil, bg: [String]? = nil, pid: Int32? = 100) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: t0.addingTimeInterval(dt), event: name)
        e.sessionId = sid; e.toolName = tool; e.agentId = agent; e.notificationType = notif; e.source = source
        e.backgroundTaskIds = bg; e.claudePid = pid
        return e
    }
    func state(_ sid: String = "s1") -> ActivitySessionState? { store.sessions[sid]?.state }

    func testStartIsIdleAndPromptIsWorking() {
        store.apply(ev(.sessionStart, source: "startup")); XCTAssertEqual(state(), .idle); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 1)); XCTAssertEqual(state(), .working); XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.sessions["s1"]?.claudePid, 100)
    }
    func testCompactionIsWorking() {
        store.apply(ev(.sessionStart, source: "compact")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preCompact, at: 1)); XCTAssertEqual(state(), .working)
        store.apply(ev(.postCompact, at: 2)); XCTAssertEqual(state(), .working)
    }
    func testToolTrafficIsWorkingAndDialogsAreWaiting() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.preToolUse, at: 1, tool: "Bash")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 2, tool: "AskUserQuestion")); XCTAssertEqual(state(), .waiting); XCTAssertFalse(store.isRunning)
        store.apply(ev(.postToolUse, at: 3, tool: "AskUserQuestion")); XCTAssertEqual(state(), .working)
        store.apply(ev(.preToolUse, at: 4, tool: "ExitPlanMode")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.permissionDenied, at: 5)); XCTAssertEqual(state(), .working)
        store.apply(ev(.permissionRequest, at: 6, tool: "Bash")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.postToolUseFailure, at: 7)); XCTAssertEqual(state(), .working)
    }
    func testNotificationDialogsAreWaitingButEchoesKeepTheState() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.notification, at: 1, notif: "permission_prompt")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.preToolUse, at: 2, tool: "Bash")); XCTAssertEqual(state(), .working)
        store.apply(ev(.notification, at: 3, notif: "auth_success")); XCTAssertEqual(state(), .working)
        store.apply(ev(.notification, at: 4, notif: "idle_prompt")); XCTAssertEqual(state(), .working, "too fresh: a glitch, not a lost Stop")
        store.apply(ev(.notification, at: 4 + 50, notif: "idle_prompt")); XCTAssertEqual(state(), .done, "quiet for 50 s: the lost-Stop rescue")
    }
    func testStopIsDoneAndStopFailureIsWaiting() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1)); XCTAssertEqual(state(), .done); XCTAssertFalse(store.isRunning)
        store.apply(ev(.userPromptSubmit, at: 2)); store.apply(ev(.stopFailure, at: 3)); XCTAssertEqual(state(), .waiting)
    }
    func testSessionEndAndProcessExitRemove() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200))
        store.apply(ev(.sessionEnd, at: 1)); XCTAssertNil(store.sessions["s1"]); XCTAssertTrue(store.isRunning)
        store.processExited(pid: 200); XCTAssertTrue(store.sessions.isEmpty); XCTAssertFalse(store.isRunning)
    }
    func testTwoSessionsOneFinishingKeepsRunning() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200))
        store.apply(ev(.stop, at: 1)); XCTAssertTrue(store.isRunning); XCTAssertEqual(store.workingCount, 1)
        store.apply(ev(.stop, "s2", at: 2, pid: 200)); XCTAssertFalse(store.isRunning)
    }
    func testStopWithHelpersOrBackgroundShellsIsHeld() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.subagentStart, at: 1, agent: "a1"))
        store.apply(ev(.stop, at: 2)); XCTAssertEqual(state(), .working, "held behind a live helper"); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.subagentStop, at: 3, agent: "a1")); XCTAssertEqual(state(), .working, "release starts a 90 s grace, not an instant done")
        store = ActivitySessionStore()
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"])); XCTAssertEqual(state(), .working)
        store.apply(ev(.stop, at: 2, bg: [])); XCTAssertEqual(state(), .done, "an empty snapshot on a Stop is a plain finish")
    }
    func testPromptDoesNotClearHelpersButStartupDoes() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.subagentStart, at: 1, agent: "a1"))
        store.apply(ev(.userPromptSubmit, at: 2)); store.apply(ev(.stop, at: 3)); XCTAssertEqual(state(), .working, "helper survives the prompt")
        store.apply(ev(.sessionStart, at: 4, source: "startup")); store.apply(ev(.userPromptSubmit, at: 5)); store.apply(ev(.stop, at: 6))
        XCTAssertEqual(state(), .done, "a process boundary clears helpers")
    }
    func testHelperEventsReopenDoneAndAnswerAgentPermission() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1)); XCTAssertEqual(state(), .done)
        store.apply(ev(.preToolUse, at: 2, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .working); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.permissionRequest, at: 3, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .waiting)
        store.apply(ev(.postToolUse, at: 4, tool: "Bash", agent: "a1")); XCTAssertEqual(state(), .working, "the helper acting again answers its own prompt")
    }
    func testHelperBackgroundSnapshotDoesNotRewriteTheParents() {
        store.apply(ev(.userPromptSubmit))
        store.apply(ev(.postToolUse, at: 1, tool: "Bash", agent: "a1", bg: ["from-helper"]))
        XCTAssertTrue(store.sessions["s1"]!.backgroundIds.isEmpty)
    }
    func testParseErrorAndMissingSessionAreIgnored() {
        store.apply(ev(.parseError)); var e = ev(.stop); e.sessionId = nil; store.apply(e)
        XCTAssertTrue(store.sessions.isEmpty)
    }
    func testPruneDeadDropsOnlyDeadPids() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.userPromptSubmit, "s2", pid: 200)); store.apply(ev(.userPromptSubmit, "s3", pid: nil))
        store.pruneDead(isAlive: { $0 == 100 })
        XCTAssertEqual(Set(store.sessions.keys), ["s1", "s3"]); XCTAssertEqual(store.trackedPids, [100])
    }
}
```

- [ ] **Step 2: Run it to verify it fails** — `swift test --filter ActivitySessionStoreTests 2>&1 | tail -3` → `cannot find 'ActivitySessionStore'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ActivitySessionStore.swift
import Foundation

public enum ActivitySessionState: Equatable { case idle, working, waiting, done }

/// One Claude Code session. Only `.working` counts as running.
public struct ActivitySession: Equatable {
    public var id: String
    public var state: ActivitySessionState = .idle
    public var stateSince: Date
    public var lastEventAt: Date
    /// Last MAIN-agent event (not a helper's, not a Notification): what "the turn has gone quiet" is measured against.
    public var lastMainEventAt: Date
    public var claudePid: Int32?
    /// Helpers believed running, each with its last-seen time; there is no reliable end event.
    public var liveAgents: [String: Date] = [:]
    public var backgroundIds: Set<String> = []
    /// A `done` deferred because helpers or background shells were still out.
    public var pendingDone = false
    public var holdReleasedAt: Date?
    public var waitingFromAgent = false

    public init(id: String, at now: Date) { self.id = id; stateSince = now; lastEventAt = now; lastMainEventAt = now }

    public func hasLiveHelpers(at now: Date) -> Bool {
        liveAgents.values.contains { now.timeIntervalSince($0) < ActivityConstants.agentStaleSeconds }
    }
    public func helperExpiry(after now: Date) -> Date? {
        guard hasLiveHelpers(at: now), let last = liveAgents.values.max() else { return nil }
        return last.addingTimeInterval(ActivityConstants.agentStaleSeconds)
    }
}

/// The per-session state machine (spec §4). Pure: driven by event timestamps and explicit `tick(now:)`,
/// so journal replay and live events share one path.
public struct ActivitySessionStore {
    public private(set) var sessions: [String: ActivitySession] = [:]
    public init() {}

    public var isRunning: Bool { sessions.values.contains { $0.state == .working } }
    public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
    public var trackedPids: Set<Int32> { Set(sessions.values.compactMap(\.claudePid)) }

    public mutating func apply(_ e: ActivityEvent) {
        guard ActivityEventName.claudeCodeEvents.contains(e.event), let sid = e.sessionId else { return }
        let now = e.loggedAt
        if e.event == .sessionEnd { sessions.removeValue(forKey: sid); return }
        var s = sessions[sid] ?? ActivitySession(id: sid, at: now)
        s.lastEventAt = now
        if let pid = e.claudePid { s.claudePid = pid }

        if let agentId = e.agentId {
            // Helper events maintain the registry and never speak for the main agent — except that a helper
            // blocked on a permission blocks the whole turn, and a helper active after `done` re-opens it.
            switch e.event {
            case .subagentStop: s.liveAgents.removeValue(forKey: agentId)
            case .permissionRequest:
                s.liveAgents[agentId] = now; clearPending(&s); set(&s, .waiting, now, fromAgent: true)
            default:
                s.liveAgents[agentId] = now
                if s.state == .waiting, s.waitingFromAgent { set(&s, .working, now) }
                else if s.state == .done { s.pendingDone = true; set(&s, .working, now) }
            }
            updateHoldRelease(&s, now: now); sessions[sid] = s; return
        }

        // Below the helper return on purpose: the snapshot belongs to the main agent.
        if let bg = e.backgroundTaskIds { s.backgroundIds = Set(bg) }
        if e.event != .notification { s.lastMainEventAt = now }

        switch e.event {
        case .sessionStart:
            if e.source != "compact" { s.liveAgents.removeAll(); s.backgroundIds.removeAll() }
            clearPending(&s); set(&s, e.source == "compact" ? .working : .idle, now)
        case .userPromptSubmit, .postToolUse, .postToolUseFailure, .permissionDenied, .preCompact, .postCompact:
            clearPending(&s); set(&s, .working, now)
        case .preToolUse:
            clearPending(&s)
            set(&s, (e.toolName == "AskUserQuestion" || e.toolName == "ExitPlanMode") ? .waiting : .working, now)
        case .permissionRequest, .stopFailure:
            clearPending(&s); set(&s, .waiting, now)
        case .notification:
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                if s.state != .waiting { clearPending(&s); set(&s, .waiting, now) }
            case "idle_prompt", "agent_needs_input":
                // A timer, not a request. Its one use: the machine still believes the turn runs, so the Stop was lost.
                guard s.state == .working, !s.pendingDone,
                      now.timeIntervalSince(s.lastMainEventAt) >= ActivityConstants.idleSignalMinQuietSeconds else { break }
                applyStopVerdict(&s, now: now)
            default: break
            }
        case .stop:
            clearPending(&s); applyStopVerdict(&s, now: now)
        case .sessionEnd, .subagentStart, .subagentStop, .parseError, .jobBegin, .jobEnd:
            break // handled above, or helper shapes without agent_id, which carry no signal
        }
        updateHoldRelease(&s, now: now)
        sessions[sid] = s
    }

    /// The finish line, shared by Stop and the lost-Stop rescues: done if nothing is still out, held otherwise.
    func applyStopVerdict(_ s: inout ActivitySession, now: Date) {
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty { set(&s, .done, now) }
        else { s.pendingDone = true; set(&s, .working, now) }
    }
    func clearPending(_ s: inout ActivitySession) { s.pendingDone = false; s.holdReleasedAt = nil }
    func set(_ s: inout ActivitySession, _ new: ActivitySessionState, _ now: Date, fromAgent: Bool = false) {
        guard s.state != new || new == .waiting else { return }
        s.state = new; s.stateSince = now; s.waitingFromAgent = fromAgent
    }
    func updateHoldRelease(_ s: inout ActivitySession, now: Date) {
        guard s.pendingDone else { return }
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty { if s.holdReleasedAt == nil { s.holdReleasedAt = now } }
        else { s.holdReleasedAt = nil }
    }

    /// The Claude process died: every session it hosted is gone, no SessionEnd required.
    public mutating func processExited(pid: Int32) { sessions = sessions.filter { $0.value.claudePid != pid } }
    /// Startup prune after replay. Sessions without a pid are left to staleness.
    public mutating func pruneDead(isAlive: (Int32) -> Bool) { sessions = sessions.filter { $0.value.claudePid.map(isAlive) ?? true } }
}
```

- [ ] **Step 4: Run the tests** — `swift test --filter ActivitySessionStoreTests 2>&1 | tail -3` → 13 tests, 0 failures.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ActivitySessionStore.swift Tests/KoffeeLidCoreTests/ActivitySessionStoreTests.swift && git commit -m "feat(activity): session state machine — event transitions"`

---

### Task 4: Session store — time rules and registry rescues

**Files:**
- Modify: `Sources/KoffeeLidCore/ActivitySessionStore.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivitySessionStoreTimeTests.swift`

**Interfaces:**
- Produces on `ActivitySessionStore`: `mutating func tick(now: Date)`, `func nextDeadline(after now: Date) -> Date?`, `func abandonCandidates(at now: Date) -> [(sessionId: String, pid: Int32)]`, `mutating func turnOver(sessionId: String, now: Date)`, `mutating func noteBusy(sessionId: String, now: Date)`, `func openWaitCandidates() -> [(sessionId: String, pid: Int32, stateSince: Date)]`, `mutating func dialogAnswered(sessionId: String, now: Date)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ActivitySessionStoreTimeTests.swift
import XCTest
import KoffeeLidCore

final class ActivitySessionStoreTimeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivitySessionStore()
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
    func ev(_ name: ActivityEventName, at dt: TimeInterval = 0, agent: String? = nil, bg: [String]? = nil) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: at(dt), event: name); e.sessionId = "s1"; e.agentId = agent; e.backgroundTaskIds = bg; e.claudePid = 100; return e
    }
    var state: ActivitySessionState? { store.sessions["s1"]?.state }

    func testHelperSilenceReleasesTheHoldThenGraceMakesItDone() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.subagentStart, at: 1, agent: "a1")); store.apply(ev(.stop, at: 2))
        XCTAssertEqual(state, .working)
        store.tick(now: at(1 + 239)); XCTAssertEqual(state, .working, "helper still counts as live")
        store.tick(now: at(1 + 240)); XCTAssertEqual(state, .working, "released (dated to this tick), but inside the 90 s grace")
        XCTAssertEqual(store.nextDeadline(after: at(1 + 240)), at(1 + 240 + 90))
        store.tick(now: at(1 + 240 + 90)); XCTAssertEqual(state, .done); XCTAssertFalse(store.isRunning)
    }
    func testANewHelperReengagesTheHold() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"]))
        store.apply(ev(.postToolUse, at: 2, bg: []))            // main-agent event clears pending: back to plain working
        XCTAssertEqual(state, .working); XCTAssertFalse(store.sessions["s1"]!.pendingDone)
        store.apply(ev(.stop, at: 3, agent: "a1"))               // a helper Stop arrives with no background left: stamped live
        store.apply(ev(.stop, at: 4)); XCTAssertTrue(store.sessions["s1"]!.pendingDone)
        store.tick(now: at(3 + 240)); XCTAssertEqual(state, .working, "helper silent: release dated to this tick")
        store.tick(now: at(3 + 240 + 89)); XCTAssertEqual(state, .working)
        store.tick(now: at(3 + 240 + 90)); XCTAssertEqual(state, .done)
    }
    func testHoldTTLEndsAHeldTurnWithNoEvents() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1, bg: ["b1"]))
        store.tick(now: at(1 + 1799)); XCTAssertEqual(state, .working)
        store.tick(now: at(1 + 1800)); XCTAssertEqual(state, .done)
    }
    func testDoneBecomesIdleAndStaleSessionsVanish() {
        store.apply(ev(.userPromptSubmit)); store.apply(ev(.stop, at: 1))
        store.tick(now: at(1 + 1200)); XCTAssertEqual(state, .idle)
        store.tick(now: at(1 + 7199)); XCTAssertNotNil(store.sessions["s1"])
        store.tick(now: at(1 + 7200)); XCTAssertNil(store.sessions["s1"])
    }
    func testAbandonCandidatesNeedTwentyQuietSecondsAndNoHelpers() {
        store.apply(ev(.userPromptSubmit))
        XCTAssertTrue(store.abandonCandidates(at: at(19)).isEmpty)
        XCTAssertEqual(store.abandonCandidates(at: at(20)).map(\.sessionId), ["s1"])
        XCTAssertEqual(store.abandonCandidates(at: at(20)).map(\.pid), [100])
        store.apply(ev(.subagentStart, at: 21, agent: "a1"))
        XCTAssertTrue(store.abandonCandidates(at: at(60)).isEmpty, "a live helper is not quiet")
        var e = ev(.userPromptSubmit, at: 0); e.sessionId = "nopid"; e.claudePid = nil; store.apply(e)
        XCTAssertFalse(store.abandonCandidates(at: at(100)).contains { $0.sessionId == "nopid" })
    }
    func testTurnOverIsDoneAndNoteBusyExtendsLiveness() {
        store.apply(ev(.userPromptSubmit))
        store.noteBusy(sessionId: "s1", now: at(30))
        XCTAssertTrue(store.abandonCandidates(at: at(40)).isEmpty, "busy re-arms the quiet gate")
        XCTAssertEqual(store.sessions["s1"]?.lastMainEventAt, t0, "hook silence is still measured from the last real event")
        store.tick(now: at(30 + 7199)); XCTAssertNotNil(store.sessions["s1"], "busy keeps a session alive past the original staleness")
        store.turnOver(sessionId: "s1", now: at(60)); XCTAssertEqual(state, .done)
        store.turnOver(sessionId: "s1", now: at(61)); XCTAssertEqual(state, .done, "idempotent, only acts on working")
    }
    func testOpenWaitsCanBeAnsweredWithoutAHook() {
        store.apply(ev(.userPromptSubmit)); var p = ev(.permissionRequest, at: 5); p.toolName = "Bash"; store.apply(p)
        let waits = store.openWaitCandidates()
        XCTAssertEqual(waits.map(\.sessionId), ["s1"]); XCTAssertEqual(waits.first?.stateSince, at(5))
        store.dialogAnswered(sessionId: "s1", now: at(20)); XCTAssertEqual(state, .working)
        XCTAssertTrue(store.openWaitCandidates().isEmpty)
    }
    func testNextDeadlineCoversQuietWatchAndStaleness() {
        store.apply(ev(.userPromptSubmit))
        XCTAssertEqual(store.nextDeadline(after: at(1)), at(20), "first registry check when the quiet gate opens")
        XCTAssertEqual(store.nextDeadline(after: at(25)), at(25 + 15), "then on the recheck cadence")
        store.apply(ev(.stop, at: 30))
        XCTAssertEqual(store.nextDeadline(after: at(31)), at(30 + 1200), "done → idle")
        XCTAssertNil(ActivitySessionStore().nextDeadline(after: t0))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ActivitySessionStoreTimeTests 2>&1 | tail -3` → `has no member 'tick'`.

- [ ] **Step 3: Add the time-based API** (append inside `ActivitySessionStore`)

```swift
    /// Every time-based rule. Call with the wall clock; schedule the next call at `nextDeadline(after:)`.
    public mutating func tick(now: Date) {
        for (id, original) in sessions {
            var s = original
            if s.pendingDone {
                updateHoldRelease(&s, now: now)
                let graceExpired = s.holdReleasedAt.map { now.timeIntervalSince($0) >= ActivityConstants.holdGraceSeconds } ?? false
                let ttlExpired = now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.holdTTLSeconds
                if graceExpired || ttlExpired { clearPending(&s); set(&s, .done, now) }
            }
            if s.state == .done, now.timeIntervalSince(s.stateSince) >= ActivityConstants.doneVisibleSeconds { set(&s, .idle, now) }
            if now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.staleSeconds { sessions.removeValue(forKey: id); continue }
            sessions[id] = s
        }
    }

    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for s in sessions.values {
            if s.pendingDone {
                if let released = s.holdReleasedAt { deadlines.append(released.addingTimeInterval(ActivityConstants.holdGraceSeconds)) }
                if let expiry = s.helperExpiry(after: now) { deadlines.append(expiry) }
                deadlines.append(s.lastEventAt.addingTimeInterval(ActivityConstants.holdTTLSeconds))
            }
            if s.state == .done { deadlines.append(s.stateSince.addingTimeInterval(ActivityConstants.doneVisibleSeconds)) }
            if s.state == .working, !s.pendingDone, s.claudePid != nil {
                let eligibleAt = s.lastEventAt.addingTimeInterval(ActivityConstants.abandonQuietSeconds)
                deadlines.append(eligibleAt > now ? eligibleAt : now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds))
            }
            if s.state == .waiting, s.claudePid != nil { deadlines.append(now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds)) }
            deadlines.append(s.lastEventAt.addingTimeInterval(ActivityConstants.staleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// Working sessions quiet for `abandonQuietSeconds` with nothing out, to be asked about at the source
    /// (Claude Code's registry file). The read lives in the app.
    public func abandonCandidates(at now: Date) -> [(sessionId: String, pid: Int32)] {
        sessions.values.compactMap { s in
            guard s.state == .working, !s.pendingDone, let pid = s.claudePid, !s.hasLiveHelpers(at: now), s.backgroundIds.isEmpty,
                  now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.abandonQuietSeconds else { return nil }
            return (s.id, pid)
        }
    }
    /// The registry says idle, stamped after our last event: the turn is over, however it ended.
    public mutating func turnOver(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working, !s.pendingDone else { return }
        set(&s, .done, now); sessions[sessionId] = s
    }
    /// The registry says busy: Claude is running even though no hook arrived. Liveness only —
    /// `lastMainEventAt` keeps measuring true hook silence.
    public mutating func noteBusy(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working else { return }
        s.lastEventAt = now; sessions[sessionId] = s
    }
    public func openWaitCandidates() -> [(sessionId: String, pid: Int32, stateSince: Date)] {
        sessions.values.compactMap { s in
            guard s.state == .waiting, let pid = s.claudePid else { return nil }
            return (s.id, pid, s.stateSince)
        }
    }
    /// The dialog was answered without a hook (registry busy, stamped after the dialog opened).
    public mutating func dialogAnswered(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .waiting else { return }
        set(&s, .working, now); sessions[sessionId] = s
    }
```

- [ ] **Step 4: Run all store tests** — `swift test --filter 'ActivitySessionStore' 2>&1 | tail -3` → 21 tests, 0 failures. If `testANewHelperReengagesTheHold` disagrees on the exact release instant, fix the test's arithmetic against the store's rule (release is dated to the tick that first sees silence, never backdated) rather than the store.

- [ ] **Step 5: Commit** — `git add -A Sources/KoffeeLidCore/ActivitySessionStore.swift Tests/KoffeeLidCoreTests/ActivitySessionStoreTimeTests.swift && git commit -m "feat(activity): held-Stop release, staleness and registry rescue hooks"`

---

### Task 5: Job store

**Files:**
- Create: `Sources/KoffeeLidCore/ActivityJobStore.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivityJobStoreTests.swift`

**Interfaces:**
- Produces: `ActivityJob { id, ownerPid: Int32?, label: String?, armAfter: Date?, since: Date }`, `ActivityJobStore` with `jobs`, `begin(id:pid:label:armAfterSeconds:now:)`, `end(id:)`, `processExited(pid:)`, `tick(now:)`, `nextDeadline(after:) -> Date?`, `runningCount(at:) -> Int`, `isRunning(at:) -> Bool`, `trackedPids: Set<Int32>`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ActivityJobStoreTests.swift
import XCTest
import KoffeeLidCore

final class ActivityJobStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var store = ActivityJobStore()
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

    func testAJobCountsOnlyAfterItsArmAfter() {
        store.begin(id: "zsh-7", pid: 7, label: "make", armAfterSeconds: 5, now: t0)
        XCTAssertFalse(store.isRunning(at: at(4.9))); XCTAssertEqual(store.runningCount(at: at(4.9)), 0)
        XCTAssertTrue(store.isRunning(at: at(5))); XCTAssertEqual(store.nextDeadline(after: t0), at(5))
        store.begin(id: "x", pid: 8, label: nil, armAfterSeconds: 0, now: t0)
        XCTAssertEqual(store.runningCount(at: t0), 1, "zero arm-after counts immediately")
    }
    func testEndRemovesWhateverTheStatus() {
        store.begin(id: "zsh-7", pid: 7, label: "make", armAfterSeconds: 0, now: t0)
        store.end(id: "zsh-7"); XCTAssertTrue(store.jobs.isEmpty)
        store.end(id: "unknown"); XCTAssertTrue(store.jobs.isEmpty)
    }
    func testANewBeginInTheSameSlotEvictsThePrevious() {
        store.begin(id: "zsh-7", pid: 7, label: "a", armAfterSeconds: 0, now: t0)
        store.begin(id: "zsh-7", pid: 7, label: "b", armAfterSeconds: 0, now: at(1))
        XCTAssertEqual(store.jobs.count, 1); XCTAssertEqual(store.jobs["zsh-7"]?.label, "b")
        store.begin(id: "other-id", pid: 7, label: "c", armAfterSeconds: 0, now: at(2))
        XCTAssertEqual(store.jobs.count, 1, "one job per shell pid, whatever the id"); XCTAssertEqual(store.jobs["other-id"]?.label, "c")
    }
    func testOwnerDeathAndStalenessRemove() {
        store.begin(id: "a", pid: 7, label: nil, armAfterSeconds: 0, now: t0)
        store.begin(id: "b", pid: 8, label: nil, armAfterSeconds: 0, now: t0)
        XCTAssertEqual(store.trackedPids, [7, 8])
        store.processExited(pid: 7); XCTAssertEqual(Set(store.jobs.keys), ["b"])
        store.tick(now: at(7199)); XCTAssertEqual(store.jobs.count, 1)
        store.tick(now: at(7200)); XCTAssertTrue(store.jobs.isEmpty)
    }
    func testNextDeadlineIsTheEarliestOfArmAfterAndStaleness() {
        store.begin(id: "a", pid: 7, label: nil, armAfterSeconds: 5, now: t0)
        XCTAssertEqual(store.nextDeadline(after: t0), at(5))
        XCTAssertEqual(store.nextDeadline(after: at(6)), at(7200))
        XCTAssertNil(ActivityJobStore().nextDeadline(after: t0))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ActivityJobStoreTests 2>&1 | tail -3` → `cannot find 'ActivityJobStore'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ActivityJobStore.swift
import Foundation

/// One terminal command reported by the zsh hooks. Not journaled for replay purposes beyond the
/// current boot; its outcome is irrelevant — only whether it is still running.
public struct ActivityJob: Equatable {
    public var id: String
    /// The shell that owns the job: watched for death, and the eviction slot (one job per shell).
    public var ownerPid: Int32?
    public var label: String?
    /// Not counted until this instant; nil once elapsed.
    public var armAfter: Date?
    public var since: Date
}

public struct ActivityJobStore {
    public private(set) var jobs: [String: ActivityJob] = [:]
    public init() {}

    public mutating func begin(id: String, pid: Int32?, label: String?, armAfterSeconds: Double, now: Date) {
        if let pid { jobs = jobs.filter { $0.value.ownerPid != pid } }
        var job = ActivityJob(id: id, ownerPid: pid, label: label, armAfter: nil, since: now)
        if armAfterSeconds > 0 { job.armAfter = now.addingTimeInterval(armAfterSeconds) }
        jobs[id] = job
    }
    public mutating func end(id: String) { jobs.removeValue(forKey: id) }
    public mutating func processExited(pid: Int32) { jobs = jobs.filter { $0.value.ownerPid != pid } }

    public mutating func tick(now: Date) {
        for (id, original) in jobs {
            var job = original
            if let a = job.armAfter, a <= now { job.armAfter = nil }
            if now.timeIntervalSince(job.since) >= ActivityConstants.jobStaleSeconds { jobs.removeValue(forKey: id); continue }
            jobs[id] = job
        }
    }
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for job in jobs.values {
            if let a = job.armAfter { deadlines.append(a) }
            deadlines.append(job.since.addingTimeInterval(ActivityConstants.jobStaleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }
    public func runningCount(at now: Date) -> Int { jobs.values.filter { ($0.armAfter ?? .distantPast) <= now }.count }
    public func isRunning(at now: Date) -> Bool { runningCount(at: now) > 0 }
    public var trackedPids: Set<Int32> { Set(jobs.values.compactMap(\.ownerPid)) }
}
```

- [ ] **Step 4: Run** — `swift test --filter ActivityJobStoreTests 2>&1 | tail -3` → 5 tests, 0 failures.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ActivityJobStore.swift Tests/KoffeeLidCoreTests/ActivityJobStoreTests.swift && git commit -m "feat(activity): job store with per-shell slots and arm-after"`

---

### Task 6: Arm policy

**Files:**
- Create: `Sources/KoffeeLidCore/ActivityArmPolicy.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivityArmPolicyTests.swift`

**Interfaces:**
- Produces: `ActivityArmAction { arm, disarm }`, `ActivityArmPolicy(holdOff:)` with `var holdOff`, `private(set) var ownsArm, suppressed, lastRunning, disarmAt`, `mutating func update(running: Bool, modeIsOff: Bool, enabled: Bool, now: Date) -> ActivityArmAction?`, `mutating func modeChanged(isOff: Bool, isActivitySource: Bool)`, `mutating func armFailed()`, `mutating func tick(now: Date) -> ActivityArmAction?`, `func nextDeadline(after:) -> Date?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ActivityArmPolicyTests.swift
import XCTest
import KoffeeLidCore

final class ActivityArmPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
    var p = ActivityArmPolicy(holdOff: 60)

    func testRisingEdgeArmsOnlyFromOffAndOnlyWhenEnabled() {
        XCTAssertNil(p.update(running: false, modeIsOff: true, enabled: true, now: t0))
        XCTAssertEqual(p.update(running: true, modeIsOff: true, enabled: true, now: at(1)), .arm)
        XCTAssertNil(p.update(running: true, modeIsOff: false, enabled: true, now: at(2)), "level, not edge")
        var q = ActivityArmPolicy(holdOff: 60)
        XCTAssertNil(q.update(running: true, modeIsOff: false, enabled: true, now: t0), "already armed by the user: nothing")
        var r = ActivityArmPolicy(holdOff: 60)
        XCTAssertNil(r.update(running: true, modeIsOff: true, enabled: false, now: t0), "feature off")
    }
    func testOwnedArmDisarmsAfterHoldOff() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0)
        p.modeChanged(isOff: false, isActivitySource: true); XCTAssertTrue(p.ownsArm)
        XCTAssertNil(p.update(running: false, modeIsOff: false, enabled: true, now: at(10)))
        XCTAssertEqual(p.nextDeadline(after: at(10)), at(70))
        XCTAssertNil(p.tick(now: at(69)))
        XCTAssertEqual(p.tick(now: at(70)), .disarm)
        XCTAssertNil(p.tick(now: at(71)), "fires once")
    }
    func testAResumeInsideTheHoldOffCancelsTheDisarm() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0); p.modeChanged(isOff: false, isActivitySource: true)
        _ = p.update(running: false, modeIsOff: false, enabled: true, now: at(10))
        XCTAssertNil(p.update(running: true, modeIsOff: false, enabled: true, now: at(30)), "still armed, no second arm")
        XCTAssertNil(p.nextDeadline(after: at(30))); XCTAssertNil(p.tick(now: at(100)))
    }
    func testManualChangeHandsTheArmToTheUser() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0); p.modeChanged(isOff: false, isActivitySource: true)
        p.modeChanged(isOff: false, isActivitySource: false)   // user switched Armed → Caffeinate
        XCTAssertFalse(p.ownsArm)
        _ = p.update(running: false, modeIsOff: false, enabled: true, now: at(10))
        XCTAssertNil(p.tick(now: at(1000)), "never disarm what the user owns")
    }
    func testAnUnownedArmIsNeverDisarmed() {
        _ = p.update(running: true, modeIsOff: false, enabled: true, now: t0)   // user was already armed
        _ = p.update(running: false, modeIsOff: false, enabled: true, now: at(10))
        XCTAssertNil(p.tick(now: at(1000)))
    }
    func testManualOffWhileRunningSuppressesUntilTheNextEdge() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0); p.modeChanged(isOff: false, isActivitySource: true)
        p.modeChanged(isOff: true, isActivitySource: false)     // koffeelid off while Claude still works
        XCTAssertTrue(p.suppressed); XCTAssertFalse(p.ownsArm)
        XCTAssertNil(p.update(running: true, modeIsOff: true, enabled: true, now: at(5)), "no re-arm on the level")
        _ = p.update(running: false, modeIsOff: true, enabled: true, now: at(10))
        XCTAssertEqual(p.update(running: true, modeIsOff: true, enabled: true, now: at(20)), .arm, "a fresh edge re-arms")
        XCTAssertFalse(p.suppressed)
    }
    func testActivityOwnDisarmDoesNotSuppress() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0); p.modeChanged(isOff: false, isActivitySource: true)
        _ = p.update(running: false, modeIsOff: false, enabled: true, now: at(1))
        XCTAssertEqual(p.tick(now: at(61)), .disarm); p.modeChanged(isOff: true, isActivitySource: true)
        XCTAssertFalse(p.suppressed)
        XCTAssertEqual(p.update(running: true, modeIsOff: true, enabled: true, now: at(70)), .arm)
    }
    func testABlockedArmWaitsForTheNextEdge() {
        XCTAssertEqual(p.update(running: true, modeIsOff: true, enabled: true, now: t0), .arm)
        p.armFailed()
        XCTAssertNil(p.update(running: true, modeIsOff: true, enabled: true, now: at(15)), "no retry per tick")
        _ = p.update(running: false, modeIsOff: true, enabled: true, now: at(20))
        XCTAssertEqual(p.update(running: true, modeIsOff: true, enabled: true, now: at(30)), .arm)
    }
    func testRailDisarmWhileRunningAlsoSuppresses() {
        _ = p.update(running: true, modeIsOff: true, enabled: true, now: t0); p.modeChanged(isOff: false, isActivitySource: true)
        p.modeChanged(isOff: true, isActivitySource: false)     // low battery disarm
        XCTAssertNil(p.update(running: true, modeIsOff: true, enabled: true, now: at(15)))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ActivityArmPolicyTests 2>&1 | tail -3` → `cannot find 'ActivityArmPolicy'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ActivityArmPolicy.swift
import Foundation

public enum ActivityArmAction: Equatable { case arm, disarm }

/// Turns the aggregate "something is running" level into arm/disarm decisions (spec §6).
/// Edge-triggered: arms on a rising edge from Off; disarms, after `holdOff`, only an arm it owns.
public struct ActivityArmPolicy: Equatable {
    public var holdOff: TimeInterval
    public private(set) var ownsArm = false
    /// Set by a non-activity transition to Off while running, or by a blocked arm: no re-arm until the next rising edge.
    public private(set) var suppressed = false
    public private(set) var lastRunning = false
    public private(set) var disarmAt: Date?

    public init(holdOff: TimeInterval) { self.holdOff = holdOff }

    public mutating func update(running: Bool, modeIsOff: Bool, enabled: Bool, now: Date) -> ActivityArmAction? {
        defer { lastRunning = running }
        if running {
            disarmAt = nil                                  // a resume inside the hold-off cancels the disarm
            guard !lastRunning else { return nil }          // level, not edge
            suppressed = false                              // a fresh edge lifts a manual Off or a blocked arm
            return (modeIsOff && enabled) ? .arm : nil
        }
        if lastRunning, ownsArm { disarmAt = now.addingTimeInterval(holdOff) }
        return nil
    }

    /// Report every mode change with whether the activity source made it.
    public mutating func modeChanged(isOff: Bool, isActivitySource: Bool) {
        if isActivitySource { ownsArm = !isOff; if isOff { disarmAt = nil }; return }
        if isOff, lastRunning { suppressed = true }
        ownsArm = false
        disarmAt = nil
    }

    /// The coordinator refused the arm (battery, thermal, disabled, flag): wait for the next edge.
    public mutating func armFailed() { suppressed = true; ownsArm = false }

    public mutating func tick(now: Date) -> ActivityArmAction? {
        guard let due = disarmAt, now >= due, !lastRunning, ownsArm else { return nil }
        disarmAt = nil
        return .disarm
    }
    public func nextDeadline(after now: Date) -> Date? { disarmAt.flatMap { $0 > now ? $0 : nil } }
}
```

Note: the guard against re-arming after a manual Off or a blocked arm is the level check (`lastRunning`), because arming is edge-triggered by construction. `suppressed` is therefore informational — it is what the status line and the log report ("auto-arm suppressed until the next activity") and it is cleared by the rising edge before the decision. If `testManualOffWhileRunningSuppressesUntilTheNextEdge` fails on the `at(5)` line, the level guard is wrong, not the test.

- [ ] **Step 4: Run** — `swift test --filter ActivityArmPolicyTests 2>&1 | tail -3` → 9 tests, 0 failures.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ActivityArmPolicy.swift Tests/KoffeeLidCoreTests/ActivityArmPolicyTests.swift && git commit -m "feat(activity): edge-triggered arm policy with ownership and hold-off"`

---

### Task 7: settings.json hook transform and strict file IO

**Files:**
- Create: `Sources/KoffeeLidCore/HookConfig.swift`
- Create: `Sources/KoffeeLidCore/HookSettingsFile.swift`
- Test: `Tests/KoffeeLidCoreTests/HookConfigTests.swift`

**Interfaces:**
- Produces: `HookConfig.events: [String]` (15 names), `HookConfig.ourMarker = "/Contents/MacOS/KoffeeLidHook hook"`, `HookConfig.install(into: [String: Any], command: String) -> [String: Any]`, `HookConfig.uninstall(from:) -> [String: Any]`, `HookConfig.installedCommand(in:event:) -> String?`, `HookConfig.installedCount(in:command:) -> Int`; `HookSettingsFile.load(at: URL) throws -> [String: Any]?`, `.backup(from:to:) throws`, `.write(_:to:) throws`, `HookSettingsFile.Failure` (CustomStringConvertible).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/HookConfigTests.swift
import XCTest
import KoffeeLidCore

final class HookConfigTests: XCTestCase {
    let cmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook"
    /// Shaped like a real settings.json with a stranger's hook that must survive untouched.
    var fixture: [String: Any] {
        ["model": "claude-fable-5-1",
         "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff", "timeout": 10]]]]]]
    }
    func commands(_ root: [String: Any], _ event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.flatMap { g -> [String] in
            ((g as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    func testInstallAddsAllFifteenEventsAndKeepsForeignHooks() {
        let out = HookConfig.install(into: fixture, command: cmd)
        XCTAssertEqual(HookConfig.events.count, 15)
        XCTAssertEqual(HookConfig.installedCount(in: out, command: cmd), 15)
        for event in HookConfig.events { XCTAssertEqual(HookConfig.installedCommand(in: out, event: event), cmd, event) }
        XCTAssertTrue(commands(out, "Stop").contains { $0.contains("Glass.aiff") })
        XCTAssertEqual(out["model"] as? String, "claude-fable-5-1")
    }
    func testInstalledEntryHasThePrescribedShape() {
        let out = HookConfig.install(into: [:], command: cmd)
        let groups = (out["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "*")
        let item = (groups[0]["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["type"] as? String, "command"); XCTAssertEqual(item?["command"] as? String, cmd); XCTAssertEqual(item?["timeout"] as? Int, 5)
    }
    func testInstallIsIdempotentAndReplacesAnOlderPath() {
        let old = HookConfig.install(into: fixture, command: "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook")
        let out = HookConfig.install(into: HookConfig.install(into: old, command: cmd), command: cmd)
        XCTAssertEqual(commands(out, "Stop").filter { $0.contains("KoffeeLidHook") }, [cmd])
        XCTAssertEqual(HookConfig.installedCount(in: out, command: cmd), 15)
    }
    func testUninstallRemovesExactlyOurs() {
        let out = HookConfig.uninstall(from: HookConfig.install(into: fixture, command: cmd))
        XCTAssertEqual(HookConfig.installedCount(in: out, command: cmd), 0)
        XCTAssertEqual(commands(out, "Stop"), ["afplay /System/Library/Sounds/Glass.aiff"])
        XCTAssertNil((out["hooks"] as? [String: Any])?["PreToolUse"], "an event left empty is dropped")
        XCTAssertEqual((HookConfig.uninstall(from: ["model": "x"])["model"]) as? String, "x")
    }
    func testDeclinesShapesItDoesNotUnderstand() {
        let weird: [String: Any] = ["hooks": ["Stop": "not-an-array", "PreToolUse": [["hooks": [["type": "command", "command": "x"]]]]]]
        let out = HookConfig.install(into: weird, command: cmd)
        XCTAssertEqual((out["hooks"] as? [String: Any])?["Stop"] as? String, "not-an-array")
        XCTAssertEqual(HookConfig.installedCount(in: out, command: cmd), 14)
        let hooksNotObject: [String: Any] = ["hooks": "nope"]
        XCTAssertEqual(HookConfig.install(into: hooksNotObject, command: cmd)["hooks"] as? String, "nope")
    }
    func testSettingsFileRoundTripBackupAndRefusals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json"), backup = dir.appendingPathComponent("settings.json.backup-koffeelid")
        XCTAssertNil(try HookSettingsFile.load(at: file), "absent file is nil, not an error")
        try HookSettingsFile.write(["a": 1], to: file)
        XCTAssertEqual(try HookSettingsFile.load(at: file)?["a"] as? Int, 1)
        try HookSettingsFile.backup(from: file, to: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try HookSettingsFile.load(at: file)) { XCTAssertTrue("\($0)".contains("not valid JSON"), "\($0)") }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter HookConfigTests 2>&1 | tail -3` → `cannot find 'HookConfig'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/HookConfig.swift
import Foundation

/// Edits the `hooks` object of Claude Code's `~/.claude/settings.json`. Pure dictionary transforms;
/// file IO lives in `HookSettingsFile`. Shapes this code does not understand are left untouched, and the
/// caller counts what actually landed rather than assuming.
public enum HookConfig {
    public static let events: [String] = ActivityEventName.claudeCodeEvents.map(\.rawValue)
    /// Recognises our own entries whatever bundle path they were installed from.
    public static let ourMarker = "/Contents/MacOS/KoffeeLidHook hook"

    public static func install(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        if let existing = root["hooks"], !(existing is [String: Any]) { return root }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooks where value is [Any] { hooks[event] = scrubEventValue(value) }
        for event in events {
            if let existing = hooks[event], !(existing is [Any]) { continue }
            var groups = (hooks[event] as? [Any]) ?? []
            groups.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 5]]] as [String: Any])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public static func uninstall(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks where value is [Any] {
            let scrubbed = scrubEventValue(value)
            if scrubbed.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = scrubbed }
        }
        root["hooks"] = hooks
        return root
    }

    public static func installedCommand(in root: [String: Any], event: String) -> String? {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return nil }
        for case let group as [String: Any] in groups {
            for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                if let command = hook["command"] as? String, command.contains(ourMarker) { return command }
            }
        }
        return nil
    }
    public static func installedCount(in root: [String: Any], command: String) -> Int {
        events.filter { installedCommand(in: root, event: $0) == command }.count
    }

    static func scrubEventValue(_ value: Any) -> [Any] {
        guard let elements = value as? [Any] else { return [] }
        return elements.compactMap { element -> Any? in
            guard let group = element as? [String: Any] else { return element }
            return scrubGroup(group)
        }
    }
    /// Remove our items from one group; a group left empty is dropped; unknown shapes pass through.
    static func scrubGroup(_ group: [String: Any]) -> [String: Any]? {
        guard let items = group["hooks"] as? [Any] else { return group }
        let kept = items.filter { item in
            guard let hook = item as? [String: Any], let command = hook["command"] as? String else { return true }
            return !command.contains(ourMarker)
        }
        if kept.isEmpty { return nil }
        var group = group; group["hooks"] = kept; return group
    }
}
```

```swift
// Sources/KoffeeLidCore/HookSettingsFile.swift
import Foundation

/// Reading and writing Claude Code's settings.json. Strict on purpose: the file belongs to the user and
/// holds configuration this project knows nothing about, so every ambiguous case is an error, not a guess.
public enum HookSettingsFile {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String), unparseable, backupFailed(String), writeFailed(String)
        public var description: String {
            switch self {
            case .unreadable(let why): return "could not read settings: \(why)"
            case .unparseable: return "settings file exists but is not valid JSON; refusing to touch it"
            case .backupFailed(let why): return "could not write a backup: \(why)"
            case .writeFailed(let why): return "could not write settings: \(why)"
            }
        }
    }
    /// nil when the file does not exist; throws when it exists but cannot be read or parsed.
    public static func load(at path: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw Failure.unreadable(error.localizedDescription) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unparseable }
        return root
    }
    public static func backup(from path: URL, to backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.removeItem(at: backupPath)
        do { try FileManager.default.copyItem(at: path, to: backupPath) } catch { throw Failure.backupFailed(error.localizedDescription) }
    }
    public static func write(_ root: [String: Any], to path: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        } catch { throw Failure.writeFailed(error.localizedDescription) }
    }
}
```

- [ ] **Step 4: Run** — `swift test --filter HookConfigTests 2>&1 | tail -3` → 6 tests, 0 failures.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/HookConfig.swift Sources/KoffeeLidCore/HookSettingsFile.swift Tests/KoffeeLidCoreTests/HookConfigTests.swift && git commit -m "feat(activity): Claude Code settings.json hook transform and strict file IO"`

---

### Task 8: zsh snippet, tested in a real zsh

**Files:**
- Create: `Sources/KoffeeLidCore/ShellInit.swift`
- Test: `Tests/KoffeeLidCoreTests/ShellInitTests.swift`

**Interfaces:**
- Produces: `ShellInit.zsh(hookPath: String) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ShellInitTests.swift
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
    func testTheCommandsExitStatusSurvivesOurPrecmd() throws {
        let calls = try zsh("""
        _probe() { printf 'probe %s\\n' "$?" >> $KOFFEELID_LOG }
        add-zsh-hook precmd _probe
        (exit 3)
        """)
        XCTAssertTrue(calls.contains("probe 3"), "\(calls)")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ShellInitTests 2>&1 | tail -3` → `cannot find 'ShellInit'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ShellInit.swift
import Foundation

/// Printed by `koffeelid shell-init zsh` for `eval` in .zshrc. Held to behavioural tests in a real zsh.
public enum ShellInit {
    static let hookPlaceholder = "@KOFFEELID_HOOK@"

    /// The snippet calls the hook binary by absolute path: PATH is not ours to trust.
    public static func zsh(hookPath: String) -> String {
        zshTemplate.replacingOccurrences(of: hookPlaceholder, with: hookPath)
    }

    static let zshTemplate = #"""
# KoffeeLid: arm while a terminal command runs. Set KOFFEELID_SKIP (array of program names never
# tracked) or KOFFEELID_ARM_AFTER (seconds a command must run before it counts) before this line.
typeset -ga KOFFEELID_SKIP
(( ${#KOFFEELID_SKIP} )) || KOFFEELID_SKIP=(
  vi vim nvim emacs nano pico less more man info
  ssh mosh tmux screen top htop btop watch
  claude codex grok koffeelid
)
typeset -g _koffeelid_job=

_koffeelid_preexec() {
  # $3 is the command line after alias expansion. Collect the head of every segment (split on
  # && || | |& ; & and the group characters), quotes stripped, basename taken: a launcher's
  # `cd '<dir>' && '<path>/vim'` must match on vim, and `(vim)` on vim, not on `(`.
  local -a words heads
  words=(${(z)3})
  local word head=
  for word in $words; do
    case $word in
      '&&'|'||'|'|'|'|&'|';'|'&'|'('|')'|'{'|'}') head= ;;
      *) [[ -n $head ]] || { head=${${(Q)word}:t}; heads+=($head) } ;;
    esac
  done
  # One skipped head skips the whole line: the shell waits on the interactive program wherever it sits.
  for head in $heads; do
    (( ${KOFFEELID_SKIP[(I)$head]} )) && return
  done
  local name=${heads[1]:-${${(Q)words[1]}:t}}
  local -a extra
  [[ -n ${KOFFEELID_ARM_AFTER-} ]] && extra=(--arm-after $KOFFEELID_ARM_AFTER)
  _koffeelid_job=zsh-$$
  '@KOFFEELID_HOOK@' job begin --id $_koffeelid_job --pid $$ --label $name $extra >/dev/null 2>&1
}

_koffeelid_precmd() {
  # First statement: $? is the command's status, and later precmd hooks expect to see it.
  local code=$?
  if [[ -n $_koffeelid_job ]]; then
    '@KOFFEELID_HOOK@' job end --id $_koffeelid_job >/dev/null 2>&1
    _koffeelid_job=
  fi
  return $code
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _koffeelid_preexec
add-zsh-hook precmd _koffeelid_precmd
"""#
}
```

- [ ] **Step 4: Run** — `swift test --filter ShellInitTests 2>&1 | tail -3` → 7 tests, 0 failures. These tests spawn `/bin/zsh -f -i`; if the sandbox refuses, run them once outside it and note that in the commit body.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ShellInit.swift Tests/KoffeeLidCoreTests/ShellInitTests.swift && git commit -m "feat(activity): zsh preexec/precmd snippet with skip list, tested in a real zsh"`

---

### Task 9: Process walk and registry record parsing

**Files:**
- Create: `Sources/KoffeeLidCore/ProcWalk.swift`
- Create: `Sources/KoffeeLidCore/ClaudeRegistryRecord.swift`
- Test: `Tests/KoffeeLidCoreTests/ProcWalkTests.swift`

**Interfaces:**
- Produces: `ProcWalk.ProcInfo { pid, ppid, name, path }`, `ProcWalk.info(for:) -> ProcInfo?`, `ProcWalk.chain(from: Int32, maxHops: Int = 15) -> [ProcInfo]`, `ProcWalk.environmentValue(_ name: String, forPid:) -> String?`, `ProcWalk.isClaudePath(_:) -> Bool`, `ProcWalk.isClaudeProcess(_:) -> Bool`, `ProcWalk.claudePid(inChainFrom: Int32) -> Int32?`, `ProcWalk.looksLikeClaude(pid:) -> Bool`, `ProcWalk.isAlive(pid:) -> Bool`; `ClaudeRegistryRecord { sessionId, status, statusUpdatedAt; isIdle, isBusy }`, `ClaudeRegistryRecord.parse(_ data: Data, expectedPid: Int32) -> ClaudeRegistryRecord?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KoffeeLidCoreTests/ProcWalkTests.swift
import XCTest
import KoffeeLidCore

final class ProcWalkTests: XCTestCase {
    func testChainStartsWithSelfAndWalksToTheParent() {
        let chain = ProcWalk.chain(from: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertEqual(chain.dropFirst().first?.pid, getppid())
        XCTAssertTrue(chain.count >= 2)
    }
    func testEnvironmentValueReadsAnotherProcessEnvironmentOrOurOwn() {
        setenv("KOFFEELID_PROCWALK_PROBE", "hello-42", 1)
        XCTAssertEqual(ProcWalk.environmentValue("KOFFEELID_PROCWALK_PROBE", forPid: getpid()), "hello-42")
        XCTAssertNil(ProcWalk.environmentValue("KOFFEELID_NOT_SET_ANYWHERE", forPid: getpid()))
    }
    func testClaudePathShapes() {
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/bin/claude"))
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/share/claude/versions/2.1.246"))
        XCTAssertFalse(ProcWalk.isClaudePath("/usr/bin/zsh"))
        XCTAssertFalse(ProcWalk.isClaudePath("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "claude", path: nil)))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "2.1.246", path: "/x/claude/versions/2.1.246")))
        XCTAssertFalse(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "node", path: "/usr/local/bin/node")))
    }
    func testNoClaudeInAnOrdinaryChainAndAliveness() {
        // Run from a plain terminal the chain has no Claude; run from inside a Claude Code shell it does.
        // Either way the answer must be consistent with the per-process check.
        if let pid = ProcWalk.claudePid(inChainFrom: getpid()) { XCTAssertTrue(ProcWalk.looksLikeClaude(pid: pid)) }
        XCTAssertTrue(ProcWalk.isAlive(pid: getpid())); XCTAssertFalse(ProcWalk.isAlive(pid: 2_000_000))
    }
    func testRegistryRecordParsesAndRefusesOtherPids() {
        let json = Data("{\"pid\": 555, \"sessionId\": \"s1\", \"status\": \"busy\", \"statusUpdatedAt\": 1700000000250}".utf8)
        let r = ClaudeRegistryRecord.parse(json, expectedPid: 555)
        XCTAssertEqual(r?.sessionId, "s1"); XCTAssertEqual(r?.isBusy, true); XCTAssertEqual(r?.isIdle, false)
        XCTAssertEqual(r?.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_000.25))
        XCTAssertNil(ClaudeRegistryRecord.parse(json, expectedPid: 556), "a recycled pid's file must read as no record")
        XCTAssertEqual(ClaudeRegistryRecord.parse(Data("{\"pid\": 1, \"status\": \"idle\"}".utf8), expectedPid: 1)?.isIdle, true)
        XCTAssertEqual(ClaudeRegistryRecord.parse(Data("{\"pid\": 1, \"status\": \"resting\"}".utf8), expectedPid: 1)?.isIdle, false, "unknown statuses are neither")
        XCTAssertNil(ClaudeRegistryRecord.parse(Data("nope".utf8), expectedPid: 1))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ProcWalkTests 2>&1 | tail -3` → `cannot find 'ProcWalk'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/KoffeeLidCore/ProcWalk.swift
import Foundation

/// Reads the process ancestor chain via sysctl — microseconds, no subprocesses. Used by the hook to find
/// the Claude Code process it runs under, and by the app to prune sessions whose pid died or was recycled.
public enum ProcWalk {
    public struct ProcInfo: Equatable {
        public let pid: Int32, ppid: Int32, name: String, path: String?
        public init(pid: Int32, ppid: Int32, name: String, path: String?) { self.pid = pid; self.ppid = ppid; self.name = name; self.path = path }
    }

    public static func info(for pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return ProcInfo(pid: pid, ppid: proc.kp_eproc.e_ppid, name: name, path: length > 0 ? String(cString: buffer) : nil)
    }

    public static func chain(from pid: Int32, maxHops: Int = 15) -> [ProcInfo] {
        var out: [ProcInfo] = []; var current = pid
        while out.count < maxHops, current > 1, let info = info(for: current) { out.append(info); current = info.ppid }
        return out
    }

    /// The KERN_PROCARGS2 buffer: argc, exec path, NULs, argv strings, then KEY=VALUE environment strings.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]; var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// The exec path as recorded (a symlink launcher shows the symlink, unlike proc_pidpath).
    static func execPath(for pid: Int32) -> String? {
        guard let buffer = procArgs(pid) else { return nil }
        let start = MemoryLayout<Int32>.size; var end = start
        while end < buffer.count, buffer[end] != 0 { end += 1 }
        guard end > start else { return nil }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    /// One variable from a same-user process's environment (CLAUDE_CONFIG_DIR: the registry dir is per account).
    public static func environmentValue(_ name: String, forPid pid: Int32) -> String? {
        guard let buffer = procArgs(pid) else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer.prefix(MemoryLayout<Int32>.size)) }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // exec path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var remaining = argc
        while remaining > 0, index < buffer.count {                      // argv
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1; remaining -= 1
        }
        let prefix = Array("\(name)=".utf8)
        while index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            if end == index { break }                                    // double NUL: past the environment
            if buffer[index..<end].starts(with: prefix) { return String(decoding: buffer[(index + prefix.count)..<end], as: UTF8.self) }
            index = end + 1
        }
        return nil
    }

    /// Both real install shapes: the launcher `~/.local/bin/claude` and the versioned target
    /// `~/.local/share/claude/versions/<version>` (whose p_comm is the version string).
    public static func isClaudePath(_ path: String) -> Bool {
        path.hasSuffix("/claude") || path.split(separator: "/").contains("claude")
    }
    public static func isClaudeProcess(_ info: ProcInfo) -> Bool {
        if info.name == "claude" { return true }
        if let path = info.path, isClaudePath(path) { return true }
        if let argv0 = execPath(for: info.pid), isClaudePath(argv0) { return true }
        return false
    }
    /// The nearest Claude Code ancestor of `pid` (inclusive), or nil.
    public static func claudePid(inChainFrom pid: Int32) -> Int32? { chain(from: pid).first(where: isClaudeProcess)?.pid }
    /// kill(0) proves a process, not THE process: a pid recycled while the app was down must not keep a dead session alive.
    public static func looksLikeClaude(pid: Int32) -> Bool { info(for: pid).map(isClaudeProcess) ?? false }
    public static func isAlive(pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
```

```swift
// Sources/KoffeeLidCore/ClaudeRegistryRecord.swift
import Foundation

/// Claude Code's own per-process record, `<config>/sessions/<pid>.json`: `status` is "busy" while a turn
/// runs and "idle" at the prompt. The one signal about a turn that does not travel through hooks.
public struct ClaudeRegistryRecord: Equatable {
    public let sessionId: String?
    public let status: String?
    public let statusUpdatedAt: Date?
    /// Strictly "idle" / "busy": values a future Claude Code adds must read as neither.
    public var isIdle: Bool { status == "idle" }
    public var isBusy: Bool { status == "busy" }

    public static func parse(_ data: Data, expectedPid: Int32) -> ClaudeRegistryRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["pid"] as? Int == Int(expectedPid) else { return nil }
        let ms = (object["statusUpdatedAt"] as? Double) ?? (object["statusUpdatedAt"] as? Int).map(Double.init)
        return ClaudeRegistryRecord(sessionId: object["sessionId"] as? String, status: object["status"] as? String,
                                    statusUpdatedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }
}
```

- [ ] **Step 4: Run** — `swift test --filter ProcWalkTests 2>&1 | tail -3` → 5 tests, 0 failures. Then the whole suite: `swift test 2>&1 | tail -3` → 0 failures, no warnings.

- [ ] **Step 5: Commit** — `git add Sources/KoffeeLidCore/ProcWalk.swift Sources/KoffeeLidCore/ClaudeRegistryRecord.swift Tests/KoffeeLidCoreTests/ProcWalkTests.swift && git commit -m "feat(activity): sysctl process walk, Claude detection and registry record parsing"`

---

### Task 10: The hook binary and its target

**Files:**
- Create: `Hook/Sources/main.swift`
- Modify: `project.yml` (new `KoffeeLidHook` tool target, embedded in the app like `KoffeeLidWatchdog`)
- Modify: `script/install.sh` (pkill line for the hook is **not** needed — hooks are short-lived; nothing to change unless the build path changes)

**Interfaces:**
- Consumes: `ActivityTrim`, `ActivityJournalWriter`, `ActivityEvent`, `ProcWalk`, `AppSupport.activityJournalURL`, `ActivityConstants`.
- Produces: an executable `KoffeeLid.app/Contents/MacOS/KoffeeLidHook` with verbs `hook`, `job begin --id ID --pid PID [--label TEXT] [--arm-after SECONDS]`, `job end --id ID`.

- [ ] **Step 1: Add the target to `project.yml`** (insert before `KoffeeLid:` under `targets:`, and add the dependency)

```yaml
  KoffeeLidHook:
    type: tool
    platform: macOS
    sources: [Hook/Sources]
    dependencies:
      - package: KoffeeLidPackage
        product: KoffeeLidCore
    settings:
      base:
        PRODUCT_NAME: KoffeeLidHook
        PRODUCT_BUNDLE_IDENTIFIER: dev.rubens.koffeelid.hook
        SKIP_INSTALL: YES
```

and in the `KoffeeLid` target's `dependencies:` list, after the watchdog entry:

```yaml
      - target: KoffeeLidHook
        embed: true
        copy:
          destination: executables
```

- [ ] **Step 2: Write the tool**

```swift
// Hook/Sources/main.swift
import Foundation
import Darwin
import KoffeeLidCore

/// `KoffeeLidHook hook` runs inside every Claude Code turn: it must never block on anything but one
/// append, never launch the app, and always exit 0. `job begin|end` are the zsh snippet's primitives.
enum HookMain {
    static func run(_ args: [String]) -> Int32 {
        if ProcessInfo.processInfo.environment["KOFFEELID_DISABLE"] == "1" { return 0 }
        switch args.first {
        case "hook": return hook()
        case "job": return job(Array(args.dropFirst()))
        default:
            FileHandle.standardError.write(Data("usage: KoffeeLidHook hook | job begin --id ID --pid PID [--label TEXT] [--arm-after SECONDS] | job end --id ID\n".utf8))
            return 2
        }
    }

    static func hook() -> Int32 {
        var input = Data()
        let stdin = FileHandle.standardInput
        // Read everything so the writer is never broken by a closed pipe, but retain at most the cap.
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            if input.count < ActivityConstants.hookStdinMaxBytes {
                input.append(chunk.prefix(ActivityConstants.hookStdinMaxBytes - input.count))
            }
        }
        var event = ActivityTrim.event(fromHookPayload: input, loggedAt: Date())
        // Ancestors from the parent: Claude Code spawns the hook through a shell.
        event.claudePid = ProcWalk.claudePid(inChainFrom: getppid())
        if let line = try? ActivityTrim.cappedLine(event) { ActivityJournalWriter.append(line, to: AppSupport.activityJournalURL) }
        return 0
    }

    static func job(_ args: [String]) -> Int32 {
        guard let verb = args.first, verb == "begin" || verb == "end" else { return 2 }
        var id: String?; var pid: Int32 = getppid(); var label: String?; var armAfter: Double?
        var i = 1
        while i + 1 < args.count {
            let v = args[i + 1]
            switch args[i] {
            case "--id": id = v
            case "--pid": pid = Int32(v) ?? pid
            case "--label": label = v
            case "--arm-after": armAfter = Double(v)
            default: return 2
            }
            i += 2
        }
        guard let id, !id.isEmpty else { return 2 }
        var e = ActivityEvent(loggedAt: Date(), event: verb == "begin" ? .jobBegin : .jobEnd)
        e.jobId = String(id.prefix(ActivityConstants.metadataMaxChars))
        if verb == "begin" {
            e.jobPid = pid
            e.jobLabel = label.map(ActivityTrim.clampLabel)
            e.jobArmAfterSeconds = armAfter.map { max(0, $0) }
        }
        if let line = try? ActivityTrim.cappedLine(e) { ActivityJournalWriter.append(line, to: AppSupport.activityJournalURL) }
        return 0
    }
}

exit(HookMain.run(Array(CommandLine.arguments.dropFirst())))
```

- [ ] **Step 3: Regenerate and build**

```bash
cd /Users/Rubens/Projects/koffeelid && script/bootstrap.sh && \
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'
```
Expected: `** BUILD SUCCEEDED **`, no warnings. Then confirm the embed: `ls DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/MacOS/` shows `KoffeeLid`, `KoffeeLidWatchdog`, `KoffeeLidHook`.

- [ ] **Step 4: Smoke the binary against a scratch journal**

```bash
H=DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/MacOS/KoffeeLidHook
echo '{"hook_event_name":"Stop","session_id":"smoke","tool_input":{"x":"y"}}' | "$H" hook; echo "exit $?"
"$H" job begin --id zsh-1 --pid $$ --label make; "$H" job end --id zsh-1
tail -3 "$HOME/Library/Application Support/KoffeeLid/activity.jsonl"
```
Expected: `exit 0`; three JSON lines, the Stop line without `tool_input`, the begin line with `"job_pid"`. Then delete the smoke lines: the installed app is not tailing yet, but keep the journal clean — `rm "$HOME/Library/Application Support/KoffeeLid/activity.jsonl"`. Also check `echo garbage | "$H" hook; echo $?` prints 0 and `KOFFEELID_DISABLE=1 "$H" hook </dev/null` writes nothing.

- [ ] **Step 5: Commit** — `git add Hook/Sources/main.swift project.yml && git commit -m "build(activity): KoffeeLidHook tool target — hook and job verbs appending to the activity journal"`

---

### Task 11: App adapters — journal tailer, process watcher, registry reader

**Files:**
- Create: `App/Sources/ActivityJournalTailer.swift`
- Create: `App/Sources/ActivityProcessWatcher.swift`
- Create: `App/Sources/ClaudeProcessRegistry.swift`

**Interfaces:**
- Produces: `ActivityJournalTailer(url:)` with `var onEvents: (([ActivityEvent]) -> Void)?` (called on the tailer's queue), `start()`, `stop()`; `ActivityProcessWatcher(queue: .main)` with `var onExit: ((Int32) -> Void)?`, `watch(pid:)`, `unwatchAll(except:)`; `ClaudeProcessRegistry.read(pid:) -> ClaudeRegistryRecord?`.

No unit tests (hardware/kernel-facing, like `BatteryMonitor`); the behaviour is verified by Task 12's runtime smoke and `docs/manual-checks.md`.

- [ ] **Step 1: Write the tailer**

```swift
// App/Sources/ActivityJournalTailer.swift
import Foundation
import KoffeeLidCore

/// Tails the activity journal with a vnode DispatchSource. `start()` drains what is already on disk (the
/// replay), then live appends arrive within milliseconds. A rename or delete (rotation) is followed by
/// draining the old inode and re-arming on the recreated path.
final class ActivityJournalTailer {
    var onEvents: (([ActivityEvent]) -> Void)?
    private let url: URL
    private let queue = DispatchQueue(label: "dev.rubens.koffeelid.activity.tailer")
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var remainder = Data()
    private var stopped = false

    init(url: URL) { self.url = url }

    func start() { queue.sync { openAndArm(); drain() } }
    func stop() { queue.sync { stopped = true; source?.cancel(); source = nil } }

    private func openAndArm() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_CREAT without O_TRUNC: opens the existing inode untouched or creates an empty one atomically.
        // fileExists + createFile would race a hook's own O_CREAT and truncate its line away.
        let fd = open(url.path, O_RDONLY | O_CREAT, 0o644)
        guard fd >= 0 else { self.fd = -1; scheduleReopen(); return }
        self.fd = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let flags = source.data
            self.drain()
            if flags.contains(.rename) || flags.contains(.delete) {
                self.source?.cancel(); self.source = nil; self.remainder.removeAll()
                self.openAndArm(); self.drain()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
    private func scheduleReopen() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped, self.source == nil else { return }
            self.openAndArm(); self.drain()
        }
    }
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            remainder.append(contentsOf: buffer[0..<n])
        }
        var events: [ActivityEvent] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = remainder.subdata(in: remainder.startIndex..<newline)
            remainder.removeSubrange(remainder.startIndex...newline)
            if !line.isEmpty, let e = ActivityCodec.decodeLine(line) { events.append(e) }
        }
        if !events.isEmpty { onEvents?(events) }
    }
}
```

- [ ] **Step 2: Write the process watcher**

```swift
// App/Sources/ActivityProcessWatcher.swift
import Foundation

/// kqueue EVFILT_PROC via DispatchSource: the instant a watched process exits, `onExit` fires on `queue`.
/// This is what removes a stuck session or job without waiting for an end event that may never come.
final class ActivityProcessWatcher {
    var onExit: ((Int32) -> Void)?
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let queue: DispatchQueue
    init(queue: DispatchQueue = .main) { self.queue = queue }

    func watch(pid: Int32) {
        queue.async { [self] in
            guard sources[pid] == nil else { return }
            guard kill(pid, 0) == 0 || errno == EPERM else { onExit?(pid); return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.sources.removeValue(forKey: pid)?.cancel()
                self.onExit?(pid)
            }
            source.resume()
            sources[pid] = source
            // The pid may have died between the liveness check and resume(): the attach silently misses it.
            if kill(pid, 0) != 0 && errno != EPERM { sources.removeValue(forKey: pid)?.cancel(); onExit?(pid) }
        }
    }
    func unwatchAll(except keep: Set<Int32>) {
        queue.async { [self] in
            for (pid, source) in sources where !keep.contains(pid) { source.cancel(); sources.removeValue(forKey: pid) }
        }
    }
}
```

- [ ] **Step 3: Write the registry reader**

```swift
// App/Sources/ClaudeProcessRegistry.swift
import Foundation
import KoffeeLidCore

/// Locates `<config>/sessions/<pid>.json` through the process (CLAUDE_CONFIG_DIR is per account), not a fixed path.
enum ClaudeProcessRegistry {
    static func read(pid: Int32) -> ClaudeRegistryRecord? {
        let configDir = ProcWalk.environmentValue("CLAUDE_CONFIG_DIR", forPid: pid).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("sessions/\(pid).json")) else { return nil }
        return ClaudeRegistryRecord.parse(data, expectedPid: pid)
    }
}
```

- [ ] **Step 4: Regenerate and build** — `script/bootstrap.sh && xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'` → `BUILD SUCCEEDED`, no warnings.

- [ ] **Step 5: Commit** — `git add App/Sources/ActivityJournalTailer.swift App/Sources/ActivityProcessWatcher.swift App/Sources/ClaudeProcessRegistry.swift && git commit -m "feat(activity): journal tailer, kqueue process watcher and registry reader"`

---

### Task 12: ActivityMonitor

**Files:**
- Create: `App/Sources/ActivityMonitor.swift`

**Interfaces:**
- Consumes: Tasks 3–5, 9, 11.
- Produces: `struct ActivitySnapshot: Equatable { running: Bool; workingSessions: Int; runningJobs: Int; var summary: String }`, `@MainActor final class ActivityMonitor` with `var onChange: ((ActivitySnapshot) -> Void)?` (main thread, only on change), `var onLog: ((String) -> Void)?`, `var jobArmAfterSeconds: Double`, `private(set) var snapshot: ActivitySnapshot`, `var hookBinaryURL: URL` (static helper), `func start()`, `func stop()`, `func refresh()` (re-evaluate now, e.g. on wake). Disabled entirely when `KOFFEELID_DISABLE_ACTIVITY=1` is in the environment (`start()` logs and returns).

- [ ] **Step 1: Write the monitor**

```swift
// App/Sources/ActivityMonitor.swift
import AppKit
import KoffeeLidCore

struct ActivitySnapshot: Equatable {
    var running = false
    var workingSessions = 0
    var runningJobs = 0
    /// For the status line and the Advanced page. Not localized: it is CLI/log text.
    var summary: String {
        let s = workingSessions == 1 ? "1 session working" : "\(workingSessions) sessions working"
        let j = runningJobs == 1 ? "1 command" : "\(runningJobs) commands"
        return "\(s), \(j)"
    }
}

/// Owns the two stores; tails the activity journal; watches Claude and shell pids; runs the time rules and
/// the registry rescues; reports the aggregate "running" level to the coordinator. Main thread only.
@MainActor
final class ActivityMonitor {
    var onChange: ((ActivitySnapshot) -> Void)?
    var onLog: ((String) -> Void)?
    var jobArmAfterSeconds: Double = ActivityConstants.jobArmAfterDefaultSeconds
    private(set) var snapshot = ActivitySnapshot()

    private var sessions = ActivitySessionStore()
    private var jobs = ActivityJobStore()
    private let tailer = ActivityJournalTailer(url: AppSupport.activityJournalURL)
    private let watcher = ActivityProcessWatcher(queue: .main)
    private var timer: Timer?
    private var started = false
    private var warnedNoRegistry: Set<String> = []
    private var warnedHooksSilent: Set<String> = []
    private var wakeObserver: NSObjectProtocol?

    static var isDisabledByEnvironment: Bool { ProcessInfo.processInfo.environment["KOFFEELID_DISABLE_ACTIVITY"] == "1" }

    func start() {
        guard !started else { return }
        if Self.isDisabledByEnvironment { onLog?("activity: disabled by KOFFEELID_DISABLE_ACTIVITY"); return }
        started = true
        watcher.onExit = { [weak self] pid in self?.processExited(pid) }
        // Replay: events from this boot only, then prune dead or recycled pids.
        let boot = Self.bootDate() ?? .distantPast
        let replayed = (ActivityJournalWriter.readAll(url: AppSupport.activityJournalRotatedURL) + ActivityJournalWriter.readAll(url: AppSupport.activityJournalURL))
            .filter { $0.loggedAt >= boot }
        apply(replayed)
        sessions.pruneDead { ProcWalk.isAlive(pid: $0) && ProcWalk.looksLikeClaude(pid: $0) }
        for job in jobs.jobs.values { if let pid = job.ownerPid, !ProcWalk.isAlive(pid: pid) { jobs.processExited(pid: pid) } }
        onLog?("activity: replayed \(replayed.count) events, \(sessions.sessions.count) sessions, \(jobs.jobs.count) jobs")
        rotateIfNeeded()
        // Live: the tailer drains from the current end (the replay already consumed the file), then follows appends.
        tailer.onEvents = { [weak self] events in Task { @MainActor in self?.apply(events) } }
        tailer.start()
        onLog?("activity: hooks journal tailing")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        sync()
    }

    func stop() {
        guard started else { return }
        started = false
        tailer.stop(); timer?.invalidate(); timer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Re-run every time rule against the wall clock (wake, preference change).
    func refresh() { sync() }

    // MARK: ingestion

    private func apply(_ events: [ActivityEvent]) {
        for e in events {
            switch e.event {
            case .jobBegin:
                guard let id = e.jobId else { continue }
                jobs.begin(id: id, pid: e.jobPid, label: e.jobLabel, armAfterSeconds: e.jobArmAfterSeconds ?? jobArmAfterSeconds, now: e.loggedAt)
            case .jobEnd:
                if let id = e.jobId { jobs.end(id: id) }
            case .parseError:
                onLog?("activity: unparseable hook payload (\(e.rawPrefix?.prefix(60) ?? ""))")
            default:
                sessions.apply(e)
            }
        }
        sync()
    }

    private func processExited(_ pid: Int32) {
        sessions.processExited(pid: pid); jobs.processExited(pid: pid)
        sync()
    }

    // MARK: time

    private func sync() {
        let now = Date()
        sessions.tick(now: now); jobs.tick(now: now)
        checkRegistry(now: now)
        watcher.unwatchAll(except: sessions.trackedPids.union(jobs.trackedPids))
        for pid in sessions.trackedPids.union(jobs.trackedPids) { watcher.watch(pid: pid) }
        rotateIfNeeded()
        publish(now: now)
        scheduleNext(now: now)
    }

    private func publish(now: Date) {
        let new = ActivitySnapshot(running: sessions.isRunning || jobs.isRunning(at: now),
                                   workingSessions: sessions.workingCount, runningJobs: jobs.runningCount(at: now))
        guard new != snapshot else { return }
        if new.running != snapshot.running { onLog?(new.running ? "activity: running (\(new.summary))" : "activity: idle") }
        snapshot = new
        onChange?(new)
    }

    private func scheduleNext(now: Date) {
        timer?.invalidate(); timer = nil
        let deadlines = [sessions.nextDeadline(after: now), jobs.nextDeadline(after: now)].compactMap { $0 }
        guard let next = deadlines.min() else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in self?.sync() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Esc/Ctrl-C fire no hook: ask Claude Code's own registry about quiet turns and open dialogs (spec §4).
    private func checkRegistry(now: Date) {
        for (sid, pid) in sessions.abandonCandidates(at: now) {
            guard let record = ClaudeProcessRegistry.read(pid: pid), record.sessionId == sid else {
                if warnedNoRegistry.insert(sid).inserted { onLog?("activity: no registry record for pid \(pid) (session \(sid.prefix(8))); only staleness can end it") }
                continue
            }
            guard let session = sessions.sessions[sid] else { continue }
            if record.isIdle, let stamped = record.statusUpdatedAt, stamped > session.lastMainEventAt {
                onLog?("activity: quiet turn \(sid.prefix(8)) — registry idle, turn over")
                sessions.turnOver(sessionId: sid, now: now)
            } else if record.isBusy {
                if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                    onLog?("activity: hooks look dead for \(sid.prefix(8)) — registry busy, no hook for 5 min")
                }
                sessions.noteBusy(sessionId: sid, now: now)
            }
        }
        for (sid, pid, since) in sessions.openWaitCandidates() {
            guard let record = ClaudeProcessRegistry.read(pid: pid), record.sessionId == sid, record.isBusy,
                  let stamped = record.statusUpdatedAt, stamped.timeIntervalSince(since) > ActivityConstants.dialogAnswerMinStampLeadSeconds else { continue }
            onLog?("activity: dialog answered without a hook (\(sid.prefix(8))); back to working")
            sessions.dialogAnswered(sessionId: sid, now: now)
        }
    }

    // MARK: journal housekeeping

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: AppSupport.activityJournalURL.path)[.size] as? Int) else { return }
        let idle = !sessions.isRunning && !jobs.isRunning(at: Date())
        guard size > ActivityConstants.journalRotateHardBytes || (idle && size > ActivityConstants.journalRotateIdleBytes) else { return }
        try? fm.removeItem(at: AppSupport.activityJournalRotatedURL)
        if (try? fm.moveItem(at: AppSupport.activityJournalURL, to: AppSupport.activityJournalRotatedURL)) != nil { onLog?("activity: journal rotated") }
    }

    static func bootDate() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]; var tv = timeval(); var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// The embedded hook binary next to the app binary — what `install-hooks` and `shell-init` point at.
    static var hookBinaryURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KoffeeLidHook") }
}
```

- [ ] **Step 2: Build** — `xcodebuild … build 2>&1 | grep -E 'error|warning:|BUILD'` → `BUILD SUCCEEDED`, no warnings. (Not wired into the coordinator yet; that is Task 13.)

- [ ] **Step 3: Commit** — `git add App/Sources/ActivityMonitor.swift && git commit -m "feat(activity): ActivityMonitor — replay, tailing, ticks, registry rescues, rotation"`

---

### Task 13: Preferences and coordinator wiring

**Files:**
- Modify: `App/Sources/Preferences.swift`
- Modify: `App/Sources/KoffeeLidController.swift`

**Interfaces:**
- Consumes: `ActivityMonitor`, `ActivitySnapshot`, `ActivityArmPolicy`.
- Produces: `Preferences.armOnActivity: Bool` (default `false`), `activityDisarmHoldOffSeconds: Double` (60), `activityJobArmAfterSeconds: Double` (5); `ArmSource.activity`; `KoffeeLidController.activity: ActivityMonitor` (read by the UI for the live line); `disarm(reason:source:)` gains an optional `source: ArmSource? = nil`; `statusLine()` extended.

- [ ] **Step 1: Preferences** — register defaults and add accessors in `App/Sources/Preferences.swift`:

In `d.register(defaults:)` add:
```swift
            "armOnActivity": false, "activityDisarmHoldOffSeconds": 60.0, "activityJobArmAfterSeconds": 5.0,
```
After `armWithOption`:
```swift
    /// Arm while a Claude Code session or a terminal command (zsh hooks) is running; disarm after the hold-off.
    var armOnActivity: Bool { get { d.bool(forKey: "armOnActivity") } set { set("armOnActivity", newValue) } }
    var activityDisarmHoldOffSeconds: Double { get { d.double(forKey: "activityDisarmHoldOffSeconds") } set { set("activityDisarmHoldOffSeconds", min(300, max(10, newValue))) } }
    var activityJobArmAfterSeconds: Double { get { d.double(forKey: "activityJobArmAfterSeconds") } set { set("activityJobArmAfterSeconds", min(30, max(0, newValue))) } }
```

- [ ] **Step 2: Coordinator — source, state, monitor**

`App/Sources/KoffeeLidController.swift` line 6: `enum ArmSource: String { case menu, rightClick, shortcut, gesture, intent, url, cli, activity }`

Add properties next to `private let commands = CommandServer()`:
```swift
    /// Auto-arm on activity (spec docs/superpowers/specs/2026-09-11-activity-auto-arm-design.md).
    let activity = ActivityMonitor()
    private var activityPolicy = ActivityArmPolicy(holdOff: ActivityConstants.disarmHoldOffDefaultSeconds)
    private var activityTimer: Timer?
```

In `start()`, just before `prefs.onChange = …`:
```swift
        activityPolicy.holdOff = prefs.activityDisarmHoldOffSeconds
        activity.jobArmAfterSeconds = prefs.activityJobArmAfterSeconds
        activity.onLog = { [log] in log.log($0) }
        activity.onChange = { [weak self] snapshot in self?.handleActivity(snapshot) }
        activity.start()
```
In `shutdown()`, first line after the `isStarted` guard (read the function first; it must stay before the flag-clearing block): `activity.stop(); activityTimer?.invalidate()`.

- [ ] **Step 3: Coordinator — ownership reporting**

In `setMode`, the in-place switch branch: after `mode = target` add `armSource = source` (spec §6: today the source is not recorded on Armed ↔ Caffeinate). At the end of that `if mode != target { … }` block add `activityModeChanged(source: source)`.

`arm(source:mode:)`: after `refreshStatusItem()` and before `return .allowed`, add `activityModeChanged(source: source)`.

`disarm(reason:)` → `func disarm(reason: String, source: ArmSource? = nil)`; before `log.log("disarmed (\(reason))")` add `activityModeChanged(source: source)`. In `setMode`, `if target == .off { disarm(reason: source.rawValue, source: source); return .allowed }`.

Add the handlers (under `// MARK: events`):
```swift
    // MARK: activity

    private func activityModeChanged(source: ArmSource?) {
        activityPolicy.modeChanged(isOff: mode == .off, isActivitySource: source == .activity)
        scheduleActivityTick()
    }

    private func handleActivity(_ snapshot: ActivitySnapshot) {
        let action = activityPolicy.update(running: snapshot.running, modeIsOff: mode == .off,
                                           enabled: prefs.armOnActivity && prefs.enabled, now: Date())
        applyActivity(action)
        scheduleActivityTick()
    }

    private func applyActivity(_ action: ActivityArmAction?) {
        switch action {
        case .arm:
            let decision = arm(source: .activity)
            if case .blocked = decision { activityPolicy.armFailed(); log.log("auto-arm blocked; waiting for the next activity") }
            else { log.log("auto-armed (activity)") }
        case .disarm:
            guard armSource == .activity else { return }   // belt and braces: the policy already checks ownership
            disarm(reason: "activity ended", source: .activity)
        case nil: break
        }
    }

    private func scheduleActivityTick() {
        activityTimer?.invalidate(); activityTimer = nil
        guard let due = activityPolicy.nextDeadline(after: Date()) else { return }
        log.log("auto-disarm scheduled in \(Int(due.timeIntervalSinceNow.rounded()))s")
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyActivity(self.activityPolicy.tick(now: Date()))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }
```
Note: `arm(source: .activity)` calls `notifyBlocked` on a refusal exactly like any other source; `armFailed()` guarantees it happens once per activity edge, not per tick.

- [ ] **Step 4: Coordinator — status line and preferences**

`statusLine()`: after the `mode:` part add
```swift
        if armSource == .activity { parts.append("auto-armed (activity)") }
        if activityPolicy.suppressed, prefs.armOnActivity { parts.append("auto-arm suppressed until the next activity") }
```
and as the last part, always: `parts.append("activity: " + activity.snapshot.summary)`.

`preferenceChanged(_:)` — add a case before `default`:
```swift
        case "armOnActivity", "activityDisarmHoldOffSeconds", "activityJobArmAfterSeconds":
            activityPolicy.holdOff = prefs.activityDisarmHoldOffSeconds
            activity.jobArmAfterSeconds = prefs.activityJobArmAfterSeconds
            if key == "armOnActivity", !prefs.armOnActivity, armSource == .activity { disarm(reason: "activity auto-arm disabled", source: .activity) }
            if key == "armOnActivity", prefs.armOnActivity { handleActivity(activity.snapshot) }
            scheduleActivityTick()
```
The last line re-evaluates when the feature is switched on while something already runs: `update` sees `lastRunning == running`, so it does **not** arm on a level — that is intended (the user turns the switch on, the next command or turn arms). Also in the existing `"enabled"` branch nothing changes: `disarm(reason: "disabled")` has no source, so the policy treats it as a manual Off.

- [ ] **Step 5: Build and smoke**

Build (grep as before) → `BUILD SUCCEEDED`, no warnings. Then the always-safe runtime smoke, with the feature disabled for this process so it cannot arm on the session running it:

```bash
"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status      # note the user's mode; do not touch the installed app
KOFFEELID_DISABLE_ACTIVITY=1 DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/MacOS/KoffeeLid & sleep 3
tail -5 "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"
osascript -e 'tell application id "dev.rubens.koffeelid" to quit'
```
Expected in the log: `launched (pid …)`, `activity: disabled by KOFFEELID_DISABLE_ACTIVITY`, then `clean termination`. **Caution:** the Debug app shares the bundle id with the installed one, so `AppDelegate` exits as a duplicate instance if the installed app is running. That is fine for this smoke: read the log line `duplicate-instance exit` and stop there; the full runtime check happens after install (Task 16).

- [ ] **Step 6: Commit** — `git add App/Sources/Preferences.swift App/Sources/KoffeeLidController.swift && git commit -m "feat(activity): ArmSource.activity, arm policy wiring, preferences and status line"`

---

### Task 14: CLI verbs and HookInstaller

**Files:**
- Create: `App/Sources/HookInstaller.swift`
- Modify: `App/Sources/CommandServer.swift` (`CommandLineClient.run`, `usage`)

**Interfaces:**
- Produces: `HookInstaller.install() -> (ok: Bool, message: String)`, `HookInstaller.uninstall() -> (ok: Bool, message: String)`, `HookInstaller.installedCount() -> Int?` (nil when settings.json is unreadable), `HookInstaller.command: String`, `HookInstaller.zshLine: String` (`eval "$(koffeelid shell-init zsh)"` or the bundle-binary form when no wrapper exists), `HookInstaller.snippet: String`. CLI verbs: `install-hooks`, `uninstall-hooks`, `shell-init zsh`, all exit 0/1 without contacting or launching the app.

- [ ] **Step 1: Write the installer**

```swift
// App/Sources/HookInstaller.swift
import Foundation
import KoffeeLidCore

/// `koffeelid install-hooks` / `uninstall-hooks` and the Settings button share this. Edits
/// `~/.claude/settings.json` through `HookConfig`, backs it up first, and reports what actually landed.
enum HookInstaller {
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var backupURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json.backup-koffeelid") }
    /// The hook binary's resolved absolute path: a hook pointing at a nonexistent path fails silently.
    static var hookPath: String { ActivityMonitor.hookBinaryURL.resolvingSymlinksInPath().standardizedFileURL.path }
    static var command: String { "\(hookPath) hook" }
    static var snippet: String { ShellInit.zsh(hookPath: hookPath) }
    static var zshLine: String {
        FileManager.default.isExecutableFile(atPath: "/usr/local/bin/koffeelid")
            ? "eval \"$(koffeelid shell-init zsh)\""
            : "eval \"$(\"\(Bundle.main.bundleURL.path)/Contents/MacOS/KoffeeLid\" shell-init zsh)\""
    }

    static func install() -> (ok: Bool, message: String) {
        do {
            let root = try HookSettingsFile.load(at: settingsURL) ?? [:]
            try HookSettingsFile.backup(from: settingsURL, to: backupURL)
            let edited = HookConfig.install(into: root, command: command)
            try HookSettingsFile.write(edited, to: settingsURL)
            let n = HookConfig.installedCount(in: edited, command: command), total = HookConfig.events.count
            if n == total { return (true, "Installed \(total) Claude Code hooks -> \(command)") }
            let missing = HookConfig.events.filter { HookConfig.installedCommand(in: edited, event: $0) != command }
            return (false, "Installed \(n) of \(total) hooks -> \(command)\nDeclined to touch: \(missing.joined(separator: ", ")) (their value in ~/.claude/settings.json has a shape this tool does not rewrite)")
        } catch { return (false, "install-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    static func uninstall() -> (ok: Bool, message: String) {
        do {
            guard let root = try HookSettingsFile.load(at: settingsURL) else { return (true, "No settings file found — nothing to remove.") }
            try HookSettingsFile.backup(from: settingsURL, to: backupURL)
            try HookSettingsFile.write(HookConfig.uninstall(from: root), to: settingsURL)
            return (true, "Removed KoffeeLid hooks.")
        } catch { return (false, "uninstall-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    /// How many of the 15 events currently point at THIS bundle's hook binary; nil if settings.json is unreadable.
    static func installedCount() -> Int? {
        guard let root = try? HookSettingsFile.load(at: settingsURL) else { return nil }
        return HookConfig.installedCount(in: root ?? [:], command: command)
    }
}
```

- [ ] **Step 2: CLI verbs** — in `CommandLineClient.run(arguments:)`, before `guard let verb = DeepLink(command: arguments[1])`:

```swift
        switch arguments[1] {
        case "install-hooks":
            let r = HookInstaller.install(); print(r.message); return r.ok ? 0 : 1
        case "uninstall-hooks":
            let r = HookInstaller.uninstall(); print(r.message); return r.ok ? 0 : 1
        case "shell-init":
            guard arguments.count >= 3, arguments[2] == "zsh" else { fputs("usage: koffeelid shell-init zsh\n", stderr); return 2 }
            print(HookInstaller.snippet); return 0
        default: break
        }
```
and `usage` becomes `"usage: koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings | install-hooks | uninstall-hooks | shell-init zsh"`.

- [ ] **Step 3: Build and smoke without touching the real settings file**

Build → `BUILD SUCCEEDED`. Then:
```bash
B=DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/MacOS/KoffeeLid
"$B" shell-init zsh | head -3          # prints the snippet, mentions .../Debug/KoffeeLid.app/Contents/MacOS/KoffeeLidHook
"$B" shell-init zsh | zsh -n && echo syntax-ok
"$B" bogus; echo "exit $?"            # usage + exit 2
```
Do **not** run `install-hooks` from the Debug build: it would point the user's Claude Code at the DerivedData path. `install-hooks` is smoked from the installed app in Task 16.

- [ ] **Step 4: Commit** — `git add App/Sources/HookInstaller.swift App/Sources/CommandServer.swift && git commit -m "feat(activity): koffeelid install-hooks, uninstall-hooks and shell-init zsh"`

---

### Task 15: Settings UI, Advanced UI and strings

**Files:**
- Modify: `App/Sources/UI/SettingsViewController.swift` ("Arm with" group)
- Modify: `App/Sources/UI/AdvancedViewController.swift` (new "Auto-arm on activity" group)
- Modify: `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `Preferences.armOnActivity / activityDisarmHoldOffSeconds / activityJobArmAfterSeconds`, `HookInstaller`, `KoffeeLidController.shared.activity.snapshot`, `SettingsForm` API (`row`, `labelledSlider`, `note`, `switch`, `button`, `value`).

- [ ] **Step 1: Settings page** — inside the existing `f.group { g in … }` under `f.header(L("Arm with"))`, after the Armed + Caffeinate shortcut row:

```swift
            g.row(L("While Claude Code or a terminal command is running"), SettingsForm.switch(prefs.armOnActivity) { [prefs] in prefs.armOnActivity = $0 })
            hooksValue = SettingsForm.value("")
            hooksButton = SettingsForm.button(L("Install hooks…"), { [weak self] in
                let r = HookInstaller.install()
                DiagnosticLog.shared.log("install-hooks from Settings: \(r.message)")
                self?.refreshHooks()
            })
            g.row(L("Claude Code hooks"), hooksValue!, hooksButton!)
            g.row(L("Terminal commands"), SettingsForm.button(L("Copy zsh line"), {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(HookInstaller.zshLine, forType: .string)
            }), detail: L("Add the copied line to ~/.zshrc"))
```
Add the properties `private var hooksValue: NSTextField?` and `private var hooksButton: NSButton?`, and:
```swift
    private func refreshHooks() {
        let total = HookConfig.events.count
        switch HookInstaller.installedCount() {
        case .some(let n) where n == total: hooksValue?.stringValue = L("Installed"); hooksValue?.textColor = .secondaryLabelColor; hooksButton?.isHidden = true
        case .some(let n): hooksValue?.stringValue = String(format: L("%d of %d installed"), n, total); hooksValue?.textColor = .systemOrange; hooksButton?.isHidden = false
        case .none: hooksValue?.stringValue = L("Settings file unreadable"); hooksValue?.textColor = .systemOrange; hooksButton?.isHidden = true
        }
    }
```
Call `refreshHooks()` at the end of `build` and in `viewWillAppear` (next to `refreshPermission()`). Add `import KoffeeLidCore` if missing (it is already imported). Extend the existing note under the group by appending a sentence: `L("Auto-arm arms only from Off and disarms only what it armed itself, after the hold-off set in Advanced.")` — keep it as a second `f.note` call so the existing key stays untouched.

- [ ] **Step 2: Advanced page** — after the "Lid effect" group and before `f.header(L("App"))`:

```swift
        f.header(L("Auto-arm on activity"))
        f.group { g in
            g.labelledSlider(L("Disarm after nothing has run for"), min: 10, max: 300, value: prefs.activityDisarmHoldOffSeconds, fmt: { "\(Int($0.rounded())) s" }) { [prefs] in prefs.activityDisarmHoldOffSeconds = ($0 / 5).rounded() * 5 }
            g.labelledSlider(L("Ignore commands shorter than"), min: 0, max: 30, value: prefs.activityJobArmAfterSeconds, fmt: { "\(Int($0.rounded())) s" }) { [prefs] in prefs.activityJobArmAfterSeconds = $0.rounded() }
            activityValue = SettingsForm.value("—")
            g.row(L("Activity"), activityValue)
        }
        f.note(L("Claude Code sessions blocked on a question or a permission do not count as running. A turn whose helpers are still out stays running until they fall silent."))
```
Add `private var activityValue: NSTextField!` and extend the existing 0.2 s timer body: `self?.activityValue.stringValue = KoffeeLidController.shared.activity.snapshot.summary`.

- [ ] **Step 3: Strings** — add every new key to `App/Resources/Localizable.xcstrings` with an `fr` `stringUnit` (`state: translated`), same JSON shape as the existing entries:

| en | fr |
|---|---|
| While Claude Code or a terminal command is running | Quand Claude Code ou une commande du terminal tourne |
| Install hooks… | Installer les hooks… |
| Claude Code hooks | Hooks Claude Code |
| Terminal commands | Commandes du terminal |
| Copy zsh line | Copier la ligne zsh |
| Add the copied line to ~/.zshrc | Ajoutez la ligne copiée à ~/.zshrc |
| Installed | Installés |
| %d of %d installed | %d sur %d installés |
| Settings file unreadable | Fichier de réglages illisible |
| Auto-arm arms only from Off and disarms only what it armed itself, after the hold-off set in Advanced. | L’activation automatique ne part que depuis Désactivé et ne désactive que ce qu’elle a activé elle-même, après le délai réglé dans Avancé. |
| Auto-arm on activity | Activation automatique sur activité |
| Disarm after nothing has run for | Désactiver quand plus rien ne tourne depuis |
| Ignore commands shorter than | Ignorer les commandes plus courtes que |
| Activity | Activité |
| Claude Code sessions blocked on a question or a permission do not count as running. A turn whose helpers are still out stays running until they fall silent. | Une session Claude Code bloquée sur une question ou une permission ne compte pas comme active. Un tour dont les agents auxiliaires tournent encore reste actif jusqu’à ce qu’ils se taisent. |

- [ ] **Step 4: Build and look**

Build → `BUILD SUCCEEDED`, **no** `warning:` lines (an untranslated key is a build warning). Render both pages without clicking the status item:
```bash
KOFFEELID_DISABLE_ACTIVITY=1 DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/MacOS/KoffeeLid --open-settings
```
(if the installed app is running this exits as a duplicate instance; then check the UI after Task 16's install instead). Check: the switch row, the hooks status row ("not installed" shows as `0 of 15 installed` in orange with the button), the Copy button, the Advanced sliders and the live Activity line. Quit with `osascript -e 'tell application id "dev.rubens.koffeelid" to quit'`.

- [ ] **Step 5: Commit** — `git add App/Sources/UI/SettingsViewController.swift App/Sources/UI/AdvancedViewController.swift App/Resources/Localizable.xcstrings && git commit -m "feat(activity): Settings switch, hook installer controls, Advanced sliders and live activity line"`

---

### Task 16: Documentation, version, install and end-to-end check

**Files:**
- Modify: `docs/architecture.md`, `docs/development.md`, `docs/manual-checks.md`, `docs/platform-notes.md`, `CLAUDE.md`, `README.md`
- Modify: `App/Info.plist`, `Sources/KoffeeLidCore/KoffeeLidCore.swift`, `Tests/KoffeeLidCoreTests/SmokeTests.swift` (version → `0.1.0`)

- [ ] **Step 1: architecture.md** — add a section `## Auto-arm on activity` after "Command line and URLs" covering: the module list from the plan's file map; the data flow `KoffeeLidHook → activity.jsonl → ActivityJournalTailer → ActivityMonitor (ActivitySessionStore + ActivityJobStore) → onChange → KoffeeLidController.handleActivity → ActivityArmPolicy → arm(.activity) / disarm(source: .activity)`; the ownership rules (spec §6) in three sentences; the pointer to the spec for the state machine table. Add `activity` to the `ArmSource` mention in the "Arming state machine" section and note that `setMode` now records the source on in-place switches. In the "Kernel flag ownership" table nothing changes (activity uses `arm`/`disarm`).

- [ ] **Step 2: development.md** — under "How to add things" add **"Testing the activity feature"**: `KOFFEELID_DISABLE_ACTIVITY=1` for the Debug smoke (shared UserDefaults and journal with the installed app); how to fake a session without Claude: `echo '{"hook_event_name":"UserPromptSubmit","session_id":"fake"}' | /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook` (arms if the switch is on; no pid → only staleness or a `Stop` line ends it) and `… "Stop" …` to end it; that `install-hooks` writes the path of the binary that runs it, so it must be run from `/Applications`; that `~/.claude/settings.json` is user-owned and backed up to `settings.json.backup-koffeelid`. Update "A user-visible string"/"A preference" only if the pattern changed (it did not).

- [ ] **Step 3: manual-checks.md** — add `## Auto-arm on activity`:

```markdown
## Auto-arm on activity
- [ ] `koffeelid install-hooks` → `Installed 15 Claude Code hooks -> /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook`; `koffeelid status` ends with `activity: 0 sessions working, 0 commands`
- [ ] Add the zsh line to `~/.zshrc`, open a new terminal, run `sleep 120` → after 5 s the mug arms, log `activity: running (0 sessions working, 1 command)` then `auto-armed (activity)`; `koffeelid status` shows `auto-armed (activity)`
- [ ] Close the lid during the sleep → Mac stays awake; open it → lock screen; command ends → `activity: idle`, `auto-disarm scheduled in 60s`, then `disarmed (activity ended)` and normal lid sleep is back (`AppleClamshellCausesSleep = Yes`)
- [ ] `sleep 2` alone never arms (arm-after 5 s); `vim` never arms (skip list)
- [ ] Start a Claude Code turn → arms within a second of the prompt (`activity: running (1 session working, 0 commands)`); a question from Claude (AskUserQuestion) → `activity: idle` and the hold-off starts; answering it → running again, disarm cancelled
- [ ] Ctrl-C a Claude turn → `activity: quiet turn … — registry idle, turn over` within ~35 s, then the hold-off, then `disarmed (activity ended)`
- [ ] Two Claude sessions, finish one → still armed; finish the other → hold-off then disarm
- [ ] Arm from the menu, then start and finish a command → never disarms; `koffeelid off` while a command runs → stays off (`auto-arm suppressed until the next activity` in status) until the next command begins
- [ ] Switch the feature off in Settings while auto-armed → `disarmed (activity auto-arm disabled)`
- [ ] Low battery below the threshold on battery while running → auto-arm blocked once (`auto-arm blocked; waiting for the next activity`, one notification), no repeat every 15 s
- [ ] `kill -9` the app while auto-armed with a command running; watchdog relaunch → `activity: replayed N events …`, `auto-armed (activity)` again
- [ ] `koffeelid uninstall-hooks` → `Removed KoffeeLid hooks.`; `~/.claude/settings.json.backup-koffeelid` exists
```

- [ ] **Step 4: platform-notes.md** — add a short section "Claude Code hooks and registry" recording the three externally-owned surfaces this relies on (hook events and payload keys, `<config>/sessions/<pid>.json` with `pid/sessionId/status/statusUpdatedAt`, `CLAUDE_CONFIG_DIR`), that all three are undocumented upstream and were verified through MySidepulse on 2026-08-26, and the canary log lines (`no registry record`, `hooks look dead`).

- [ ] **Step 5: CLAUDE.md and README** — CLAUDE.md: add `install-hooks | uninstall-hooks | shell-init zsh` to the CLI line under "Commands"; add a fifth target row `KoffeeLidHook (Hook/Sources/main.swift)` to the architecture table; add invariant 11: *"Auto-arm owns only its own arm: `ArmSource.activity` may arm only from Off and `disarm(source: .activity)` only fires while `armSource == .activity`; every other source hands the arm to the user (`ActivityArmPolicy`). Timings in `ActivityConstants` were sized from recorded Claude Code journals — retune only against evidence."*; update the test count in "Status and open items" and add a bullet for the feature with the hooks-install and `.zshrc` steps still to be done by the user. README: add the feature to the feature list, the three CLI verbs, and update the static test badge count to the new total from `swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1`.

- [ ] **Step 6: Version 0.1.0** — `App/Info.plist` `CFBundleShortVersionString`, `KoffeeLidCore.version`, `SmokeTests` assertion → `0.1.0`. Run `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 7: Install and end-to-end**

```bash
"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status         # must print mode: off; if not, STOP and ask the user
script/install.sh 2>&1 | tail -3
/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid install-hooks
/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid status
```
Expected: `Installed 15 Claude Code hooks -> /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook`, and the status line ends with `activity: 1 session working, 0 commands` a moment after the next hook event of the current Claude Code session (this very session fires them). If the user was in a mode other than off before the install, restore it (`koffeelid caffeinate` / `arm`). Leave the Settings switch **off**; turning it on and adding the `.zshrc` line are the user's calls, listed in `docs/manual-checks.md`. Do not run `uninstall-hooks` afterwards: the hooks are the deliverable.

- [ ] **Step 8: Commit** — `git add -A docs CLAUDE.md README.md App/Info.plist Sources/KoffeeLidCore/KoffeeLidCore.swift Tests/KoffeeLidCoreTests/SmokeTests.swift && git commit -m "docs(activity): architecture, development, manual checks, platform notes; version 0.1.0"`. Do not tag or push; report the test total and the manual checks still open.
