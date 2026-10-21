import AppKit
import SwiftUI
import UserNotifications
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// Every pending reminder, soonest first, live from the database ("reminders" table).
@MainActor
final class RemindersModel: ObservableObject {
    @Published private(set) var reminders: [ReminderEntity] = []
    private var sub: VeltoretKit.Subscription?

    init() {
        reload()
        sub = AppServices.db?.changed.subscribe { [weak self] tables in
            guard tables.contains("reminders") else { return }
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        reminders = ((try? AppServices.plans?.reminders()) ?? []).sorted { $0.at < $1.at }
    }

    func remove(_ id: Int64) {
        reminders.removeAll { $0.id == id }
        do { try AppServices.plans.removeReminder(id) } catch { Log.error(error, "Removing a reminder") }
    }
}

/// The notification permission as Settings shows it, refreshed when the app becomes active.
@MainActor
final class NotificationStatusModel: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatusBox = .unknown
    private var sub: VeltoretKit.Subscription?
    private var observer: NSObjectProtocol?

    init() {
        apply()
        sub = MacNotifier.shared.statusChanged.subscribe { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                          queue: .main) { _ in MacNotifier.shared.refreshStatus() }
        MacNotifier.shared.refreshStatus()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func apply() { status = UNAuthorizationStatusBox(MacNotifier.shared.status) }
}

/// The authorization status, with "unknown" (not checked yet / no app bundle).
enum UNAuthorizationStatusBox: Equatable {
    case unknown, notDetermined, denied, allowed

    init(_ s: UNAuthorizationStatus?) {
        guard MacNotifier.isSupported, let s else { self = .unknown; return }
        switch s {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = MacNotifier.allows(s) ? .allowed : .denied
        }
    }
}

/// One reminder row: amber bell, title, "Today at 8:00 PM", and "×" (Cancel reminder).
struct ReminderRow: View {
    let reminder: ReminderEntity
    let onCancel: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bell").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.amber).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).vTitleSmall().lineLimit(1).truncationMode(.tail)
                Text(Plans.reminderLabel(reminder.at, now: Date())).vBodySmall(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VIconButton("xmark", help: "Cancel reminder", size: 34, kind: .flat, action: onCancel)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }
}

/// "Reminders" (menu bar item): all pending reminders in a dialog, each with "Cancel reminder".
@MainActor
public enum RemindersDialog {
    public static func show() async {
        let _: Bool? = await Dialogs.present { ctl in RemindersDialogView(controller: ctl) }
    }
}

private struct RemindersDialogView: View {
    let controller: DialogController<Bool>
    @StateObject private var model = RemindersModel()
    @StateObject private var permission = NotificationStatusModel()

    var body: some View {
        VDialog(title: "Reminders", width: 460, scrollable: true) {
            VStack(alignment: .leading, spacing: 0) {
                if model.reminders.isEmpty {
                    Text("No reminders. Use \"Remind me\" on a movie, show or episode.").vBodyMedium(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if permission.status == .denied {
                        Text(NotificationsSection.offWarning).vBodySmall(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(model.reminders.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { VDivider() }
                        ReminderRow(reminder: r) { model.remove(r.id) }.padding(.leading, -16)
                    }
                }
            }
        } actions: {
            Button("Close") { controller.close(true) }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
        }
    }
}
