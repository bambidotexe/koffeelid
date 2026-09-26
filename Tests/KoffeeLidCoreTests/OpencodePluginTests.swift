import XCTest
import KoffeeLidCore

/// `~/.config/opencode/plugins/koffeelid.js`: the plugin source Core generates, tested for shape (the source
/// was tested by hand against a real OpenCode 2.0.17 server; `OpencodePluginExecutedTests` runs the generated
/// source itself, under node, against a synthetic event stream).
final class OpencodePluginTests: XCTestCase {
    let hookPath = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"

    func testSourceEmbedsTheHookCommandAndThePluginId() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertTrue(source.contains(#"const COMMAND = ["\#(hookPath)", "hook", "opencode"]"#))
        XCTAssertTrue(source.contains(#"const ID = "dev.rubens.koffeelid.opencode""#))
        XCTAssertTrue(source.contains("export default {"))
        XCTAssertTrue(source.contains("setup(ctx)"), "the v2 shape; a v1-style plugin fails to load")
        XCTAssertTrue(source.contains("ctx.event.subscribe"))
    }
    func testLocationShutdownIsDroppedFromForwardedAndNoDirectoryFieldRemains() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertFalse(source.contains("\"location.shutdown\""), "dropped from FORWARDED, per the brief's two changes")
        XCTAssertFalse(source.contains("out.directory"), "no path leaves OpenCode")
        XCTAssertFalse(source.contains("data.location"), "no path leaves OpenCode")
    }
    func testRootOfWalksParentsToTheTopWithACappedCycleGuard() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertTrue(source.contains("function rootOf(state, id)"))
        XCTAssertTrue(source.contains("i < 16"), "capped so a cycle cannot loop forever")
    }
    func testSourceIsStableForTheSameHookPath() {
        XCTAssertEqual(OpencodePlugin.source(hookPath: hookPath), OpencodePlugin.source(hookPath: hookPath))
    }
    func testIsOursRecognisesTheMarkerAndTheId() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertTrue(OpencodePlugin.isOurs(source))
        XCTAssertTrue(OpencodePlugin.isOurs(OpencodePlugin.source(hookPath: "/Volumes/x/KoffeeLid.app/Contents/MacOS/KoffeeLidHook")),
                      "ours whatever the bundle path, the marker and the id are what count")
        XCTAssertFalse(OpencodePlugin.isOurs("export default { id: \"someone.else\", setup() {} }"))
        XCTAssertFalse(OpencodePlugin.isOurs(""))
    }
    func testIsCurrentIsByteForByteAgainstTodaysSource() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertTrue(OpencodePlugin.isCurrent(source, hookPath: hookPath))
        XCTAssertFalse(OpencodePlugin.isCurrent(source, hookPath: "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"),
                       "a file installed from a different bundle path is ours but not current")
        XCTAssertFalse(OpencodePlugin.isCurrent(source + "\n// tampered", hookPath: hookPath))
    }
    func testHookPathIsJSONEncodedAgainstQuotesAndBackslashes() throws {
        let tricky = #"/Applications/Weird "App"\Name.app/Contents/MacOS/KoffeeLidHook"#
        let source = OpencodePlugin.source(hookPath: tricky)
        let line = try XCTUnwrap(source.split(separator: "\n").first { $0.hasPrefix("const COMMAND = ") })
        let jsonPart = String(line).replacingOccurrences(of: "const COMMAND = ", with: "")
        let array = try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String]
        XCTAssertEqual(array, [tricky, "hook", "opencode"], "the path must round-trip through the JSON the JS parses")
    }
    func testHookPathsSlashesStayUnescapedSoIsOursStillMatches() {
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertTrue(source.contains(#"["/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook", "hook", "opencode"]"#))
        XCTAssertTrue(OpencodePlugin.isOurs(source))
    }
    func testASessionsDeletedLinkIsKeptForAGrandchildStillToCome() {
        // Dropping a child→parent link on session.deleted would resolve a still-live grandchild's parent_id
        // to the deleted (middle) session instead of walking through it to the true root.
        let source = OpencodePlugin.source(hookPath: hookPath)
        XCTAssertFalse(source.contains("state.parents.delete"))
    }
}
