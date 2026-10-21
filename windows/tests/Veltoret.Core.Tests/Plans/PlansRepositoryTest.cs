using Veltoret.Core.Data;
using Veltoret.Core.Plans;
using Veltoret.Core.Settings;
using P = Veltoret.Core.Plans.Plans;

namespace Veltoret.Core.Tests.Plans;

/// <summary>Fire-once, restore, snooze and new-episode alert rules against a real SQLite file.</summary>
public sealed class PlansRepositoryTest : IDisposable
{
    private sealed class FakeNotifier : IPlanNotifier
    {
        public bool CanPost { get; set; } = true;
        public List<ReminderEntity> Reminders { get; } = new();
        public List<ShowEntity> Episodes { get; } = new();
        public Task ShowReminder(ReminderEntity reminder) { lock (Reminders) Reminders.Add(reminder); return Task.CompletedTask; }
        public Task ShowNewEpisode(ShowEntity show) { Episodes.Add(show); return Task.CompletedTask; }
    }

    private sealed class FakeAlarms : IReminderAlarms
    {
        public HashSet<long> Scheduled { get; } = new();
        public void Schedule(ReminderEntity reminder) => Scheduled.Add(reminder.Id);
        public void Cancel(long id) => Scheduled.Remove(id);
    }

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "veltoret-plans-" + Guid.NewGuid().ToString("N"));
    private readonly VeltoretDb _db;
    private readonly PlansDao _dao;
    private long _now = 1_800_000_000_000L;
    private readonly PlansRepository _repo;
    private readonly FakeNotifier _notifier = new();
    private readonly FakeAlarms _alarms = new();

    public PlansRepositoryTest()
    {
        _db = new VeltoretDb(Path.Combine(_dir, "test.db"));
        _dao = new PlansDao(_db);
        _repo = new PlansRepository(_dao, () => _now) { Notifier = _notifier, Alarms = _alarms };
    }

    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try { Directory.Delete(_dir, true); } catch (IOException) { }
    }

    [Fact]
    public async Task NewReminderSchedulesAndAddsToWatchlist()
    {
        var id = await _repo.AddReminder(P.Movie, 5, null, null, "Dune", _now + 60_000, addToWatchlist: true);
        Assert.Contains(id, _alarms.Scheduled);
        Assert.True(await _repo.IsInWatchlist(P.Movie, 5));
    }

    [Fact]
    public async Task SnoozeDoesNotTouchTheWatchlist()
    {
        await _repo.Snooze(P.Tv, 8, 1, 2, "Below · S1 · E2");
        Assert.False(await _repo.IsInWatchlist(P.Tv, 8));
        var r = Assert.Single(await _repo.Reminders());
        Assert.Equal(_now + PlansRepository.SnoozeMs, r.At);
        Assert.Equal(2, r.Episode);
    }

    [Fact]
    public async Task FiresOnceEvenWhenCalledTwice()
    {
        var id = await _repo.AddReminder(P.Movie, 5, null, null, "Dune", _now - 1000, addToWatchlist: false);
        var results = await Task.WhenAll(_repo.Fire(id), _repo.Fire(id), _repo.Fire(id));
        Assert.Single(results, r => r);
        Assert.Single(_notifier.Reminders);
        Assert.Empty(await _repo.Reminders());
    }

    [Fact]
    public async Task NotificationsOffKeepsTheRow()
    {
        _notifier.CanPost = false;
        var id = await _repo.AddReminder(P.Movie, 5, null, null, "Dune", _now - 1000, addToWatchlist: false);
        Assert.False(await _repo.Fire(id));
        Assert.Single(await _repo.Reminders());
        Assert.Empty(_notifier.Reminders);
    }

    [Fact]
    public async Task RestoreSchedulesFutureFiresRecentDropsStale()
    {
        var future = await _repo.AddReminder(P.Movie, 1, null, null, "Future", _now + 60_000, false);
        var recent = await _repo.AddReminder(P.Movie, 2, null, null, "Recent", _now - P.StaleAfterMs, false);
        await _repo.AddReminder(P.Movie, 3, null, null, "Stale", _now - P.StaleAfterMs - 1, false);
        _alarms.Scheduled.Clear();

        await _repo.Restore();

        Assert.Equal(new[] { future }, _alarms.Scheduled);
        Assert.Equal(recent, Assert.Single(_notifier.Reminders).Id);
        Assert.Equal(new[] { future }, (await _repo.Reminders()).Select(r => r.Id));
    }

    [Fact]
    public async Task RemoveCancelsTheAlarm()
    {
        var id = await _repo.AddReminder(P.Movie, 1, null, null, "Future", _now + 60_000, false);
        await _repo.RemoveReminder(id);
        Assert.Empty(_alarms.Scheduled);
        Assert.Empty(await _repo.Reminders());
    }

    [Fact]
    public async Task SchedulerFiresDueReminders()
    {
        var fired = new TaskCompletionSource<long>();
        using var scheduler = new ReminderScheduler(id => { fired.TrySetResult(id); return Task.CompletedTask; });
        scheduler.Schedule(new ReminderEntity { Id = 42, At = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 50 });
        var done = await Task.WhenAny(fired.Task, Task.Delay(5000));
        Assert.Same(fired.Task, done);
        Assert.Equal(42, await fired.Task);
    }

    [Fact]
    public async Task NewEpisodeAlertsOncePerEpisodeForWatchlistShows()
    {
        var catalog = new CatalogDao(_db);
        var settings = new SettingsStore(Path.Combine(_dir, "settings.json"));
        settings.Update(s => s with { OnboardingComplete = true });
        var today = new DateTime(2026, 10, 19, 10, 0, 0);
        var day = "2026-10-19";
        var fresh = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        await catalog.UpsertShow(new ShowEntity { TmdbId = 8, Name = "Below", Status = "Returning Series", UpdatedAt = fresh, NextEpisodeSeason = 2, NextEpisodeNumber = 3, NextEpisodeAirDate = day });
        await catalog.UpsertShow(new ShowEntity { TmdbId = 9, Name = "Not saved", Status = "Returning Series", UpdatedAt = fresh, NextEpisodeAirDate = day });
        await catalog.UpsertShow(new ShowEntity { TmdbId = 10, Name = "No numbers", Status = "Returning Series", UpdatedAt = fresh, NextEpisodeAirDate = day });
        await _repo.SetWatchlist(P.Tv, 8, true);
        await _repo.SetWatchlist(P.Tv, 10, true);
        var refreshed = new List<int>();
        var upcoming = new UpcomingService(_repo, catalog, new WatchDao(_db), settings,
            id => { refreshed.Add(id); return Task.CompletedTask; }, () => true, () => today);

        await upcoming.Run();
        await upcoming.Run();

        Assert.Equal(new[] { 8, 10 }, _notifier.Episodes.Select(s => s.TmdbId).OrderBy(i => i));
        Assert.Empty(refreshed); // refreshed less than 20 h ago
        Assert.Equal(new[] { "2026-10-19|10:null:null", "2026-10-19|8:2:3" }, settings.Current.AlertedEpisodes);
    }

    [Fact]
    public async Task StaleFollowedShowsAreRefreshed()
    {
        var catalog = new CatalogDao(_db);
        var settings = new SettingsStore(Path.Combine(_dir, "settings.json"));
        settings.Update(s => s with { OnboardingComplete = true, NewEpisodeAlerts = false });
        var old = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - UpcomingService.RefreshMs - 1;
        await catalog.UpsertShow(new ShowEntity { TmdbId = 1, Name = "Airing", Status = "Returning Series", UpdatedAt = old });
        await catalog.UpsertShow(new ShowEntity { TmdbId = 2, Name = "Ended", Status = "Ended", UpdatedAt = old });
        await catalog.UpsertShow(new ShowEntity { TmdbId = 3, Name = "Not followed", Status = "Returning Series", UpdatedAt = old });
        await _repo.SetWatchlist(P.Tv, 1, true);
        await _repo.SetWatchlist(P.Tv, 2, true);
        var refreshed = new List<int>();
        var upcoming = new UpcomingService(_repo, catalog, new WatchDao(_db), settings,
            id => { refreshed.Add(id); return Task.CompletedTask; }, () => true);
        await upcoming.Run();
        Assert.Equal(new[] { 1 }, refreshed);
    }

    [Fact]
    public void PruneKeepsTheNewest200()
    {
        var keys = Enumerable.Range(0, 250).Select(i => $"2026-01-01|{i:D3}:1:1").Reverse();
        var kept = UpcomingService.Prune(keys);
        Assert.Equal(200, kept.Count);
        Assert.Equal("2026-01-01|050:1:1", kept[0]);
        Assert.Equal("2026-01-01|249:1:1", kept[^1]);
    }
}
