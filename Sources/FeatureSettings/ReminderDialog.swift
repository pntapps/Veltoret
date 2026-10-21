import AppKit
import SwiftUI
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// "Remind me" (Android TitlePlans.ReminderDialog, Windows ReminderDialog): one-click times (tonight, tomorrow,
/// Saturday, and "When it airs" for an episode that hasn't aired) or any date and time. Also lists the title's
/// pending reminders so they can be cancelled.
@MainActor
public enum ReminderDialog {
    /// Shows the dialog; true when a reminder was set. `title` is stored with the reminder (movie title, show name,
    /// or "Show · S1 · E2"). `airDate` ("yyyy-MM-dd") adds "When it airs (…, 8 PM)" while the episode is upcoming.
    @discardableResult
    public static func show(type: String, id: Int, season: Int?, episode: Int?, title: String,
                            airDate: String?) async -> Bool {
        let calendar = Calendar.current
        let today = LocalDate(Date(), calendar: calendar)
        var extra: [ReminderChoice] = []
        if Plans.isUpcoming(airDate, today: today), let d = Plans.parse(airDate),
           let at = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 20, minute: 0)) {
            extra.append(ReminderChoice(label: "When it airs (\(Plans.airLabel(airDate, today: today) ?? ""), 8 PM)", at: at))
        }
        let existing = (try? AppServices.plans.remindersFor(type: type, id: id)) ?? []

        let picked: Date? = await Dialogs.present { ctl in
            ReminderDialogView(title: title, extra: extra, existing: existing, controller: ctl)
        }
        guard let at = picked else { return false }

        let ms = Plans.toMillis(at)
        let label = Plans.reminderLabel(ms, now: Date())
        do {
            _ = try AppServices.plans.addReminder(type: type, id: id, season: season, episode: episode, title: title, at: at)
        } catch {
            Log.error(error, "Adding a reminder")
            Toast.show("Couldn't set the reminder")
            return false
        }
        if MacNotifier.shared.canPostNowOnMain {
            Toast.show("Reminder set for \(label)")
        } else {
            let allowed = await MacNotifier.shared.requestAuthorization()
            if allowed {
                Toast.show("Reminder set for \(label)")
            } else {
                Toast.show("Reminder set for \(label). Allow notifications so it can appear.", actionTitle: "Settings") {
                    SystemSettingsLinks.open(SystemSettingsLinks.notifications)
                }
            }
        }
        return true
    }
}

extension MacNotifier {
    /// `canPostNow` without blocking (main thread): the last known status; unknown counts as "can't".
    var canPostNowOnMain: Bool { status.map(MacNotifier.allows) ?? false }
}

// MARK: - View

struct ReminderChoice {
    let label: String
    let at: Date
}

private struct ReminderDialogView: View {
    let title: String
    let extra: [ReminderChoice]
    @State var existing: [ReminderEntity]
    let controller: DialogController<Date>

    init(title: String, extra: [ReminderChoice], existing: [ReminderEntity], controller: DialogController<Date>) {
        self.title = title; self.extra = extra; _existing = State(initialValue: existing); self.controller = controller
    }

    private enum Step { case choices, date, time }
    @State private var step: Step = .choices
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var month: Date = {
        let c = Calendar.current
        return c.date(from: c.dateComponents([.year, .month], from: Date())) ?? Date()
    }()
    @State private var hour = 8          // 1…12
    @State private var minute = 0
    @State private var pm = true

    private static let us = Locale(identifier: "en_US")

    var body: some View {
        switch step {
        case .choices: choices
        case .date: datePage
        case .time: timePage
        }
    }

