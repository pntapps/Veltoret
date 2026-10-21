import AppKit
import SwiftUI
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// The live settings for SwiftUI: `model.binding(\.autoPlayNext)` reads and saves through `SettingsStore`.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var s: AppSettings
    private var sub: VeltoretKit.Subscription?

    init() {
        s = AppServices.settings?.current ?? AppSettings()
        sub = AppServices.settings?.changed.subscribe { [weak self] next in
            Task { @MainActor in if self?.s != next { self?.s = next } }
        }
    }

    func set<V>(_ key: WritableKeyPath<AppSettings, V>, _ value: V) {
        s[keyPath: key] = value
        AppServices.settings?.update { $0[keyPath: key] = value }
    }

    func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.s[keyPath: key] }, set: { self.set(key, $0) })
    }
}

/// Spec 2.2, in order.
enum Languages {
    static let all: [(String, String)] = [
        ("en", "English"), ("hi", "Hindi"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"),
        ("ta", "Tamil"), ("te", "Telugu"), ("ml", "Malayalam"), ("bn", "Bengali"), ("ur", "Urdu"), ("tr", "Turkish"),
    ]

    static func label(_ code: String) -> String {
        all.first { $0.0 == code }?.1 ?? code.uppercased(with: Locale(identifier: "en_US"))
    }
}

// MARK: - Playback

struct PlaybackSection: View {
    @StateObject private var m = SettingsModel()

    /// Only offered when a display can show HDR (EDR headroom above 1).
    private var hdrDisplay: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 }
    }

    var body: some View {
        SettingsPanel {
            SwitchRow("Auto-play next episode", subtitle: "Counts down at the end of an episode", isOn: m.binding(\.autoPlayNext))
            SettingsDivider()
            ChoiceRow("Skip button", options: [30, 60, 85, 90, 120].map { ($0, "+\($0)s") }, selected: m.s.skipSeconds) {
                m.set(\.skipSeconds, $0)
            }
            SettingsDivider()
            ChoiceRow("Seek step", options: [5, 10, 15, 30].map { ($0, "\($0)s") }, selected: m.s.seekSeconds) {
                m.set(\.seekSeconds, $0)
            }
            SettingsDivider()
            ChoiceRow("Preferred audio", options: Languages.all, selected: m.s.preferredAudioLanguage) {
                m.set(\.preferredAudioLanguage, $0)
            }
            SettingsDivider()
            ChoiceRow("Default subtitles", options: [("", "Off")] + Languages.all, selected: m.s.preferredSubtitleLanguage) {
                m.set(\.preferredSubtitleLanguage, $0)
            }
            if hdrDisplay {
                SettingsDivider()
                SwitchRow("HDR for HDR videos", subtitle: "Shows HDR videos in HDR on displays that support it",
                          isOn: m.binding(\.autoHdr))
            }
        }
    }
}

struct SubtitlesSection: View {
    @StateObject private var m = SettingsModel()
    var body: some View {
        SettingsPanel {
            ChoiceRow("Text size", options: [(Float(0.8), "Small"), (Float(1.0), "Normal"), (Float(1.25), "Large"),
                                             (Float(1.5), "Extra large")],
                      selected: m.s.subtitleScale) { m.set(\.subtitleScale, $0) }
            SettingsDivider()
            SwitchRow("Background box", subtitle: "Dark box behind subtitle text", isOn: m.binding(\.subtitleBackground))
        }
    }
}

// MARK: - Reminders & alerts

struct NotificationsSection: View {
    static let offWarning = "Notifications are off for Veltoret, so reminders can't appear. Turn them on in System Settings → Notifications."

    @StateObject private var m = SettingsModel()
    @StateObject private var reminders = RemindersModel()
    @StateObject private var permission = NotificationStatusModel()

