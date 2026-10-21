import Foundation

private let posix = Locale(identifier: "en_US_POSIX")

/// Text the player shows (Android: ui/util/Format.kt plus the player's own labels).
public enum PlayerFormat {
    /// Player clock: "4:05", "1:02:09". Negative clamps to 0.
    public static func clock(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%lld:%02lld", m, s)
    }

    /// "1.4 GB", "700 MB" (1024-based, one decimal from GB up); ≤ 0 → "—".
    public static func bytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit >= 3
            ? String(format: "%.1f %@", locale: posix, value, units[unit])
            : String(format: "%.0f %@", locale: posix, value, units[unit])
    }

    /// "2h 46m" / "48m" / "2h"; nil when unknown.
    public static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "S1 · E2", "Special 3", or "" when unknown.
    public static func episodeCode(_ season: Int?, _ episode: Int?) -> String {
        guard let season, let episode else { return "" }
        return season == 0 ? "Special \(episode)" : "S\(season) · E\(episode)"
    }

    /// Speed option label: "Normal" for 1, else "0.25×", "1.5×", "2×".
    public static func speedOption(_ speed: Float) -> String { abs(speed - 1) < 0.001 ? "Normal" : trim(speed) + "×" }

    /// Speed chip: "Speed" at 1×, else "1.5×".
    public static func speedChip(_ speed: Float) -> String { abs(speed - 1) < 0.001 ? "Speed" : trim(speed) + "×" }

    /// "2", "1.5", "0.25" (C# "0.##").
    public static func trim(_ value: Float) -> String {
        if value == value.rounded(.down) { return String(Int(value)) }
        var s = String(format: "%.2f", locale: posix, Double(value))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Subtitle sync value: "In sync", "0.5 s later", "1.0 s earlier".
    public static func syncLabel(_ offsetMs: Int64) -> String {
        if offsetMs == 0 { return "In sync" }
        return String(format: "%.1f s %@", locale: posix, Double(abs(offsetMs)) / 1000.0, offsetMs > 0 ? "later" : "earlier")
    }

    /// Loading hint under the spinner (Android PlayerLoading); nil at stage 0.
    public static func loadingHint(_ stage: Int, _ from: String?) -> String? {
        if stage <= 0 { return nil }
        if stage >= 2 { return from != nil ? "Slow connection, still loading…" : "Still loading…" }
        if let from { return "Loading from \(from)…" }
        return "Loading…"
    }

    /// Volume HUD: "Volume 80%", "Volume 150% · Boost".
    public static func volume(_ percent: Int) -> String { percent > 100 ? "Volume \(percent)% · Boost" : "Volume \(percent)%" }

    /// Swipe-seek HUD: "+1:30  ·  12:04" / "−0:20  ·  0:40".
    public static func swipeSeek(_ deltaMs: Int64, _ targetMs: Int64) -> String {
        (deltaMs < 0 ? "−" : "+") + clock(abs(deltaMs)) + "  ·  " + clock(targetMs)
    }

    public static func zoom(_ zoom: Double) -> String { "Zoom " + String(format: "%.1f", locale: posix, zoom) + "×" }

    /// Short local time ("10:42 PM").
    public static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// "Ends at 10:42 PM" under the seek bar.
    public static func endsAt(_ date: Date) -> String { "Ends at " + time(date) }

    /// Sleep detail in the More panel.
    public static func sleepDetail(_ endsAt: Date?, _ endOfVideo: Bool) -> String {
        if endOfVideo { return "At the end of this video" }
        if let endsAt { return "Stops at " + time(endsAt) }
        return "Off"
    }
}

/// Seek arithmetic shared by every control (Android PlayerViewModel.seekBy / skipForward), plus the pure parts of
/// the Windows player window (zoom, ends-at).
public enum PlayerMath {
    public static func seekBy(_ position: Int64, _ duration: Int64, _ deltaMs: Int64) -> Int64 {
        let target = max(0, position + deltaMs)
        return duration > 0 ? min(target, duration - 500) : target
    }

    /// Touch/trackpad swipe seek: the full width is 3 minutes; returns the change and the clamped target.
    public static func swipeSeek(_ position: Int64, _ duration: Int64, _ dx: Double, _ width: Double) -> (delta: Int64, target: Int64) {
        let delta: Int64 = width > 0 ? Int64(dx / width * 180_000) : 0
        var target = max(0, position + delta)
        if duration > 0 { target = min(target, duration) }
        return (target - position, target)
    }

