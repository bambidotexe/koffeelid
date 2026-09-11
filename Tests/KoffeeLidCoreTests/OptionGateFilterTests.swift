import XCTest
import KoffeeLidCore

final class OptionGateFilterTests: XCTestCase {
    func testTrustedAfterHoldSamples() {
        var g = OptionGateFilter(holdSamples: 2, staleClearSamples: 3, maxHoldSeconds: 20)
        XCTAssertFalse(g.feed(optionDown: true, now: 0))
        XCTAssertTrue(g.feed(optionDown: true, now: 0.03))
    }
    func testClearsAfterStaleSamples() {
        var g = OptionGateFilter(holdSamples: 1, staleClearSamples: 2, maxHoldSeconds: 20)
        XCTAssertTrue(g.feed(optionDown: true, now: 0))
        XCTAssertTrue(g.feed(optionDown: false, now: 0.03))   // one up sample: still trusted
        XCTAssertFalse(g.feed(optionDown: false, now: 0.06))  // second: cleared
    }
    func testStuckKeyExpires() {
        var g = OptionGateFilter(holdSamples: 1, staleClearSamples: 1, maxHoldSeconds: 5)
        XCTAssertTrue(g.feed(optionDown: true, now: 0))
        XCTAssertTrue(g.feed(optionDown: true, now: 4.9))
        XCTAssertFalse(g.feed(optionDown: true, now: 5.1))
        XCTAssertFalse(g.feed(optionDown: true, now: 6))     // stays expired while held
        _ = g.feed(optionDown: false, now: 7)
        XCTAssertTrue(g.feed(optionDown: true, now: 8))      // fresh press works again
    }
}
