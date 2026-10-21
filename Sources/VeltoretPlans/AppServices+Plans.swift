import Foundation
import VeltoretKit

extension AppServices {
    /// Watchlist and reminders.
    public static var plans: PlansRepository!
    /// New-episode alerts and daily next-episode refresh.
    public static var upcoming: UpcomingService!
    /// In-process reminder timer (`plans.alarms`).
    public static var reminderScheduler: ReminderScheduler!
}
