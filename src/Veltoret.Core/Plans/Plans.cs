using System.Globalization;

namespace Veltoret.Core.Plans;

/// <summary>What a notification opens: a movie, a show, or one episode of it; <see cref="Play"/> starts it right away.</summary>
public sealed record OpenTarget(string MediaType, int MediaId, int? Season = null, int? Episode = null, bool Play = false);

/// <summary>Pure date and time rules for watchlist, reminders and upcoming episodes (Android: data/plans/Plans.kt; PlansTest).</summary>
public static class Plans
{
    public const string Movie = "movie";
    public const string Tv = "tv";

    /// <summary>Reminders that fire late (PC off or asleep) still show if they're less than this overdue; older ones are dropped.</summary>
    public const long StaleAfterMs = 12L * 60 * 60 * 1000;

    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    /// <summary>TMDB statuses of shows still being made (their next episode can change).</summary>
    private static readonly HashSet<string> Airing = new(StringComparer.Ordinal) { "Returning Series", "In Production", "Planned", "Pilot" };

    public static bool StillAiring(string? status) => status != null && Airing.Contains(status);

    /// <summary>One-tap reminder times: tonight 8 PM (while it's still ahead), tomorrow 8 PM, Saturday 8 PM. <paramref name="now"/> is local time.</summary>
    public static List<(string Label, DateTime At)> QuickTimes(DateTime now)
    {
        var today = now.Date;
        var evening = TimeSpan.FromHours(20);
        // TemporalAdjusters.next: strictly after today, so on a Saturday it's a week later.
        var daysToSaturday = ((int)DayOfWeek.Saturday - (int)today.DayOfWeek + 7) % 7;
        if (daysToSaturday == 0) daysToSaturday = 7;
        var saturday = today.AddDays(daysToSaturday);
        var list = new List<(string, DateTime)>();
        if (now.TimeOfDay < new TimeSpan(19, 30, 0)) list.Add(("Tonight, 8 PM", today + evening));
        list.Add(("Tomorrow, 8 PM", today.AddDays(1) + evening));
        if (saturday != today.AddDays(1)) list.Add(("Saturday, 8 PM", saturday + evening));
        return list;
    }

    /// <summary>"Today", "Tomorrow", "Friday" within a week, then "Fri, Oct 23". <paramref name="date"/> is TMDB's "yyyy-MM-dd".</summary>
    public static string? AirLabel(string? date, DateOnly today)
    {
        if (Parse(date) is not { } d) return null;
        var days = d.DayNumber - today.DayNumber;
        return days switch
        {
            < 0 => null,
            0 => "Today",
            1 => "Tomorrow",
            < 7 => d.ToString("dddd", Us),
            _ => d.ToString("ddd, MMM d", Us),
        };
    }

    /// <summary>True when the episode airs today or later (yesterday's "next episode" is stale).</summary>
    public static bool IsUpcoming(string? date, DateOnly today) => Parse(date) is { } d && d >= today;

    /// <summary>"Fri, Oct 23 at 9:00 PM" (or "Today at …" / "Tomorrow at …"). <paramref name="now"/> is local to <paramref name="zone"/>.</summary>
    public static string ReminderLabel(long at, DateTime now, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var t = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(at), zone).DateTime;
        var time = t.ToString("h:mm tt", Us);
        var days = DateOnly.FromDateTime(t).DayNumber - DateOnly.FromDateTime(now).DayNumber;
        var day = days switch
        {
            0 => "Today",
            1 => "Tomorrow",
            _ => t.ToString("ddd, MMM d", Us),
        };
        return $"{day} at {time}";
    }

    /// <summary>At start-up or after a resume: schedule what's ahead, show what's slightly overdue, drop the rest.</summary>
    public enum DueKind { Schedule, FireNow, Drop }

    public static DueKind Due(long at, long now) =>
        at > now ? DueKind.Schedule : now - at <= StaleAfterMs ? DueKind.FireNow : DueKind.Drop;

    /// <summary>Local wall-clock time (in <paramref name="zone"/>) to epoch milliseconds.</summary>
    public static long ToMillis(DateTime local, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var unspecified = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        var utc = TimeZoneInfo.ConvertTimeToUtc(zone.IsInvalidTime(unspecified) ? unspecified.AddHours(1) : unspecified, zone);
        return new DateTimeOffset(utc, TimeSpan.Zero).ToUnixTimeMilliseconds();
    }

    public static DateOnly? Parse(string? date) =>
        !string.IsNullOrWhiteSpace(date) &&
        DateOnly.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
            ? d
            : null;
}
