import XCTest
import KoffeeLidCore

final class FrenchElisionTests: XCTestCase {
    func line(_ name: String) -> String { "Activé automatiquement tant que \(name) travaille" }

    func testElidesBeforeAVowelInitialWord() {
        XCTAssertEqual(FrenchElision.elideQue(in: line("une commande")), "Activé automatiquement tant qu’une commande travaille")
        XCTAssertEqual(FrenchElision.elideQue(in: line("OpenCode")), "Activé automatiquement tant qu’OpenCode travaille")
    }
    func testDoesNotElideBeforeAConsonantInitialWord() {
        XCTAssertEqual(FrenchElision.elideQue(in: line("Claude Code")), line("Claude Code"))
        XCTAssertEqual(FrenchElision.elideQue(in: line("Codex")), line("Codex"))
    }
    func testAccentedAndUppercaseVowelsElideToo() {
        XCTAssertEqual(FrenchElision.elideQue(in: "tant que Étrange tourne"), "tant qu’Étrange tourne")
        XCTAssertEqual(FrenchElision.elideQue(in: "tant que île tourne"), "tant qu’île tourne")
        XCTAssertEqual(FrenchElision.elideQue(in: "tant que Yolo tourne"), "tant qu’Yolo tourne")
    }
    func testLeavesTextWithNoStandaloneQueAlone() {
        XCTAssertEqual(FrenchElision.elideQue(in: "Activé automatiquement, fin dans %@"), "Activé automatiquement, fin dans %@")
        XCTAssertEqual(FrenchElision.elideQue(in: ""), "")
    }
    func testDoesNotMatchQueInsideALongerWord() {
        // "automatiquement" ends in "que" with no following space: not the standalone word "que".
        XCTAssertEqual(FrenchElision.elideQue(in: "automatiquement une chose"), "automatiquement une chose")
        XCTAssertEqual(FrenchElision.elideQue(in: "une bibliothèque immense"), "une bibliothèque immense")
    }
    func testElidesEveryStandaloneOccurrence() {
        XCTAssertEqual(FrenchElision.elideQue(in: "que un et que Un"), "qu’un et qu’Un")
    }
}
