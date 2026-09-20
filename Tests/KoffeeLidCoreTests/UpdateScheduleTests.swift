import XCTest
import KoffeeLidCore

final class UpdateScheduleTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let week: TimeInterval = 7 * 24 * 3600

    func testAFreshScheduleIsDueSoTheLaunchCheckRuns() {
        XCTAssertTrue(UpdateSchedule().isDue(now: launch))
    }
    func testAnAnswerHoldsTheNextCheckForAWeek() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        XCTAssertFalse(schedule.isDue(now: launch + week - 1))
        XCTAssertTrue(schedule.isDue(now: launch + week))
    }
    func testAFailureIsTriedAgainAnHourLater() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch)
        XCTAssertFalse(schedule.isDue(now: launch + hour - 1))
        XCTAssertTrue(schedule.isDue(now: launch + hour))
    }
    func testAFailureAfterAWeekWaitsItsHourToo() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        schedule.failed(at: launch + week)
        XCTAssertFalse(schedule.isDue(now: launch + week + 60))
        XCTAssertTrue(schedule.isDue(now: launch + week + hour))
    }
    func testAnAnswerClearsTheFailureBeforeIt() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch)
        schedule.answered(at: launch + 60)
        XCTAssertFalse(schedule.isDue(now: launch + hour))
        XCTAssertTrue(schedule.isDue(now: launch + 60 + week))
    }
    func testAClockSetBackMakesTheCheckDueRatherThanLate() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        XCTAssertTrue(schedule.isDue(now: launch - 60))
    }
    func testAFailureDatedInTheFutureDoesNotHoldTheCheck() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch + 10 * hour)
        XCTAssertTrue(schedule.isDue(now: launch))
    }
    func testTheTickIsShortEnoughToMeetTheRetry() {
        XCTAssertLessThan(UpdateSchedule.tick, UpdateSchedule.retryDelay)
        XCTAssertEqual(UpdateSchedule.interval, week)
    }
}
