import XCTest
import KoffeeLidCore

final class WatchdogSupportTests: XCTestCase {
    func testCrashLoopGuardAllowsUpToMaxWithinWindow() {
        var g = CrashLoopGuard(maxRelaunches: 3, window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(g.permitRelaunch(at: t0))
        XCTAssertTrue(g.permitRelaunch(at: t0.addingTimeInterval(10)))
        XCTAssertTrue(g.permitRelaunch(at: t0.addingTimeInterval(20)))
        XCTAssertFalse(g.permitRelaunch(at: t0.addingTimeInterval(30)))
        XCTAssertEqual(g.history.count, 3)
    }
    func testCrashLoopGuardForgetsOldEntries() {
        var g = CrashLoopGuard(maxRelaunches: 1, window: 60)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(g.permitRelaunch(at: t0))
        XCTAssertFalse(g.permitRelaunch(at: t0.addingTimeInterval(30)))
        XCTAssertTrue(g.permitRelaunch(at: t0.addingTimeInterval(61)))
    }
    func testPidFileRoundTrip() {
        let r = PidFileRecord(pid: 819, executablePath: "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid")
        XCTAssertEqual(r.serialized, "819\n/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid\n")
        XCTAssertEqual(PidFileRecord(contents: r.serialized), r)
        XCTAssertNil(PidFileRecord(contents: "garbage"))
        XCTAssertNil(PidFileRecord(contents: ""))
    }
    func testRelaunchHistoryStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rh-\(UUID().uuidString).json")
        let store = RelaunchHistoryStore(url: url)
        XCTAssertEqual(store.load(), [])
        let dates = [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)]
        try store.save(dates)
        XCTAssertEqual(store.load(), dates)
    }
}