    var body: some View {
        SettingsPanel {
            SwitchRow("New episode alerts", subtitle: "A notification on the day a show on your Watchlist airs a new episode",
                      isOn: Binding(get: { m.s.newEpisodeAlerts }, set: { on in
                          m.set(\.newEpisodeAlerts, on)
                          if on { Task { await MacNotifier.shared.requestAuthorizationIfNeeded() } }
                      }))
            SettingsDivider()
            permissionRow
            if reminders.reminders.isEmpty {
                SettingsDivider()
                SettingsNote("No reminders. Use \"Remind me\" on a movie, show or episode.")
            } else {
                if permission.status == .denied {
                    SettingsDivider()
                    SettingsNote(Self.offWarning, color: Theme.danger)
                }
                ForEach(reminders.reminders, id: \.id) { r in
                    SettingsDivider()
                    ReminderRow(reminder: r) { reminders.remove(r.id) }
                }
            }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch permission.status {
        case .allowed:
            SettingRow("Notifications", subtitle: "Allowed for Veltoret", icon: "bell.badge", chevron: false) {
                SystemSettingsLinks.open(SystemSettingsLinks.notifications)
            }
        case .denied:
            HStack(spacing: 12) {
                SettingRow("Notifications", subtitle: "Off for Veltoret", icon: "bell.slash", subtitleColor: Theme.danger)
                Button("Open System Settings") { SystemSettingsLinks.open(SystemSettingsLinks.notifications) }
                    .buttonStyle(.vText).padding(.trailing, 8)
            }
        case .notDetermined:
            HStack(spacing: 12) {
                SettingRow("Notifications", subtitle: "Veltoret hasn't asked yet", icon: "bell")
                Button("Allow") { Task { await MacNotifier.shared.requestAuthorization() } }
                    .buttonStyle(.vText).padding(.trailing, 8)
            }
        case .unknown:
            SettingRow("Notifications", subtitle: MacNotifier.isSupported ? "Checking…" : "Not available in this build",
                       icon: "bell")
        }
    }
}

// MARK: - Appearance / App

struct AppearanceSection: View {
    @StateObject private var m = SettingsModel()
    var body: some View {
        SettingsPanel {
            SwitchRow("Pure black", subtitle: "True black background for OLED screens", isOn: m.binding(\.oledBlack))
        }
    }
}

struct AppSection: View {
    @StateObject private var m = SettingsModel()
    @State private var needsApproval = LoginItem.needsApproval

    var body: some View {
        SettingsPanel {
            SwitchRow("Keep running in the menu bar",
                      subtitle: "Reminders, new episode alerts and scans keep working after you close the window",
                      isOn: m.binding(\.runInBackground))
            SettingsDivider()
            SwitchRow("Open at login", subtitle: "Opens in the menu bar when you log in",
                      isOn: Binding(get: { m.s.startAtLogin }, set: { on in
                          if LoginItem.set(on) {
                              m.set(\.startAtLogin, on)
                              needsApproval = LoginItem.needsApproval
                          } else {
                              Toast.show("macOS didn't allow that change")
                          }
                      }))
            if needsApproval && m.s.startAtLogin {
                HStack {
                    Text("Approve Veltoret in System Settings → General → Login Items.").vBodySmall(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open") { SystemSettingsLinks.open(SystemSettingsLinks.loginItems) }.buttonStyle(.vText)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            SettingsDivider()
            SwitchRow("Show in menu bar", subtitle: "Open Veltoret, scan and see reminders from the menu bar",
                      isOn: m.binding(\.showMenuBarItem))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            needsApproval = LoginItem.needsApproval
        }
    }
}

// MARK: - TMDB

struct TmdbSection: View {
    @StateObject private var m = SettingsModel()
    @State private var text = AppServices.settings?.current.tmdbKeyOverride ?? ""
    @State private var show = false
    @State private var saving = false

    var body: some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(help).vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                Text("TMDB key").vLabelMedium(Theme.textMuted).padding(.top, 14).padding(.bottom, 6)
                VTextField("TMDB key", text: $text, icon: "key", secure: !show, onSubmit: save) {
                    VIconButton(show ? "eye.slash" : "eye", help: show ? "Hide key" : "Show key", size: 32, kind: .flat) {
                        show.toggle()
                    }
                }
                HStack(spacing: 8) {
                    VButton("Save key", kind: .primary, loading: saving, action: save)
                        .disabled(text == m.s.tmdbKeyOverride)
                    if !m.s.tmdbKeyOverride.isEmpty {
                        Button("Clear") {
                            text = ""
                            m.set(\.tmdbKeyOverride, "")
                            Toast.show("TMDB key removed")
                        }
                        .buttonStyle(.vTextMuted)
                    }
                }
                .padding(.top, 12)
                Link(destination: URL(string: "https://www.themoviedb.org/settings/api")!) {
                    Text("Get a key at themoviedb.org").vLabelMedium(Theme.amber)
                }
                .padding(.top, 10)
            }
            .padding(16)
        }
    }

