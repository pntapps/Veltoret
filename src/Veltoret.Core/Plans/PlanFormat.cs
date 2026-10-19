using System.Globalization;

namespace Veltoret.Core.Plans;

/// <summary>The Format.kt helpers reminders, notifications and Settings need (en-US only).</summary>
public static class PlanFormat
{
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    /// <summary>"S3 · E2", "Special 4", or "" when either is missing.</summary>
    public static string EpisodeCode(int? season, int? episode) =>
        season == null || episode == null ? "" : season == 0 ? $"Special {episode}" : $"S{season} · E{episode}";

    /// <summary>"48m", "2h", "2h 46m"; null when unknown.</summary>
    public static string? Runtime(int? minutes)
    {
        if (minutes is not > 0) return null;
        int h = minutes.Value / 60, m = minutes.Value % 60;
        return h == 0 ? $"{m}m" : m == 0 ? $"{h}h" : $"{h}h {m}m";
    }

    /// <summary>"Never", "Just now", "5 min ago", "3 h ago", "2 days ago" ("1 days ago" is what Android prints too).</summary>
    public static string Relative(long epochMs, long? nowMs = null)
    {
        if (epochMs <= 0) return "Never";
        var diff = (nowMs ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) - epochMs;
        var min = diff / 60_000;
        if (min < 1) return "Just now";
        if (min < 60) return $"{min} min ago";
        var h = min / 60;
        if (h < 24) return $"{h} h ago";
        return $"{h / 24} days ago";
    }

    /// <summary>"yyyy-MM-dd" as "Oct 23, 2026"; null when blank or invalid.</summary>
    public static string? Date(string? isoDate) => Plans.Parse(isoDate)?.ToString("MMM d, yyyy", Us);

    public static string Date(DateOnly d) => d.ToString("MMM d, yyyy", Us);
}
