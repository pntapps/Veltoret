import XCTest
import VeltoretKit
@testable import VeltoretPlans

/// Fire-once, restore, snooze and new-episode alert rules against a real (in-memory) SQLite database.
final class PlansRepositoryTests: XCTestCase {
    final class FakeNotifier: PlanNotifier, @unchecked Sendable {
        private let lock = NSLock()
        var canPostNow = true
        private(set) var reminders: [ReminderEntity] = []
        private(set) var episodes: [ShowEntity] = []
        func showReminder(_ reminder: ReminderEntity) async throws { lock.withLock { reminders.append(reminder) } }
        func showNewEpisode(_ show: ShowEntity) async throws { lock.withLock { episodes.append(show) } }
    }

    final class FakeAlarms: ReminderAlarms {
        var scheduled = Set<Int64>()
        func schedule(_ reminder: ReminderEntity) { scheduled.insert(reminder.id) }
        func cancel(_ id: Int64) { scheduled.remove(id) }
    }

    private var now: Int64 = 1_800_000_000_000
    private var repo: PlansRepository!
    private var notifier: FakeNotifier!
    private var alarms: FakeAlarms!

    override func setUpWithError() throws {
        try AppServices.initForTests()
        notifier = FakeNotifier()
        alarms = FakeAlarms()
        repo = PlansRepository(AppServices.plansDao, now: { [unowned self] in self.now })
        repo.notifier = notifier
        repo.alarms = alarms
    }

    func testNewReminderSchedulesAndAddsToWatchlist() throws {
        let id = try repo.addReminder(type: Plans.movie, id: 5, season: nil, episode: nil, title: "Dune", atMs: now + 60_000, addToWatchlist: true)
        XCTAssertTrue(alarms.scheduled.contains(id))
        XCTAssertTrue(try repo.isInWatchlist(type: Plans.movie, id: 5))
    }

    func testSnoozeDoesNotTouchTheWatchlist() throws {
        try repo.snooze(type: Plans.tv, id: 8, season: 1, episode: 2, title: "Below · S1 · E2")
        XCTAssertFalse(try repo.isInWatchlist(type: Plans.tv, id: 8))
        let all = try repo.reminders()
        XCTAssertEqual(1, all.count)
        XCTAssertEqual(now + PlansRepository.snoozeMs, all[0].at)
        XCTAssertEqual(2, all[0].episode)
    }

    func testFiresOnceEvenWhenCalledTwice() async throws {
        let id = try repo.addReminder(type: Plans.movie, id: 5, season: nil, episode: nil, title: "Dune", atMs: now - 1000, addToWatchlist: false)
        let repo = self.repo!
        async let a = repo.fire(id)
        async let b = repo.fire(id)
        async let c = repo.fire(id)
        let results = try await [a, b, c]
        XCTAssertEqual(1, results.filter { $0 }.count)
        XCTAssertEqual(1, notifier.reminders.count)
        XCTAssertTrue(try repo.reminders().isEmpty)
    }

    func testNotificationsOffKeepsTheRow() async throws {
        notifier.canPostNow = false
        let id = try repo.addReminder(type: Plans.movie, id: 5, season: nil, episode: nil, title: "Dune", atMs: now - 1000, addToWatchlist: false)
        let fired = try await repo.fire(id)
        XCTAssertFalse(fired)
        XCTAssertEqual(1, try repo.reminders().count)
        XCTAssertTrue(notifier.reminders.isEmpty)
    }

    func testRestoreSchedulesFutureFiresRecentDropsStale() async throws {
        let future = try repo.addReminder(type: Plans.movie, id: 1, season: nil, episode: nil, title: "Future", atMs: now + 60_000, addToWatchlist: false)
        let recent = try repo.addReminder(type: Plans.movie, id: 2, season: nil, episode: nil, title: "Recent", atMs: now - Plans.staleAfterMs, addToWatchlist: false)
        try repo.addReminder(type: Plans.movie, id: 3, season: nil, episode: nil, title: "Stale", atMs: now - Plans.staleAfterMs - 1, addToWatchlist: false)
        alarms.scheduled.removeAll()

        try await repo.restore()

        XCTAssertEqual([future], alarms.scheduled)
        XCTAssertEqual([recent], notifier.reminders.map(\.id))
        XCTAssertEqual([future], try repo.reminders().map(\.id))
    }

