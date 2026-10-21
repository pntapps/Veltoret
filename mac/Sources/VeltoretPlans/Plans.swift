import Foundation
import VeltoretKit

/// What a notification opens: a movie, a show, or one episode of it; `play` starts it right away.
public struct OpenTarget: Hashable, Sendable, Codable {
    public var mediaType: String
    public var mediaId: Int
    public var season: Int?
    public var episode: Int?
    public var play: Bool

    public init(mediaType: String, mediaId: Int, season: Int? = nil, episode: Int? = nil, play: Bool = false) {
        self.mediaType = mediaType; self.mediaId = mediaId; self.season = season; self.episode = episode; self.play = play
    }

    /// For notification `userInfo` (plist-safe values only).
    public var userInfo: [String: Any] {
        var d: [String: Any] = ["type": mediaType, "media": mediaId, "play": play]
        if let season { d["season"] = season }
        if let episode { d["episode"] = episode }
        return d
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String, let media = userInfo["media"] as? Int else { return nil }
        self.init(mediaType: type, mediaId: media, season: userInfo["season"] as? Int,
                  episode: userInfo["episode"] as? Int, play: userInfo["play"] as? Bool ?? false)
    }
}

/// A calendar day without a time or zone (C# DateOnly, java.time.LocalDate). TMDB dates are "yyyy-MM-dd".
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Noon UTC of this day (for formatting with a UTC formatter).
    var utcNoon: Date {
        LocalDate.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// Days since 1970-01-01.
    public var dayNumber: Int { Int((utcNoon.timeIntervalSince1970 / 86_400).rounded(.down)) }

    public func adding(days: Int) -> LocalDate {
        LocalDate(LocalDate.utc.date(byAdding: .day, value: days, to: utcNoon)!, calendar: LocalDate.utc)
    }

    /// "yyyy-MM-dd".
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Pure date and time rules for watchlist, reminders and upcoming episodes (Android: data/plans/Plans.kt; PlansTest).
public enum Plans {
    public static let movie = "movie"
    public static let tv = "tv"

    /// Reminders that fire late (Mac off or asleep) still show if they're less than this overdue; older ones are dropped.
    public static let staleAfterMs: Int64 = 12 * 60 * 60 * 1000

    /// TMDB statuses of shows still being made (their next episode can change).
    private static let airing: Set<String> = ["Returning Series", "In Production", "Planned", "Pilot"]

    public static func stillAiring(_ status: String?) -> Bool { status.map(airing.contains) ?? false }

    public struct QuickTime: Hashable, Sendable {
        public let label: String
        public let at: Date
    }

    /// One-tap reminder times: tonight 8 PM (while it's still ahead), tomorrow 8 PM, Saturday 8 PM. `now` is read
    /// in `calendar`'s time zone.
    public static func quickTimes(_ now: Date, calendar: Calendar = .current) -> [QuickTime] {
        let today = calendar.startOfDay(for: now)
        func evening(_ days: Int) -> Date {
            let d = calendar.date(byAdding: .day, value: days, to: today)!
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: d)!
        }
        // TemporalAdjusters.next: strictly after today, so on a Saturday it's a week later. Weekday: Sunday = 1.
        let weekday = calendar.component(.weekday, from: today)
        var daysToSaturday = (7 - weekday + 7) % 7
        if daysToSaturday == 0 { daysToSaturday = 7 }
        var list: [QuickTime] = []
        let c = calendar.dateComponents([.hour, .minute, .second], from: now)
        let secondsOfDay = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        if secondsOfDay < 19 * 3600 + 30 * 60 { list.append(QuickTime(label: "Tonight, 8 PM", at: evening(0))) }
        list.append(QuickTime(label: "Tomorrow, 8 PM", at: evening(1)))
        if daysToSaturday != 1 { list.append(QuickTime(label: "Saturday, 8 PM", at: evening(daysToSaturday))) }
        return list
    }

    /// "Today", "Tomorrow", "Friday" within a week, then "Fri, Oct 23". `date` is TMDB's "yyyy-MM-dd".
    public static func airLabel(_ date: String?, today: LocalDate) -> String? {
        guard let d = parse(date) else { return nil }
        let days = d.dayNumber - today.dayNumber
        switch days {
        case ..<0: return nil
        case 0: return "Today"
        case 1: return "Tomorrow"
        case ..<7: return format(d, "EEEE")
        default: return format(d, "EEE, MMM d")
        }
    }

    /// True when the episode airs today or later (yesterday's "next episode" is stale).
    public static func isUpcoming(_ date: String?, today: LocalDate) -> Bool {
        guard let d = parse(date) else { return false }
        return d >= today
    }

    /// "Fri, Oct 23 at 9:00 PM" (or "Today at …" / "Tomorrow at …"), both read in `timeZone`.
    public static func reminderLabel(_ at: Int64, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        let t = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        let time = f.string(from: t)
        let days = LocalDate(t, calendar: cal).dayNumber - LocalDate(now, calendar: cal).dayNumber
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        default:
            f.dateFormat = "EEE, MMM d"
            day = f.string(from: t)
        }
        return "\(day) at \(time)"
    }

    /// At start-up or after a wake: schedule what's ahead, show what's slightly overdue, drop the rest.
    public enum DueKind: Sendable { case schedule, fireNow, drop }

    public static func due(_ at: Int64, now: Int64) -> DueKind {
        at > now ? .schedule : now - at <= staleAfterMs ? .fireNow : .drop
    }

    /// An instant to epoch milliseconds.
    public static func toMillis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Local wall-clock time (year…minute in `timeZone`) to epoch milliseconds. A time skipped by a DST change
    /// moves an hour later, as on Windows.
    public static func toMillis(_ local: DateComponents, timeZone: TimeZone = .current) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents(year: local.year, month: local.month, day: local.day,
                                   hour: local.hour ?? 0, minute: local.minute ?? 0, second: local.second ?? 0)
        guard let first = cal.date(from: comps) else { return 0 }
        let back = cal.dateComponents([.hour, .minute], from: first)
        if back.hour != comps.hour || back.minute != comps.minute {
            // Invalid (skipped) local time: one hour later.
            comps.hour = (comps.hour ?? 0) + 1
            if let later = cal.date(from: comps) { return toMillis(later) }
        }
        return toMillis(first)
    }

    /// TMDB's "yyyy-MM-dd"; nil when blank or invalid.
    public static func parse(_ date: String?) -> LocalDate? {
        guard let s = date?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s == date else { return nil }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), y >= 1, (1...12).contains(m) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard comps.isValidDate(in: LocalDate.utc) else { return nil }
        return LocalDate(year: y, month: m, day: d)
    }

    static func format(_ d: LocalDate, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f.string(from: d.utcNoon)
    }
}

