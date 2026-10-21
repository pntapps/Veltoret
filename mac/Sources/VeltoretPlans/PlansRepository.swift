import Foundation
import VeltoretKit

/// Posts reminder and new-episode notifications (Windows: IPlanNotifier). The real implementation
/// (UserNotifications: "Time for …" with artwork, actions Play / Snooze 1 hour) lives in FeatureSettings and is
/// set with `AppServices.plans.notifier = …`. It builds the content itself (title, body, artwork URL, `OpenTarget`).
public protocol PlanNotifier: AnyObject {
    /// False when notifications are off for Veltoret (reminders then stay pending).
    var canPostNow: Bool { get }
    func showReminder(_ reminder: ReminderEntity) async throws
    func showNewEpisode(_ show: ShowEntity) async throws
}

/// Identifiers shared by the notifier and whoever handles a click.
public enum PlanNotificationIds {
    /// Category of reminder notifications (actions Play / Snooze 1 hour).
    public static let reminderCategory = "reminder"
    /// Category of "New episode of …" notifications.
    public static let newEpisodeCategory = "new-episode"
    /// Action "Play".
    public static let playAction = "play"
    /// Action "Snooze 1 hour".
    public static let snoozeAction = "snooze"
    public static let playTitle = "Play"
    public static let snoozeTitle = "Snooze 1 hour"
}

/// Does nothing and can't post, so reminders stay pending until a real notifier is set.
public final class NoopPlanNotifier: PlanNotifier {
    public init() {}
    public var canPostNow: Bool { false }
    public func showReminder(_ reminder: ReminderEntity) async throws {}
    public func showNewEpisode(_ show: ShowEntity) async throws {}
}

/// Wakes the repository when a reminder comes due (Android: AlarmManager; here ReminderScheduler).
public protocol ReminderAlarms: AnyObject {
    func schedule(_ reminder: ReminderEntity)
    func cancel(_ id: Int64)
}

/// The watchlist ("Watch later") and reminders ("Remind me"), Android's PlansRepository. Reminders fire through
/// `ReminderAlarms` while Veltoret runs (it stays in the menu bar); `restore()` at every start shows the ones that
/// came due while it wasn't running (up to 12 hours late) exactly once. Re-query on `db.changed`
/// ("watchlist", "reminders").
public final class PlansRepository: @unchecked Sendable {
    /// "Snooze 1 hour".
    public static let snoozeMs: Int64 = 60 * 60 * 1000

    private let dao: PlansDao
    private let now: () -> Int64
    private let lock = NSLock()
    private var _notifier: PlanNotifier?
    private var _alarms: ReminderAlarms?

    public init(_ dao: PlansDao, now: @escaping () -> Int64 = nowMillis) {
        self.dao = dao
        self.now = now
    }

    public var notifier: PlanNotifier? {
        get { lock.lock(); defer { lock.unlock() }; return _notifier }
        set { lock.lock(); _notifier = newValue; lock.unlock() }
    }

    public var alarms: ReminderAlarms? {
        get { lock.lock(); defer { lock.unlock() }; return _alarms }
        set { lock.lock(); _alarms = newValue; lock.unlock() }
    }

    // MARK: Watchlist

    public func isInWatchlist(type: String, id: Int) throws -> Bool { try dao.isInWatchlist(type, id) }

    /// Newest first.
    public func watchlist() throws -> [WatchlistEntity] { try dao.watchlist() }

    public func setWatchlist(type: String, id: Int, on: Bool) throws {
        if on {
            try dao.addToWatchlist(WatchlistEntity(mediaType: type, mediaId: id, addedAt: now()))
        } else {
            try dao.removeFromWatchlist(type, id)
        }
    }

    // MARK: Reminders

    /// All pending reminders, soonest first.
    public func reminders() throws -> [ReminderEntity] { try dao.reminders() }

    public func remindersFor(type: String, id: Int) throws -> [ReminderEntity] { try dao.remindersFor(type, id) }

    @discardableResult
    public func addReminder(type: String, id: Int, season: Int?, episode: Int?, title: String, at: Date) throws -> Int64 {
        try addReminder(type: type, id: id, season: season, episode: episode, title: title, atMs: Plans.toMillis(at),
                        addToWatchlist: true)
    }

    /// Saves and schedules a reminder; a new one also puts the title on the watchlist (a snooze doesn't).
    @discardableResult
    public func addReminder(type: String, id: Int, season: Int?, episode: Int?, title: String, atMs: Int64,
                            addToWatchlist: Bool = true) throws -> Int64 {
        var r = ReminderEntity(mediaType: type, mediaId: id, season: season, episode: episode, title: title,
                               at: atMs, createdAt: now())
        r.id = try dao.insertReminder(r)
        alarms?.schedule(r)
        if addToWatchlist, try !dao.isInWatchlist(type, id) { try setWatchlist(type: type, id: id, on: true) }
        return r.id
    }

    /// "Snooze 1 hour" on a reminder notification: the same reminder an hour from now, without touching the watchlist.
    @discardableResult
    public func snooze(type: String, id: Int, season: Int?, episode: Int?, title: String) throws -> Int64 {
        try addReminder(type: type, id: id, season: season, episode: episode, title: title,
                        atMs: now() + Self.snoozeMs, addToWatchlist: false)
    }

    public func removeReminder(_ id: Int64) throws {
        try dao.deleteReminder(id)
        alarms?.cancel(id)
    }

    /// Shows a due reminder exactly once: the timer, app start and wake can all find the same row at the same
    /// time, and only the caller whose delete removes it posts the notification. When notifications are off the
    /// row is kept (Settings shows it with a warning) until it goes stale.
    @discardableResult
    public func fire(_ id: Int64) async throws -> Bool {
        guard let r = try dao.reminder(id) else { return false }
        guard let notifier, notifier.canPostNow else { return false }
        if try dao.deleteReminder(id) == 0 { return false }
        do { try await notifier.showReminder(r) } catch {
            // The row is gone either way: never show it twice.
            Log.error(error, "Showing a reminder")
        }
        return true
    }

    /// Schedules what's ahead, drops what's more than 12 hours late, and returns what's slightly late.
    @discardableResult
    public func rescheduleAll() throws -> [ReminderEntity] {
        let now = now()
        var overdue: [ReminderEntity] = []
        for r in try dao.reminders() {
            switch Plans.due(r.at, now: now) {
            case .schedule: alarms?.schedule(r)
            case .fireNow: overdue.append(r)
            case .drop: try dao.deleteReminder(r.id)
            }
        }
        return overdue
    }

    /// Every start (and after the Mac wakes or the clock changes): `rescheduleAll()`, then shows what came due.
    public func restore() async throws {
        for r in try rescheduleAll() { try await fire(r.id) }
    }
}
