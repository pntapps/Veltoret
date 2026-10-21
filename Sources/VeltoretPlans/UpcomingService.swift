import Foundation
import VeltoretKit

/// Android's UpcomingWorker. Once a day around 10 AM (and once at start): refreshes the next episode of shows the
/// user follows (on the Watchlist or started) that are still airing, and posts "New episode of …" for Watchlist
/// shows airing today. Library scans refresh shows only weekly, which is too slow for air dates.
public final class UpcomingService: @unchecked Sendable {
    /// A bit under a day, so the daily run always refreshes.
    public static let refreshMs: Int64 = 20 * 60 * 60 * 1000
    public static let maxAlerted = 200

    private let plans: PlansRepository
    private let catalog: CatalogDao
    private let watch: WatchDao
    private let settings: SettingsStore
    private let refreshShow: (Int) async throws -> Void
    private let isOnline: () -> Bool
    private let localNow: () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var running = false
    private var waitingForNetwork = false
    private var timer: DispatchSourceTimer?
    private var target = Date.distantFuture
    private var _notifier: PlanNotifier?

    /// - Parameter refreshShow: refetches /tv/{id} (TmdbRepository.ensureShow with the 20 h limit).
    public init(plans: PlansRepository, catalog: CatalogDao, watch: WatchDao, settings: SettingsStore,
                refreshShow: @escaping (Int) async throws -> Void, isOnline: @escaping () -> Bool,
                localNow: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.plans = plans
        self.catalog = catalog
        self.watch = watch
        self.settings = settings
        self.refreshShow = refreshShow
        self.isOnline = isOnline
        self.localNow = localNow
        self.calendar = calendar
    }

    /// Falls back to `plans.notifier` when nil.
    public var notifier: PlanNotifier? {
        get { lock.lock(); defer { lock.unlock() }; return _notifier }
        set { lock.lock(); _notifier = newValue; lock.unlock() }
    }

    /// Runs once now (or as soon as the network is back), then daily at the next 10:00.
    public func start() {
        lock.lock()
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "veltoret.upcoming"))
            t.schedule(wallDeadline: .distantFuture)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                // Wake-ups before 10:00 only re-aim the timer.
                self.lock.lock(); let target = self.target; self.lock.unlock()
                if self.localNow() >= target { self.runWhenOnline() }
                self.armDaily()
            }
            t.resume()
            timer = t
        }
        lock.unlock()
        armDaily()
        runWhenOnline()
    }

    /// Call when the network comes back: a run that was due while offline happens now.
    public func onOnline() {
        lock.lock(); let waiting = waitingForNetwork; lock.unlock()
        if waiting { runWhenOnline() }
    }

    private func armDaily() {
        let now = localNow()
        var next = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: calendar.startOfDay(for: now))!
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next)! }
        // Re-aim at least every 6 hours so sleep and clock changes don't skip a day.
        let waitMs = min(next.timeIntervalSince(now) * 1000, 6 * 3600 * 1000)
        lock.lock()
        target = next
        timer?.schedule(wallDeadline: .now() + .milliseconds(Int(max(waitMs, 1000))))
        lock.unlock()
    }

    private func runWhenOnline() {
        guard isOnline() else {
            lock.lock(); waitingForNetwork = true; lock.unlock()
            return
        }
        lock.lock(); waitingForNetwork = false; lock.unlock()
        Task.detached { [self] in
            do { try await run() } catch { Log.error(error, "Upcoming episodes") }
        }
    }

    /// The worker's doWork. Public for tests and for a manual refresh. A run while one is going is skipped.
    public func run() async throws {
        let began: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        if !began { return }
        defer { lock.withLock { running = false } }

        let current = settings.current
        if !current.onboardingComplete { return }
        let today = LocalDate(localNow(), calendar: calendar)

        let watchlistShows = Set(try plans.watchlist().filter { $0.mediaType == Plans.tv }.map(\.mediaId))
        var followed = watchlistShows
        followed.formUnion(try watch.watchedShowIds())

        let nowMs = nowMillis()
        for id in followed.sorted() {
            guard let show = try catalog.show(id) else { continue }
            if !Plans.stillAiring(show.status) && show.nextEpisodeAirDate == nil { continue }
            if nowMs - show.updatedAt < Self.refreshMs { continue }
            do { try await refreshShow(id) } catch {
                // Per show: one failure doesn't stop the rest.
                Log.error(error, "Refreshing show \(id)")
            }
        }

        if current.newEpisodeAlerts { try await checkAlerts(watchlistShows.sorted(), today: today) }
    }

    private func checkAlerts(_ watchlistShows: [Int], today: LocalDate) async throws {
        let day = today.description
        // "2026-10-23|showId:season:episode": the date prefix sorts, so pruning keeps the newest.
        let before = settings.current.alertedEpisodes
        var alerted = Set(before)
        var added = false
        for id in watchlistShows {
            guard let show = try catalog.show(id), show.nextEpisodeAirDate == day else { continue }
            let key = Self.alertKey(day: day, showId: id, season: show.nextEpisodeSeason, episode: show.nextEpisodeNumber)
            if alerted.contains(key) { continue }
            guard let notifier = notifier ?? plans.notifier, notifier.canPostNow else { continue }
            do { try await notifier.showNewEpisode(show) } catch { Log.error(error, "New episode alert") }
            alerted.insert(key)
            added = true
        }
        let pruned = Self.prune(alerted)
        if added || pruned.count != before.count {
            settings.update { $0.alertedEpisodes = pruned }
        }
    }

    /// Kotlin prints a null Int as "null" in a string template; keys keep that spelling.
    public static func alertKey(day: String, showId: Int, season: Int?, episode: Int?) -> String {
        "\(day)|\(showId):\(season.map(String.init) ?? "null"):\(episode.map(String.init) ?? "null")"
    }

    /// The newest 200 keys (ordinal sort, keep the last).
    public static func prune<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        let sorted = keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        return sorted.count <= maxAlerted ? sorted : Array(sorted.suffix(maxAlerted))
    }

    public func dispose() {
        lock.lock(); let t = timer; timer = nil; lock.unlock()
        t?.cancel()
    }
}
