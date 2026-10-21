import AppKit
import Foundation
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// FeatureSettings module entry points (called by the app target): the Settings page and its own sections, the
/// notifier (UserNotifications), the menu bar item, "Open at login", plus `ReminderDialog`, `RemindersDialog`,
/// `VoiceSearch` and `OpenRequests` for other modules.
public enum FeatureSettingsModule {
    /// After VeltoretUI and VeltoretPlans initialized; before the app finishes launching (so a notification click
    /// that launched the app reaches the delegate).
    @MainActor
    public static func initialize() {
        PageRegistry.register(.settings) { _ in SettingsPage() }

        SettingsSections.register(id: "library", title: "Library", order: 100, icon: "books.vertical") { LibrarySection() }
        SettingsSections.register(id: "playback", title: "Playback", order: 400, icon: "play.circle") { PlaybackSection() }
        SettingsSections.register(id: "subtitles", title: "Subtitles", order: 410, icon: "captions.bubble") { SubtitlesSection() }
        SettingsSections.register(id: "notifications", title: "Reminders & alerts", order: 600, icon: "bell") {
            NotificationsSection()
        }
        SettingsSections.register(id: "appearance", title: "Appearance", order: 700, icon: "circle.lefthalf.filled") {
            AppearanceSection()
        }
        SettingsSections.register(id: "app", title: "App", order: 800, icon: "macwindow") { AppSection() }
        SettingsSections.register(id: "tmdb", title: "TMDB", order: 850, icon: "key") { TmdbSection() }
        SettingsSections.register(id: "about", title: "About", order: 900, icon: "info.circle") { AboutSection() }

        let notifier = MacNotifier.shared
        notifier.install()
        if MacNotifier.isSupported {
            AppServices.plans?.notifier = notifier
            AppServices.upcoming?.notifier = notifier
        }
    }

    /// After the main window shows: menu bar item, login item sync, notification permission check.
    @MainActor
    public static func start() {
        MenuBarController.shared.start()
        LoginItem.sync()
        MacNotifier.shared.refreshStatus()
    }

    @MainActor
    public static func shutdown() {
        MenuBarController.shared.stop()
    }
}