/// The Format.kt helpers reminders, notifications and Settings need (US English only).
public enum PlanFormat {
    /// "S3 · E2", "Special 4", or "" when either is missing.
    public static func episodeCode(_ season: Int?, _ episode: Int?) -> String {
        guard let season, let episode else { return "" }
        return season == 0 ? "Special \(episode)" : "S\(season) · E\(episode)"
    }

    /// "48m", "2h", "2h 46m"; nil when unknown.
    public static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "Never", "Just now", "5 min ago", "3 h ago", "2 days ago" ("1 days ago" is what Android prints too).
    public static func relative(_ epochMs: Int64, nowMs: Int64? = nil) -> String {
        if epochMs <= 0 { return "Never" }
        let diff = (nowMs ?? nowMillis()) - epochMs
        let min = diff / 60_000
        if min < 1 { return "Just now" }
        if min < 60 { return "\(min) min ago" }
        let h = min / 60
        if h < 24 { return "\(h) h ago" }
        return "\(h / 24) days ago"
    }

    /// "yyyy-MM-dd" as "Oct 23, 2026"; nil when blank or invalid.
    public static func date(_ isoDate: String?) -> String? {
        Plans.parse(isoDate).map(date)
    }

    public static func date(_ d: LocalDate) -> String { Plans.format(d, "MMM d, yyyy") }
}
