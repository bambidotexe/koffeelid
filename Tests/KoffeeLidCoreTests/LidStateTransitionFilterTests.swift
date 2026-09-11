import XCTest
import KoffeeLidCore

final class LidStateTransitionFilterTests: XCTestCase {
    func testFirstSampleSetsBaselineWithoutEvent() {
        var f = LidStateTransitionFilter(baselineClosed: nil)
        XCTAssertNil(f.feed(isClosed: false))
        XCTAssertEqual(f.isClosed, false)
    }
    func testUnchangedIsIgnored() {
        var f = LidStateTransitionFilter(baselineClosed: true)
        XCTAssertNil(f.feed(isClosed: true))
        XCTAssertNil(f.feed(isClosed: true))
    }
    func testOpenToClosedAndBack() {
        var f = LidStateTransitionFilter(baselineClosed: false)
        XCTAssertEqual(f.feed(isClosed: true), .closed)
        XCTAssertNil(f.feed(isClosed: true))
        XCTAssertEqual(f.feed(isClosed: false), .opened)
    }
}
