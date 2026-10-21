import Foundation
import VeltoretKit

/// Text helpers for the Files screen, transfers and the Extract dialog (Android: ui/util/Format + StorageSummary).
public enum DriveFormat {
    private static let us = Locale(identifier: "en_US_POSIX")

    /// "—" for ≤ 0; B, KB, MB, GB, TB in 1024 steps, one decimal from GB up.
    public static func bytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit >= 3 { return String(format: "%.1f", locale: us, value) + " " + units[unit] }
        // C# "0" rounds half away from zero.
        return String(format: "%.0f", locale: us, value.rounded(.toNearestOrAwayFromZero)) + " " + units[unit]
    }

    private static func spaceBytes(_ b: Int64) -> String { b <= 0 ? "0 B" : bytes(b) }

    /// "Google storage · 4.2 GB used of 15 GB · 10.8 GB free".
    public static func storageSummary(_ space: StorageSpace) -> String {
        var parts = [space.name]
        if let total = space.total, total > 0 {
            parts.append("\(spaceBytes(space.used)) used of \(spaceBytes(total))")
        } else {
            parts.append("\(spaceBytes(space.used)) used")
        }
        if let free = space.free { parts.append("\(spaceBytes(free)) free") }
        return parts.joined(separator: " · ")
    }

    /// Filled fraction of the storage bar (0..1), or nil when the total is unknown (no bar).
    public static func storageFraction(_ space: StorageSpace) -> Double? {
        guard let total = space.total, total > 0 else { return nil }
        return min(1, max(0, Double(space.used) / Double(total)))
    }

    /// The bar turns Danger at 90 % full.
    public static func storageAlmostFull(_ space: StorageSpace) -> Bool { (storageFraction(space) ?? 0) >= 0.9 }

    /// "Mar 4, 2025" in local time, or nil.
    public static func driveDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty, let date = parseDate(iso) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = .current
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    static func parseDate(_ iso: String) -> Date? {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: iso) { return d }
        a.formatOptions = [.withInternetDateTime]
        if let d = a.date(from: iso) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: iso) { return d }
        }
        return nil
    }

    /// "4:05", "1:02:09".
    public static func clock(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        let m = total % 3600 / 60
        let s = total % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%lld:%02lld", m, s)
    }

    /// Lowercased extension without the dot ("" when none) — FilenameParser.Extension.
    public static func fileExtension(_ name: String) -> String {
        guard let i = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: i)...]).lowercased()
    }

    /// The name without its last extension — FilenameParser.BaseName.
    public static func baseName(_ name: String) -> String {
        guard let i = name.lastIndex(of: ".") else { return name }
        return String(name[..<i])
    }

    /// MIME type for uploads (Android: mimeFor + MimeTypeMap).
    public static func mimeFor(_ name: String) -> String {
        switch fileExtension(name) {
        case "mkv": return "video/x-matroska"
        case "srt": return "application/x-subrip"
        case "ass", "ssa": return "text/x-ssa"
        case "vtt": return "text/vtt"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "wmv": return "video/x-ms-wmv"
        case "asf": return "video/x-ms-asf"
        case "flv": return "video/x-flv"
        case "f4v": return "video/x-f4v"
        case "webm": return "video/webm"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "mpg", "mpeg", "vob": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "ogv": return "video/ogg"
        case "divx": return "video/divx"
        case "rmvb": return "application/vnd.rn-realmedia-vbr"
        case "mxf": return "application/mxf"
        case "ttml": return "application/ttml+xml"
        case "dfxp": return "application/ttaf+xml"
        case "zip": return "application/zip"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "txt", "nfo": return "text/plain"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}
