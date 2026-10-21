import Foundation
import VeltoretKit

/// VeltoretPlans module entry points (called by the app target).
/// Reminder scheduling (Windows option 1 of spec 5.3): an in-process timer while Veltoret runs (it stays in the menu
/// bar), plus `restore()` at every start, on wake from sleep and on clock / time zone changes.
public enum VeltoretPlansModule {
    /// Starts watching for wake / clock changes and returns something to keep alive. Replaceable (tests, previews).
    public static var observeSystemChanges: (@escaping @Sendable () -> Void) -> AnyObject? = { SystemChangeMonitor($0) }

    private static var systemMonitor: AnyObject?
    private static let subs = SubscriptionBag()
    private static var upcomingStarted = false
    private static let lock = NSLock()

    public static func initialize() {
        let plans = PlansRepository(AppServices.plansDao)
        AppServices.plans = plans
        let scheduler = ReminderScheduler(fire: { id in _ = try await AppServices.plans.fire(id) })
        AppServices.reminderScheduler = scheduler
        plans.alarms = scheduler
        AppServices.upcoming = UpcomingService(
            plans: plans, catalog: AppServices.catalogDao, watch: AppServices.watchDao, settings: AppServices.settings,
            refreshShow: { id in try await PlansCoreBridge.refreshShow(id) },
            isOnline: { PlansCoreBridge.isOnline() })
        // The notifier (UserNotifications) is set by FeatureSettings: `AppServices.plans.notifier = …`.
    }

    public static func start() {
        AppServices.settings.changed.subscribe { s in
            if s.onboardingComplete { startUpcoming() }
        }.store(in: subs)
        PlansCoreBridge.subscribeOnline { online in
            if online { AppServices.upcoming.onOnline() }
        }.map { $0.store(in: subs) }
        if AppServices.settings.current.onboardingComplete { startUpcoming() }
        systemMonitor = observeSystemChanges { restoreReminders() }
        restoreReminders()
    }

    public static func shutdown() {
        subs.cancelAll()
        (systemMonitor as? SystemChangeMonitor)?.stop()
        systemMonitor = nil
        AppServices.reminderScheduler?.dispose()
        AppServices.upcoming?.dispose()
    }

    private static func startUpcoming() {
        lock.lock()
        if upcomingStarted { lock.unlock(); return }
        upcomingStarted = true
        lock.unlock()
        AppServices.upcoming.start()
    }

    /// Restores reminders (start, wake, clock change): schedules what's ahead, shows what came due.
    public static func restoreReminders() {
        Task.detached {
            do { try await AppServices.plans.restore() } catch { Log.error(error, "Restoring reminders") }
        }
    }
}