    // Step 0: choices.
    private var choices: some View {
        VDialog(title: "Remind me", width: 420) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                let now = Date()
                ForEach(Array((extra.filter { $0.at > now } + Plans.quickTimes(now).map { ReminderChoice(label: $0.label, at: $0.at) }).enumerated()), id: \.offset) { _, q in
                    choiceRow(icon: "bell", label: q.label) { controller.close(q.at) }
                }
                choiceRow(icon: "calendar.badge.clock", label: "Pick a date and time…") { step = .date }
                if !existing.isEmpty {
                    VDivider().padding(.top, 10)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(existing.sorted { $0.at < $1.at }, id: \.id) { r in existingRow(r) }
                    }
                    .padding(.top, 10)
                }
            }
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
        }
    }

    private func choiceRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.amber).frame(width: 22)
                Text(label).vBodyLarge()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func existingRow(_ r: ReminderEntity) -> some View {
        var parts: [String] = []
        if r.season != nil && r.episode != nil { parts.append(PlanFormat.episodeCode(r.season, r.episode)) }
        parts.append("Reminder \(Plans.reminderLabel(r.at, now: Date()))")
        return HStack(spacing: 8) {
            Image(systemName: "bell").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.amber)
            Text(parts.joined(separator: "  ·  ")).vBodyMedium().lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            VIconButton("xmark", help: "Cancel reminder", size: 30, kind: .flat) {
                existing.removeAll { $0.id == r.id }
                do { try AppServices.plans.removeReminder(r.id) } catch { Log.error(error, "Removing a reminder") }
            }
        }
        .padding(.vertical, 2)
    }

    // Step 1: date (today or later).
    private var datePage: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let firstOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let leading = (cal.component(.weekday, from: month) - 1) // Sunday first
        let cells: [Date?] = Array(repeating: nil, count: leading)
            + (0..<days).map { cal.date(byAdding: .day, value: $0, to: month) }
        let columns = Array(repeating: GridItem(.fixed(42), spacing: 2), count: 7)

        return VDialog(title: nil, width: 340) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Select date").vLabelMedium(Theme.textMuted)
                Text(Self.format(date, "EEE, MMM d")).vHeadlineMedium().padding(.top, 6).padding(.bottom, 14)
                HStack {
                    Text(Self.format(month, "MMMM yyyy")).vTitleSmall()
                    Spacer()
                    VIconButton("chevron.left", help: "Previous month", size: 34, kind: .flat, tint: Theme.text) {
                        month = cal.date(byAdding: .month, value: -1, to: month) ?? month
                    }
                    .disabled(month <= firstOfThisMonth)
                    VIconButton("chevron.right", help: "Next month", size: 34, kind: .flat, tint: Theme.text) {
                        month = cal.date(byAdding: .month, value: 1, to: month) ?? month
                    }
                }
                .padding(.bottom, 8)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                        Text(d).vLabelMedium(Theme.textMuted).frame(height: 22)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                        if let d { dayCell(d, today: today) } else { Color.clear.frame(width: 40, height: 40) }
                    }
                }
            }
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            Button("Next") { step = .time }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
        }
    }

    private func dayCell(_ d: Date, today: Date) -> some View {
        let selected = Calendar.current.isDate(d, inSameDayAs: date)
        let isToday = Calendar.current.isDate(d, inSameDayAs: today)
        let past = d < today
        return Button { date = d } label: {
            Text("\(Calendar.current.component(.day, from: d))")
                .font(Fonts.sans(14, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onAmber : isToday ? Theme.amber : Theme.text)
                .frame(width: 40, height: 40)
                .background(Circle().fill(selected ? Theme.amber : Color.clear))
                .overlay(Circle().strokeBorder(isToday && !selected ? Theme.amber : Color.clear, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(past)
        .opacity(past ? 0.38 : 1)
    }

    // Step 2: time (12-hour, 8:00 PM to start).
    private var chosen: Date {
        let h24 = (hour % 12) + (pm ? 12 : 0)
        return Calendar.current.date(bySettingHour: h24, minute: minute, second: 0, of: date) ?? date
    }

    private var timePage: some View {
        VDialog(title: PlanFormat.date(LocalDate(date)), width: 360) {
            HStack(spacing: 8) {
                Picker("Hour", selection: $hour) {
                    ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 76)
                Text(":").vHeadlineSmall()
                Picker("Minute", selection: $minute) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .frame(width: 76)
                Picker("AM or PM", selection: $pm) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .padding(.leading, 8)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.amber)
        } actions: {
            Button("Back") { step = .date }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            Button("Set reminder") { if chosen > Date() { controller.close(chosen) } }
                .buttonStyle(.vText)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen <= Date())
        }
    }

    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = us
        f.dateFormat = pattern
        return f.string(from: d)
    }
}
