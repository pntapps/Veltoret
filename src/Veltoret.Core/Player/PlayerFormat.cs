using System.Globalization;

namespace Veltoret.Core.Player;

/// <summary>Text the player shows (Android: ui/util/Format.kt plus the player's own labels).</summary>
public static class PlayerFormat
{
    /// <summary>Player clock: "4:05", "1:02:09". Negative clamps to 0.</summary>
    public static string Clock(long ms)
    {
        var total = Math.Max(0, ms) / 1000;
        var h = total / 3600;
        var m = total % 3600 / 60;
        var s = total % 60;
        return h > 0
            ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", h, m, s)
            : string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}", m, s);
    }

    /// <summary>"1.4 GB", "700 MB" (1024-based, one decimal from GB up); ≤ 0 → "—".</summary>
    public static string Bytes(long bytes)
    {
        if (bytes <= 0) return "—";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit >= 3
            ? string.Format(CultureInfo.InvariantCulture, "{0:0.0} {1}", value, units[unit])
            : string.Format(CultureInfo.InvariantCulture, "{0:0} {1}", value, units[unit]);
    }

    /// <summary>"2h 46m" / "48m" / "2h"; null when unknown.</summary>
    public static string? Runtime(int? minutes)
    {
        if (minutes is not > 0) return null;
        var h = minutes.Value / 60;
        var m = minutes.Value % 60;
        return h == 0 ? $"{m}m" : m == 0 ? $"{h}h" : $"{h}h {m}m";
    }

    /// <summary>"S1 · E2", "Special 3", or "" when unknown.</summary>
    public static string EpisodeCode(int? season, int? episode) =>
        season == null || episode == null ? ""
        : season == 0 ? $"Special {episode}"
        : $"S{season} · E{episode}";

    /// <summary>Speed option label: "Normal" for 1, else "0.25×", "1.5×", "2×".</summary>
    public static string SpeedOption(float speed) => Math.Abs(speed - 1f) < 0.001f ? "Normal" : Trim(speed) + "×";

    /// <summary>Speed chip: "Speed" at 1×, else "1.5×".</summary>
    public static string SpeedChip(float speed) => Math.Abs(speed - 1f) < 0.001f ? "Speed" : Trim(speed) + "×";

    public static string Trim(float value) =>
        value == Math.Floor(value) ? ((int)value).ToString(CultureInfo.InvariantCulture) : value.ToString("0.##", CultureInfo.InvariantCulture);

    /// <summary>Subtitle sync value: "In sync", "0.5 s later", "1.0 s earlier".</summary>
    public static string SyncLabel(long offsetMs) =>
        offsetMs == 0 ? "In sync"
        : string.Format(CultureInfo.InvariantCulture, "{0:0.0} s {1}", Math.Abs(offsetMs) / 1000.0, offsetMs > 0 ? "later" : "earlier");

    /// <summary>Loading hint under the spinner (Android PlayerLoading); null at stage 0.</summary>
    public static string? LoadingHint(int stage, string? from) => stage switch
    {
        <= 0 => null,
        >= 2 when from != null => "Slow connection, still loading…",
        >= 2 => "Still loading…",
        _ when from != null => $"Loading from {from}…",
        _ => "Loading…",
    };

    /// <summary>Volume HUD: "Volume 80%", "Volume 150% · Boost".</summary>
    public static string Volume(int percent) => percent > 100 ? $"Volume {percent}% · Boost" : $"Volume {percent}%";

    public static string Zoom(double zoom) => "Zoom " + zoom.ToString("0.0", CultureInfo.InvariantCulture) + "×";

    /// <summary>Sleep detail in the More panel.</summary>
    public static string SleepDetail(DateTimeOffset? endsAt, bool endOfVideo) =>
        endOfVideo ? "At the end of this video"
        : endsAt is { } t ? "Stops at " + t.ToLocalTime().ToString("t", CultureInfo.CurrentCulture)
        : "Off";
}

/// <summary>Seek arithmetic shared by every control (Android PlayerViewModel.seekBy / skipForward).</summary>
public static class PlayerMath
{
    public static long SeekBy(long position, long duration, long deltaMs)
    {
        var target = Math.Max(0, position + deltaMs);
        return duration > 0 ? Math.Min(target, duration - 500) : target;
    }

    public static long SkipForward(long position, long duration, int seconds)
    {
        var target = position + seconds * 1000L;
        return duration > 0 ? Math.Min(target, duration - 1000) : target;
    }

    /// <summary>Resume where the viewer stopped unless it was watched or barely started.</summary>
    public static long ResumeAt(bool fromStart, long? savedPositionMs, bool watched) =>
        fromStart || watched || savedPositionMs is not > 10_000 ? 0 : savedPositionMs.Value;

    public static bool SkipIntroVisible(bool isEpisode, bool introSkipped, bool controlsVisible, bool locked, long position) =>
        isEpisode && !introSkipped && !controlsVisible && !locked && position >= 5_000 && position <= 180_000;

    public static bool UpNextVisible(bool hasNext, long duration, long position, bool cancelled, bool locked, bool sleepAtEnd)
    {
        var remaining = duration - position;
        return hasNext && duration > 0 && remaining >= 1 && remaining <= 30_000 && !cancelled && !locked && !sleepAtEnd;
    }

    public static readonly float[] Speeds = { 0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f };

    /// <summary>The next/previous entry in <see cref="Speeds"/> ([ and ] keys).</summary>
    public static float StepSpeed(float current, int direction)
    {
        var i = Array.FindIndex(Speeds, s => Math.Abs(s - current) < 0.001f);
        if (i < 0) i = Array.FindLastIndex(Speeds, s => s < current) is var j && j >= 0 ? j : 0;
        return Speeds[Math.Clamp(i + direction, 0, Speeds.Length - 1)];
    }

    /// <summary>Double-click/arrow seek feedback: same direction within 1 200 ms adds up.</summary>
    public static int AccumulateSeek(int? previousTotal, bool sameDirection, long sinceLastMs, int step) =>
        previousTotal is { } t && sameDirection && sinceLastMs < 1_200 ? t + step : step;

    /// <summary>
    /// libVLC crop geometry ("WxH+X+Y" in video pixels) for zoom/pan, optionally cropping to fill a window first.
    /// Pan is a fraction of the crop's free space in each axis (−1..1). Null when nothing needs cropping.
    /// </summary>
    public static string? CropGeometry(int videoW, int videoH, double windowW, double windowH, bool fill, double zoom, double panX, double panY)
    {
        if (videoW <= 0 || videoH <= 0) return null;
        double w = videoW, h = videoH;
        if (fill && windowW > 0 && windowH > 0)
        {
            var target = windowW / windowH;
            if (w / h > target) w = h * target;
            else h = w / target;
        }
        zoom = Math.Clamp(zoom, 1, 5);
        w /= zoom;
        h /= zoom;
        if (Math.Abs(w - videoW) < 1 && Math.Abs(h - videoH) < 1) return null;
        var x = (videoW - w) / 2 * (1 + Math.Clamp(panX, -1, 1));
        var y = (videoH - h) / 2 * (1 + Math.Clamp(panY, -1, 1));
        return string.Format(CultureInfo.InvariantCulture, "{0}x{1}+{2}+{3}",
            (int)Math.Round(w), (int)Math.Round(h), (int)Math.Round(x), (int)Math.Round(y));
    }
}
