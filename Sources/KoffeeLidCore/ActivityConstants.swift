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
    /// A transcript or rollout path. The ones on this Mac run about 100 characters; `metadataMaxChars` would
    /// cut a deep home or project folder, and a cut path names no file.
    public static let pathMaxChars = 1024
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
    /// Quiet before a working session is checked at its source: Claude Code's registry (Esc/Ctrl-C fire no
    /// hook there) or Codex's rollout (a lost `Stop` or `Interrupt` leaves nothing else to end the turn).
    public static let abandonQuietSeconds: TimeInterval = 20
    public static let abandonRecheckSeconds: TimeInterval = 15
    /// After an `Interrupt`, a tool or permission line without a turn id changes nothing for this long. Codex
    /// reported a tool's end 13 s after the abort on 2026-09-25; 120 s covers a process that ignores SIGTERM.
    public static let abortQuarantineSeconds: TimeInterval = 120
    /// Registry busy but no hook for this long: hooks for that session are dead; log once.
    public static let hooksSilentWarnSeconds: TimeInterval = 300
    /// A registry stamp this much newer than a dialog's start means the dialog was answered without a hook.
    public static let dialogAnswerMinStampLeadSeconds: TimeInterval = 2

    // Jobs (SidePulse §7).
    public static let jobStaleSeconds: TimeInterval = 2 * 3600
    /// Commands shorter than this never count (KoffeeLid: never arm).
    public static let jobArmAfterDefaultSeconds: TimeInterval = 5

    // KoffeeLid's own.
    /// Between "nothing runs any more" and the auto-disarm, per kind that ran during the arm (the longest
    /// wins). A finished Claude Code or Codex turn usually has its user on the other end of a remote
    /// connection, about to prompt again — and a sleeping Mac would drop that connection — so it waits half
    /// an hour; a finished command has nothing left to wait for.
    public static let holdOffDefaults: [ActivityKind: TimeInterval] = [.claude: 30 * 60, .codex: 30 * 60, .terminal: 60]
    /// "Disarm once finished": the wait after the work ends, so a turn that picks itself back up is not cut short.
    public static let disarmOnceHoldOffSeconds: TimeInterval = 60

    // Journal rotation.
    public static let journalRotateIdleBytes = 5 * 1024 * 1024
    public static let journalRotateHardBytes = 20 * 1024 * 1024
}
