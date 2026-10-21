import XCTest
import VeltoretKit
@testable import VeltoretPlans

/// Port of the Android/Windows PlansTest.
final class PlansTests: XCTestCase {
    // A Monday.
    private let monday = LocalDate(year: 2026, month: 10, day: 19)

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ d: LocalDate, _ h: Int, _ m: Int) -> Date {
        utc.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: h, minute: m))!
    }

    private func utcMs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    func testQuickTimesOfferTonightOnlyWhileItsAhead() {
        XCTAssertEqual(["Tonight, 8 PM", "Tomorrow, 8 PM", "Saturday, 8 PM"],
                       Plans.quickTimes(at(monday, 15, 0), calendar: utc).map(\.label))
        XCTAssertEqual(["Tomorrow, 8 PM", "Saturday, 8 PM"],
                       Plans.quickTimes(at(monday, 21, 0), calendar: utc).map(\.label))
    }

    func testQuickTimesSkipSaturdayWhenItIsTomorrow() {
        let times = Plans.quickTimes(at(LocalDate(year: 2026, month: 10, day: 23), 10, 0), calendar: utc)
        XCTAssertEqual(["Tonight, 8 PM", "Tomorrow, 8 PM"], times.map(\.label))
        XCTAssertEqual(at(LocalDate(year: 2026, month: 10, day: 24), 20, 0), times[1].at)
    }

    func testQuickTimesOnSaturdayMeanNextWeek() {
        let times = Plans.quickTimes(at(LocalDate(year: 2026, month: 10, day: 24), 10, 0), calendar: utc)
        XCTAssertEqual(at(LocalDate(year: 2026, month: 10, day: 31), 20, 0), times[2].at)
    }

    func testAirLabels() {
        XCTAssertEqual("Today", Plans.airLabel("2026-10-19", today: monday))
        XCTAssertEqual("Tomorrow", Plans.airLabel("2026-10-20", today: monday))
        XCTAssertEqual("Friday", Plans.airLabel("2026-10-23", today: monday))
        XCTAssertEqual("Mon, Oct 26", Plans.airLabel("2026-10-26", today: monday))
        XCTAssertNil(Plans.airLabel("2026-10-18", today: monday))
        XCTAssertNil(Plans.airLabel("", today: monday))
        XCTAssertNil(Plans.airLabel("not a date", today: monday))
    }

    func testUpcomingIncludesToday() {
        XCTAssertTrue(Plans.isUpcoming("2026-10-19", today: monday))
        XCTAssertTrue(Plans.isUpcoming("2027-01-01", today: monday))
        XCTAssertFalse(Plans.isUpcoming("2026-10-18", today: monday))
        XCTAssertFalse(Plans.isUpcoming(nil, today: monday))
    }

    func testReminderLabels() {
        let now = at(monday, 12, 0)
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertEqual("Today at 8:00 PM", Plans.reminderLabel(utcMs(at(monday, 20, 0)), now: now, timeZone: tz))
        XCTAssertEqual("Tomorrow at 9:30 AM", Plans.reminderLabel(utcMs(at(monday.adding(days: 1), 9, 30)), now: now, timeZone: tz))
        XCTAssertEqual("Fri, Oct 23 at 8:00 PM", Plans.reminderLabel(utcMs(at(monday.adding(days: 4), 20, 0)), now: now, timeZone: tz))
    }

    func testOverdueRemindersFireWithinTwelveHoursThenDrop() {
        let now: Int64 = 1_000_000_000_000
        XCTAssertEqual(.schedule, Plans.due(now + 60_000, now: now))
        XCTAssertEqual(.fireNow, Plans.due(now - 60_000, now: now))
        XCTAssertEqual(.fireNow, Plans.due(now - Plans.staleAfterMs, now: now))
        XCTAssertEqual(.drop, Plans.due(now - Plans.staleAfterMs - 1, now: now))
    }

    func testStillAiringStatuses() {
        XCTAssertTrue(Plans.stillAiring("Returning Series"))
        XCTAssertTrue(Plans.stillAiring("In Production"))
        XCTAssertFalse(Plans.stillAiring("Ended"))
        XCTAssertFalse(Plans.stillAiring("Canceled"))
        XCTAssertFalse(Plans.stillAiring(nil))
    }

    func testToMillisRoundTrips() {
        let t = at(monday, 20, 0)
        XCTAssertEqual(utcMs(t), Plans.toMillis(DateComponents(year: 2026, month: 10, day: 19, hour: 20, minute: 0),
                                                 timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(utcMs(t), Plans.toMillis(t))
    }

    func testEpisodeCodes() {
        XCTAssertEqual("S3 · E2", PlanFormat.episodeCode(3, 2))
        XCTAssertEqual("Special 4", PlanFormat.episodeCode(0, 4))
        XCTAssertEqual("", PlanFormat.episodeCode(nil, 4))
        XCTAssertEqual("2h 46m", PlanFormat.runtime(166))
        XCTAssertEqual("Oct 23, 2026", PlanFormat.date("2026-10-23"))
    }
}
