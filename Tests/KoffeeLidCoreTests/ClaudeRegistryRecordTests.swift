import XCTest
import KoffeeLidCore

final class ClaudeRegistryRecordTests: XCTestCase {
    func testConfigDirIsDerivedFromTheTranscriptPath() {
        XCTAssertEqual(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/Users/x/.claude/projects/-Users-x-p/abc.jsonl")?.path, "/Users/x/.claude")
        XCTAssertEqual(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/tmp/cfg/projects/s/a.jsonl")?.path, "/tmp/cfg", "a relocated CLAUDE_CONFIG_DIR")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/tmp/a.jsonl"), "no projects folder")
        XCTAssertEqual(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/Users/x/projects/p/.claude/projects/-Users-x-projects-p/abc.jsonl")?.path,
                       "/Users/x/projects/p/.claude", "the projects folder above the file's own folder, not one in the working directory")
        XCTAssertEqual(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/Users/x/.claude/projects/-Users-x-p/abc/subagents/agent-1.jsonl")?.path,
                       "/Users/x/.claude", "a helper's transcript sits deeper in the same folder")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/Users/x/.claude/projects/abc.jsonl"), "a transcript sits in a project's folder")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: "Users/x/.claude/projects/s/a.jsonl"), "absolute only")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/Users/x/../y/.claude/projects/s/a.jsonl"), "no . or .. component")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: "/projects/s/a.jsonl"), "no folder above projects")
        XCTAssertNil(ClaudeRegistryRecord.configDir(fromTranscriptPath: ""))
    }
}
