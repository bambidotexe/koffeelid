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
