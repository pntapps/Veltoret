using Veltoret.Core.Plans;
using P = Veltoret.Core.Plans.Plans;

namespace Veltoret.Core.Tests.Plans;

/// <summary>Port of the Android PlansTest.</summary>
public class PlansTest
{
    // A Monday.
    private static readonly DateOnly Monday = new(2026, 10, 19);

    private static DateTime At(DateOnly d, int h, int m) => d.ToDateTime(new TimeOnly(h, m));

    [Fact]
    public void QuickTimesOfferTonightOnlyWhileItsAhead()
    {
        Assert.Equal(new[] { "Tonight, 8 PM", "Tomorrow, 8 PM", "Saturday, 8 PM" },
            P.QuickTimes(At(Monday, 15, 0)).Select(t => t.Label));
        Assert.Equal(new[] { "Tomorrow, 8 PM", "Saturday, 8 PM" },
            P.QuickTimes(At(Monday, 21, 0)).Select(t => t.Label));
    }

    [Fact]
    public void QuickTimesSkipSaturdayWhenItIsTomorrow()
    {
        var times = P.QuickTimes(new DateTime(2026, 10, 23, 10, 0, 0));
        Assert.Equal(new[] { "Tonight, 8 PM", "Tomorrow, 8 PM" }, times.Select(t => t.Label));
        Assert.Equal(new DateTime(2026, 10, 24, 20, 0, 0), times[1].At);
    }

    [Fact]
    public void QuickTimesOnSaturdayMeanNextWeek()
    {
        var times = P.QuickTimes(new DateTime(2026, 10, 24, 10, 0, 0));
        Assert.Equal(new DateTime(2026, 10, 31, 20, 0, 0), times[2].At);
    }

    [Fact]
    public void AirLabels()
    {
        Assert.Equal("Today", P.AirLabel("2026-10-19", Monday));
        Assert.Equal("Tomorrow", P.AirLabel("2026-10-20", Monday));
        Assert.Equal("Friday", P.AirLabel("2026-10-23", Monday));
        Assert.Equal("Mon, Oct 26", P.AirLabel("2026-10-26", Monday));
        Assert.Null(P.AirLabel("2026-10-18", Monday));
        Assert.Null(P.AirLabel("", Monday));
        Assert.Null(P.AirLabel("not a date", Monday));
    }

    [Fact]
    public void UpcomingIncludesToday()
    {
        Assert.True(P.IsUpcoming("2026-10-19", Monday));
        Assert.True(P.IsUpcoming("2027-01-01", Monday));
        Assert.False(P.IsUpcoming("2026-10-18", Monday));
        Assert.False(P.IsUpcoming(null, Monday));
    }

    [Fact]
    public void ReminderLabels()
    {
        var now = At(Monday, 12, 0);
        static long Utc(DateTime t) => new DateTimeOffset(t, TimeSpan.Zero).ToUnixTimeMilliseconds();
        Assert.Equal("Today at 8:00 PM", P.ReminderLabel(Utc(At(Monday, 20, 0)), now, TimeZoneInfo.Utc));
        Assert.Equal("Tomorrow at 9:30 AM", P.ReminderLabel(Utc(At(Monday.AddDays(1), 9, 30)), now, TimeZoneInfo.Utc));
        Assert.Equal("Fri, Oct 23 at 8:00 PM", P.ReminderLabel(Utc(At(Monday.AddDays(4), 20, 0)), now, TimeZoneInfo.Utc));
    }

    [Fact]
    public void OverdueRemindersFireWithinTwelveHoursThenDrop()
    {
        const long now = 1_000_000_000_000L;
        Assert.Equal(P.DueKind.Schedule, P.Due(now + 60_000, now));
        Assert.Equal(P.DueKind.FireNow, P.Due(now - 60_000, now));
        Assert.Equal(P.DueKind.FireNow, P.Due(now - P.StaleAfterMs, now));
        Assert.Equal(P.DueKind.Drop, P.Due(now - P.StaleAfterMs - 1, now));
    }

    [Fact]
    public void StillAiringStatuses()
    {
        Assert.True(P.StillAiring("Returning Series"));
        Assert.True(P.StillAiring("In Production"));
        Assert.False(P.StillAiring("Ended"));
        Assert.False(P.StillAiring("Canceled"));
        Assert.False(P.StillAiring(null));
    }

    [Fact]
    public void ToMillisRoundTrips()
    {
        var t = new DateTime(2026, 10, 19, 20, 0, 0);
        Assert.Equal(new DateTimeOffset(t, TimeSpan.Zero).ToUnixTimeMilliseconds(), P.ToMillis(t, TimeZoneInfo.Utc));
    }

    [Fact]
    public void EpisodeCodes()
    {
        Assert.Equal("S3 · E2", PlanFormat.EpisodeCode(3, 2));
        Assert.Equal("Special 4", PlanFormat.EpisodeCode(0, 4));
        Assert.Equal("", PlanFormat.EpisodeCode(null, 4));
        Assert.Equal("2h 46m", PlanFormat.Runtime(166));
        Assert.Equal("Oct 23, 2026", PlanFormat.Date("2026-10-23"));
    }
}