    private var help: String {
        var h = "Paste your TMDB API key or API Read Access Token. Get one free at themoviedb.org → Settings → API."
        if m.s.tmdbKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !BundledKeys.tmdb.isEmpty {
            h += "\nCurrently using the key built into this copy of the app. Paste your own to replace it."
        }
        return h
    }

    private func save() {
        guard !saving else { return }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != m.s.tmdbKeyOverride || text != key else { return }
        m.set(\.tmdbKeyOverride, key)
        text = key
        saving = true
        Task {
            defer { saving = false }
            do {
                guard let tmdb = AppServices.tmdb else { return }
                try await tmdb.validateKey()
                Toast.show("TMDB key saved")
                Task { await AppServices.scans?.runNow() }
            } catch {
                Toast.show("TMDB rejected this key: \(Self.message(error))")
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? TmdbError { return e.message }
        if error is TmdbKeyMissingError { return "No key entered" }
        return error.localizedDescription
    }
}

// MARK: - About

struct AboutSection: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return v.split(separator: "+").first.map(String.init) ?? v
    }

    var body: some View {
        SettingsPanel {
            SettingRow("Veltoret", subtitle: "Version \(version) · open source · Developed by PNT Apps")
            SettingsDivider()
            SettingRow("Website", subtitle: "pntapps.com", icon: "globe") { openLink("https://www.pntapps.com") }
            SettingsDivider()
            SettingRow("About us", subtitle: "Who makes Veltoret", icon: "info.circle") { openLink("https://www.pntapps.com/about") }
            SettingsDivider()
            SettingRow("Privacy policy", subtitle: "What happens to your data", icon: "lock") {
                openLink("https://www.pntapps.com/privacy")
            }
            SettingsDivider()
            SettingRow("License", subtitle: "GNU General Public License v3.0", icon: "doc.text") {
                openLink("https://www.gnu.org/licenses/gpl-3.0.html")
            }
            SettingsDivider()
            SettingRow("Source code", subtitle: "github.com/pntapps/Veltoret", icon: "chevron.left.forwardslash.chevron.right") {
                openLink("https://github.com/pntapps/Veltoret")
            }
            SettingsDivider()
            SettingRow("Open-source notices", subtitle: "Libraries and fonts Veltoret uses", icon: "books.vertical") {
                Task { await Self.showNotices() }
            }
            SettingsDivider()
            TmdbAttribution().padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        }
    }

    static let notices: [(String, String)] = [
        ("VLCKit and LibVLC (VideoLAN)", "GNU LGPL 2.1 or later"),
        ("AMSMB2 and libsmb2", "GNU LGPL 2.1 or later"),
        ("Fraunces and Inter fonts", "SIL Open Font License 1.1"),
        ("SQLite", "Public domain"),
        ("TMDB", "Metadata and images from The Movie Database (themoviedb.org)"),
    ]

    @MainActor
    static func showNotices() async {
        let _: Bool? = await Dialogs.present { ctl in
            VDialog(title: "Open-source notices", width: 460, scrollable: true) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notices, id: \.0) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.0).vTitleSmall()
                            Text(n.1).vBodySmall(Theme.textMuted)
                        }
                    }
                    Text("Veltoret is free software under the GNU GPL v3.0. VLCKit and AMSMB2 are used as separate, replaceable libraries under the LGPL; their source is available from VideoLAN and github.com/amosavian/AMSMB2.")
                        .vBodySmall(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } actions: {
                Button("Close") { ctl.close(true) }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
            }
        }
    }
}
