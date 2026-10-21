using System.Globalization;
using Veltoret.Core.Data;

namespace Veltoret.App.Controls;

/// <summary>A poster card (Android PosterItem). Stable key: "m{id}" / "s{id}" / "c{id}".</summary>
public sealed record PosterItem
{
    public int Id { get; init; }
    public bool IsShow { get; init; }
    public bool IsCollection { get; init; }
    public string Title { get; init; } = "";
    public string? Subtitle { get; init; }
    public string? PosterUrl { get; init; }
    /// <summary>0..1 when partly watched, else null.</summary>
    public double? Progress { get; init; }
    public bool Watched { get; init; }
    public string? Badge { get; init; }
    /// <summary>False for collection parts that aren't in the library (dimmed, not clickable).</summary>
    public bool Clickable { get; init; } = true;
    public double Rating { get; init; }

    public string Key => IsCollection ? $"c{Id}" : IsShow ? $"s{Id}" : $"m{Id}";
    public double CardOpacity => Clickable ? 1 : 0.42;
    public bool HasProgress => Progress is > 0;
    public double ProgressValue => Progress ?? 0;
}

/// <summary>A wide card that plays something (Continue Watching, Next Up).</summary>
public sealed record PlayItem
{
    public string FileId { get; init; } = "";
    public string Title { get; init; } = "";
    public string? Subtitle { get; init; }
    public string? ImageUrl { get; init; }
    public double? Progress { get; init; }
    public string? Caption { get; init; }
    public int? MovieId { get; init; }
    public int? ShowId { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }

    public bool HasProgress => Progress != null;
    public double ProgressValue => Progress ?? 0;
}

/// <summary>Full-width row inside a <see cref="VirtualGrid"/> (section headers, chip strips, notes).</summary>
public interface IFullSpan { }

/// <summary>A header row of a grid: <see cref="Content"/> is shown across all columns.</summary>
public sealed record GridHeader(object Content) : IFullSpan;

/// <summary>Formatting rules from the Android app (US formats regardless of locale).</summary>
public static class Formats
{
    public static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    public static string Plural(int n, string one, string many) => $"{n} {(n == 1 ? one : many)}";

    /// <summary>"2h 46m", "48m", "2h"; null when ≤ 0.</summary>
    public static string? Runtime(int? minutes)
    {
        if (minutes is not > 0) return null;
        var h = minutes.Value / 60;
        var m = minutes.Value % 60;
        return h == 0 ? $"{m}m" : m == 0 ? $"{h}h" : $"{h}h {m}m";
    }

    public static string? RuntimeMs(long ms) => ms > 0 ? Runtime((int)Math.Round(ms / 60000.0)) : null;

    /// <summary>"{m}m left" / "{h}h {m}m left" (minimum 1 minute).</summary>
    public static string Remaining(long positionMs, long durationMs)
    {
        var mins = Math.Max(1, (int)Math.Ceiling(Math.Max(0, durationMs - positionMs) / 60000.0));
        var h = mins / 60;
        var m = mins % 60;
        return h > 0 ? $"{h}h {m}m left" : $"{m}m left";
    }

    /// <summary>"S1 · E2"; season 0 → "Special 2"; empty when null.</summary>
    public static string EpisodeCode(int? season, int? episode)
    {
        if (season == null || episode == null) return "";
        return season == 0 ? $"Special {episode}" : $"S{season} · E{episode}";
    }

    public static string Join(params string?[] parts) => string.Join("  ·  ", parts.Where(p => !string.IsNullOrWhiteSpace(p)));
    public static string JoinTight(params string?[] parts) => string.Join(" · ", parts.Where(p => !string.IsNullOrWhiteSpace(p)));

    public static DateTime? ParseDate(string? yyyyMmDd) =>
        DateTime.TryParseExact(yyyyMmDd, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;

    /// <summary>"Oct 23, 2015".</summary>
    public static string? LongDate(string? yyyyMmDd) => ParseDate(yyyyMmDd)?.ToString("MMM d, yyyy", Us);

    /// <summary>Today / Tomorrow / "Friday" (&lt; 7 days) / "Fri, Oct 23".</summary>
    public static string AirLabel(DateTime date)
    {
        var days = (date.Date - DateTime.Today).Days;
        if (days == 0) return "Today";
        if (days == 1) return "Tomorrow";
        if (days > 1 && days < 7) return date.ToString("dddd", Us);
        return date.ToString("ddd, MMM d", Us);
    }

    /// <summary>Reminder label: "Today at 9:00 PM" / "Tomorrow at …" / "Fri, Oct 23 at 9:00 PM".</summary>
    public static string ReminderLabel(DateTimeOffset at)
    {
        var local = at.ToLocalTime().DateTime;
        var days = (local.Date - DateTime.Today).Days;
        var day = days == 0 ? "Today" : days == 1 ? "Tomorrow" : local.ToString("ddd, MMM d", Us);
        return $"{day} at {local.ToString("h:mm tt", Us)}";
    }

    public static string Size(long bytes)
    {
        const double Kb = 1024, Mb = Kb * 1024, Gb = Mb * 1024;
        if (bytes >= Gb) return (bytes / Gb).ToString("0.0", Us) + " GB";
        if (bytes >= Mb) return (bytes / Mb).ToString("0", Us) + " MB";
        if (bytes >= Kb) return (bytes / Kb).ToString("0", Us) + " KB";
        return bytes + " B";
    }

    public static string Rating(double r) => r.ToString("0.0", Us);

    public static string Seasons(int n) => Plural(n, "season", "seasons");
    public static string Episodes(int n) => Plural(n, "episode", "episodes");
}

/// <summary>Builders shared by Home, grids, search and detail rows.</summary>
public static class PosterItems
{
    public static PosterItem Movie(MovieEntity m, WatchStateEntity? state, string? badge = null) => new()
    {
        Id = m.TmdbId,
        Title = m.Title,
        Subtitle = NullIfEmpty(Formats.JoinTight(m.Year?.ToString(), Formats.Runtime(m.RuntimeMin))),
        PosterUrl = Veltoret.Core.Tmdb.TmdbImages.Poster(m.PosterPath),
        Progress = state is { Watched: false, PositionMs: > 0 } ? state.Progress : null,
        Watched = state?.Watched == true,
        Badge = badge,
        Rating = m.Rating,
    };

    public static PosterItem Show(ShowEntity s, int availableEpisodes, string? subtitle = null, string? badge = null) => new()
    {
        Id = s.TmdbId,
        IsShow = true,
        Title = s.Name,
        Subtitle = subtitle ?? Formats.Episodes(availableEpisodes),
        PosterUrl = Veltoret.Core.Tmdb.TmdbImages.Poster(s.PosterPath),
        Badge = badge,
        Rating = s.Rating,
    };

    public static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;
}