    func testRemoveCancelsTheAlarm() throws {
        let id = try repo.addReminder(type: Plans.movie, id: 1, season: nil, episode: nil, title: "Future", atMs: now + 60_000, addToWatchlist: false)
        try repo.removeReminder(id)
        XCTAssertTrue(alarms.scheduled.isEmpty)
        XCTAssertTrue(try repo.reminders().isEmpty)
    }

    func testSchedulerFiresDueReminders() async throws {
        let fired = expectation(description: "fired")
        let box = Box()
        let scheduler = ReminderScheduler(fire: { id in box.set(id); fired.fulfill() })
        defer { scheduler.dispose() }
        scheduler.schedule(ReminderEntity(id: 42, mediaType: Plans.movie, mediaId: 1, title: "", at: nowMillis() + 50, createdAt: 0))
        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(42, box.get())
    }

    func testNewEpisodeAlertsOncePerEpisodeForWatchlistShows() async throws {
        let catalog = AppServices.catalogDao!
        let settings = AppServices.settings!
        settings.update { $0.onboardingComplete = true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))!
        let day = "2026-10-19"
        let fresh = nowMillis()
        try catalog.upsertShow(ShowEntity(tmdbId: 8, name: "Below", status: "Returning Series", updatedAt: fresh, nextEpisodeSeason: 2, nextEpisodeNumber: 3, nextEpisodeAirDate: day))
        try catalog.upsertShow(ShowEntity(tmdbId: 9, name: "Not saved", status: "Returning Series", updatedAt: fresh, nextEpisodeAirDate: day))
        try catalog.upsertShow(ShowEntity(tmdbId: 10, name: "No numbers", status: "Returning Series", updatedAt: fresh, nextEpisodeAirDate: day))
        try repo.setWatchlist(type: Plans.tv, id: 8, on: true)
        try repo.setWatchlist(type: Plans.tv, id: 10, on: true)
        let refreshed = IntList()
        let upcoming = UpcomingService(plans: repo, catalog: catalog, watch: AppServices.watchDao, settings: settings,
                                       refreshShow: { refreshed.append($0) }, isOnline: { true }, localNow: { today },
                                       calendar: cal)

        try await upcoming.run()
        try await upcoming.run()

        XCTAssertEqual([8, 10], notifier.episodes.map(\.tmdbId).sorted())
        XCTAssertEqual([], refreshed.values) // refreshed less than 20 h ago
        XCTAssertEqual(["2026-10-19|10:null:null", "2026-10-19|8:2:3"], settings.current.alertedEpisodes)
    }

    func testStaleFollowedShowsAreRefreshed() async throws {
        let catalog = AppServices.catalogDao!
        let settings = AppServices.settings!
        settings.update { $0.onboardingComplete = true; $0.newEpisodeAlerts = false }
        let old = nowMillis() - UpcomingService.refreshMs - 1
        try catalog.upsertShow(ShowEntity(tmdbId: 1, name: "Airing", status: "Returning Series", updatedAt: old))
        try catalog.upsertShow(ShowEntity(tmdbId: 2, name: "Ended", status: "Ended", updatedAt: old))
        try catalog.upsertShow(ShowEntity(tmdbId: 3, name: "Not followed", status: "Returning Series", updatedAt: old))
        try repo.setWatchlist(type: Plans.tv, id: 1, on: true)
        try repo.setWatchlist(type: Plans.tv, id: 2, on: true)
        let refreshed = IntList()
        let upcoming = UpcomingService(plans: repo, catalog: catalog, watch: AppServices.watchDao, settings: settings,
                                       refreshShow: { refreshed.append($0) }, isOnline: { true })
        try await upcoming.run()
        XCTAssertEqual([1], refreshed.values)
    }

    func testPruneKeepsTheNewest200() {
        let keys = (0..<250).map { String(format: "2026-01-01|%03d:1:1", $0) }.reversed()
        let kept = UpcomingService.prune(keys)
        XCTAssertEqual(200, kept.count)
        XCTAssertEqual("2026-01-01|050:1:1", kept.first)
        XCTAssertEqual("2026-01-01|249:1:1", kept.last)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64?
    func set(_ v: Int64) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int64? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class IntList: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Int] = []
    func append(_ v: Int) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}