    /// Swipe volume (right half): 70 % of the height covers the whole 0–200 range; up is louder.
    public static func swipeVolume(_ startVolume: Int, _ dy: Double, _ height: Double) -> Int {
        guard height > 0 else { return startVolume }
        let v = (Double(startVolume) - dy / (0.7 * height) * 200).rounded(.toNearestOrEven)
        return Int(min(200, max(0, v)))
    }

    public static func skipForward(_ position: Int64, _ duration: Int64, _ seconds: Int) -> Int64 {
        let target = position + Int64(seconds) * 1000
        return duration > 0 ? min(target, duration - 1000) : target
    }

    /// Resume where the viewer stopped unless it was watched or barely started.
    public static func resumeAt(_ fromStart: Bool, _ savedPositionMs: Int64?, _ watched: Bool) -> Int64 {
        guard !fromStart, !watched, let saved = savedPositionMs, saved > 10_000 else { return 0 }
        return saved
    }

    public static func skipIntroVisible(_ isEpisode: Bool, _ introSkipped: Bool, _ controlsVisible: Bool, _ locked: Bool,
                                        _ position: Int64) -> Bool {
        isEpisode && !introSkipped && !controlsVisible && !locked && position >= 5_000 && position <= 180_000
    }

    public static func upNextVisible(_ hasNext: Bool, _ duration: Int64, _ position: Int64, _ cancelled: Bool,
                                     _ locked: Bool, _ sleepAtEnd: Bool) -> Bool {
        let remaining = duration - position
        return hasNext && duration > 0 && remaining >= 1 && remaining <= 30_000 && !cancelled && !locked && !sleepAtEnd
    }

    public static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next/previous entry in `speeds` ([ and ] keys).
    public static func stepSpeed(_ current: Float, _ direction: Int) -> Float {
        var i = speeds.firstIndex(where: { abs($0 - current) < 0.001 }) ?? -1
        if i < 0 { i = speeds.lastIndex(where: { $0 < current }) ?? 0 }
        return speeds[min(max(i + direction, 0), speeds.count - 1)]
    }

    /// Double-click/arrow seek feedback: same direction within 1 200 ms adds up.
    public static func accumulateSeek(_ previousTotal: Int?, _ sameDirection: Bool, _ sinceLastMs: Int64, _ step: Int) -> Int {
        if let t = previousTotal, sameDirection, sinceLastMs < 1_200 { return t + step }
        return step
    }

    /// When playback ends at the current speed ("Ends at …").
    public static func endsAt(now: Date = Date(), durationMs: Int64, positionMs: Int64, speed: Float) -> Date? {
        guard durationMs > 0 else { return nil }
        let ms = Double(durationMs - positionMs) / max(0.01, Double(speed))
        return now.addingTimeInterval(ms / 1000)
    }

    /// Zoom clamped to 1–5×; below 1.05× snaps back to 1 (Windows SetZoom; pan resets then).
    public static func clampZoom(_ zoom: Double) -> Double {
        let z = min(5, max(1, zoom))
        return z < 1.05 ? 1 : z
    }

    /// ⌘/Ctrl + scroll wheel zoom: 10 % per notch.
    public static func wheelZoom(_ zoom: Double, notches: Double) -> Double { clampZoom(zoom * pow(1.1, notches)) }

    /// Drag-to-pan while zoomed: new pan (−1..1) after dragging by `delta` points over a view of `size` points.
    public static func pan(_ pan: Double, delta: Double, size: Double, zoom: Double) -> Double {
        guard size > 0, zoom > 1.001 else { return 0 }
        return min(1, max(-1, pan - 2 * delta / size / (zoom - 1)))
    }

    /// libVLC crop geometry ("WxH+X+Y" in video pixels) for zoom/pan, optionally cropping to fill a window first.
    /// Pan is a fraction of the crop's free space in each axis (−1..1). Nil when nothing needs cropping.
    public static func cropGeometry(_ videoW: Int, _ videoH: Int, _ windowW: Double, _ windowH: Double, fill: Bool,
                                    _ zoom: Double, _ panX: Double, _ panY: Double) -> String? {
        if videoW <= 0 || videoH <= 0 { return nil }
        var w = Double(videoW), h = Double(videoH)
        if fill && windowW > 0 && windowH > 0 {
            let target = windowW / windowH
            if w / h > target { w = h * target } else { h = w / target }
        }
        let z = min(5, max(1, zoom))
        w /= z; h /= z
        if abs(w - Double(videoW)) < 1 && abs(h - Double(videoH)) < 1 { return nil }
        let x = (Double(videoW) - w) / 2 * (1 + min(1, max(-1, panX)))
        let y = (Double(videoH) - h) / 2 * (1 + min(1, max(-1, panY)))
        func r(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        return "\(r(w))x\(r(h))+\(r(x))+\(r(y))"
    }
}
