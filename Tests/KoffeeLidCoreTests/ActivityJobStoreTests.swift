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
    func testTheRunningJobsShellsAreListedOnceEach() {
        store.begin(id: "a", pid: 7, label: "make", armAfterSeconds: 0, now: t0)
        store.begin(id: "b", pid: nil, label: nil, armAfterSeconds: 0, now: t0)
        store.begin(id: "c", pid: 9, label: "sleep", armAfterSeconds: 5, now: t0)
        XCTAssertEqual(store.runningOwnerPids(at: t0), [7], "a job without a shell has no pid; one not yet counted is not running")
        XCTAssertEqual(store.runningOwnerPids(at: at(5)), [7, 9])
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
        store.begin(id: "b", pid: nil, label: nil, armAfterSeconds: 0, now: t0)
        XCTAssertEqual(store.trackedPids, [7])
        store.processExited(pid: 7); XCTAssertEqual(Set(store.jobs.keys), ["b"])
        store.tick(now: at(7199)); XCTAssertEqual(store.jobs.count, 1)
        store.tick(now: at(7200)); XCTAssertTrue(store.jobs.isEmpty)
    }
    func testAJobWithAShellIsNeverDroppedByStaleness() {
        store.begin(id: "zsh-7", pid: 7, label: "make", armAfterSeconds: 0, now: t0)
        store.begin(id: "loose", pid: nil, label: nil, armAfterSeconds: 0, now: t0)
        store.tick(now: at(3 * 3600))
        XCTAssertEqual(Set(store.jobs.keys), ["zsh-7"], "a shell with a command in the foreground is asked, not timed out")
        XCTAssertTrue(store.isRunning(at: at(3 * 3600)))
    }
    func testAProbeThatFindsTheShellAtItsPromptDropsTheJob() {
        store.begin(id: "zsh-7", pid: 7, label: "sleep", armAfterSeconds: 0, now: t0)
        let prompt = ShellJobLiveness.Probe(alive: true, isShell: true, atPrompt: true, hasChildren: false)
        XCTAssertNil(store.probe(id: "zsh-7", prompt, now: at(15)))
        XCTAssertEqual(store.jobs["zsh-7"]?.promptSeenAt, at(15))
        XCTAssertEqual(store.nextDeadline(after: at(15)), at(15 + ActivityConstants.jobPromptSettleSeconds), "asked again once the settle has run")
        XCTAssertNil(store.probe(id: "zsh-7", prompt, now: at(17)))
        XCTAssertEqual(store.probe(id: "zsh-7", prompt, now: at(20)), "shell at its prompt")
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertNil(store.probe(id: "zsh-7", prompt, now: at(21)), "an unknown job is not dropped twice")
        store.begin(id: "zsh-8", pid: 8, label: "sleep", armAfterSeconds: 0, now: t0)
        let gone = ShellJobLiveness.Probe(alive: false, isShell: false, atPrompt: false, hasChildren: false)
        XCTAssertEqual(store.probe(id: "zsh-8", gone, now: at(1)), "shell gone")
        XCTAssertTrue(store.jobs.isEmpty)
    }
    func testNextDeadlineIsTheEarliestOfArmAfterTheProbeAndStaleness() {
        store.begin(id: "a", pid: 7, label: nil, armAfterSeconds: 5, now: t0)
        XCTAssertEqual(store.nextDeadline(after: t0), at(5))
        XCTAssertEqual(store.nextDeadline(after: at(6)), at(6 + ActivityConstants.jobProbeSeconds), "a job with a shell is asked every 15 s")
        var loose = ActivityJobStore()
        loose.begin(id: "b", pid: nil, label: nil, armAfterSeconds: 0, now: t0)
        XCTAssertEqual(loose.nextDeadline(after: at(6)), at(7200), "a job without a shell is only timed out")
        XCTAssertNil(ActivityJobStore().nextDeadline(after: t0))
    }
}
