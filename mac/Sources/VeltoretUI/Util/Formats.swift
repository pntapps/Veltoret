import Foundation

/// Formatting rules from the Android app (US formats regardless of locale). Port of Windows `Controls/Items.cs` Formats.
public enum Formats {
    public static let us = Locale(identifier: "en_US_POSIX")

    /// "1 episode" / "3 episodes".
    public static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// "2h 46m", "48m", "2h"; nil when ≤ 0 or nil.
    public static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Runtime from milliseconds (rounded to the minute); nil when ≤ 0.
    public static func runtimeMs(_ ms: Int64) -> String? {
        ms > 0 ? runtime(Int((Double(ms) / 60000).rounded())) : nil
    }

    /// "{m}m left" / "{h}h {m}m left" (minimum 1 minute).
    public static func remaining(positionMs: Int64, durationMs: Int64) -> String {
        let mins = max(1, Int((Double(max(0, durationMs - positionMs)) / 60000).rounded(.up)))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }

    /// "S1 · E2"; season 0 → "Special 2"; empty when either is nil.
    public static func episodeCode(_ season: Int?, _ episode: Int?) -> String {
        guard let season, let episode else { return "" }
        return season == 0 ? "Special \(episode)" : "S\(season) · E\(episode)"
    }

    /// Compact code "S01E02" (file names, notifications).
    public static func episodeCodeCompact(_ season: Int, _ episode: Int) -> String {
        String(format: "S%02dE%02d", season, episode)
    }

    /// Joins non-blank parts with "  ·  " (MetaLine).
    public static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "  ·  ")
    }
    public static func join(_ parts: String?...) -> String { join(parts) }

    /// Joins non-blank parts with " · " (card subtitles).
    public static func joinTight(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " · ")
    }
    public static func joinTight(_ parts: String?...) -> String { joinTight(parts) }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    /// Parses "yyyy-MM-dd" (TMDB dates) as a local date at midnight.
    public static func parseDate(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = formatter("yyyy-MM-dd")
        f.timeZone = .current
        return f.date(from: String(s.prefix(10)))
    }

    /// "Oct 23, 2015".
    public static func longDate(_ yyyyMmDd: String?) -> String? {
        parseDate(yyyyMmDd).map { formatter("MMM d, yyyy").string(from: $0) }
    }

    private static func daysFromToday(_ date: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Today / Tomorrow / "Friday" (< 7 days) / "Fri, Oct 23".
    public static func airLabel(_ date: Date, now: Date = Date()) -> String {
        let days = daysFromToday(date, now: now)
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days > 1 && days < 7 { return formatter("EEEE").string(from: date) }
        return formatter("EEE, MMM d").string(from: date)
    }

    /// Air label from a "yyyy-MM-dd" string; nil when unparseable.
    public static func airLabel(_ yyyyMmDd: String?) -> String? { parseDate(yyyyMmDd).map { airLabel($0) } }

    /// Reminder label: "Today at 9:00 PM" / "Tomorrow at …" / "Fri, Oct 23 at 9:00 PM".
    public static func reminderLabel(_ at: Date, now: Date = Date()) -> String {
        let days = daysFromToday(at, now: now)
        let day = days == 0 ? "Today" : days == 1 ? "Tomorrow" : formatter("EEE, MMM d").string(from: at)
        return "\(day) at \(formatter("h:mm a").string(from: at))"
    }

    /// Reminder label from epoch milliseconds.
    public static func reminderLabel(ms: Int64) -> String { reminderLabel(Date(timeIntervalSince1970: Double(ms) / 1000)) }

    /// "1.4 GB", "700 MB", "12 KB", "512 B" (binary units, as on Android).
    public static func size(_ bytes: Int64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.1f GB", b / gb) }
        if b >= mb { return String(format: "%.0f MB", b / mb) }
        if b >= kb { return String(format: "%.0f KB", b / kb) }
        return "\(bytes) B"
    }

    /// "7.8".
    public static func rating(_ r: Double) -> String { String(format: "%.1f", r) }

    public static func seasons(_ n: Int) -> String { plural(n, "season", "seasons") }
    public static func episodes(_ n: Int) -> String { plural(n, "episode", "episodes") }

    /// Player-style clock: "1:02:03" / "2:03".
    public static func clock(ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// nil for blank strings.
    public static func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
