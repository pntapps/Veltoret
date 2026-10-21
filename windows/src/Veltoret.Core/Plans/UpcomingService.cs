using Veltoret.Core.Data;
using Veltoret.Core.Settings;

namespace Veltoret.Core.Plans;

/// <summary>
/// Android's UpcomingWorker. Once a day around 10 AM (and once at start): refreshes the next episode of shows the
/// user follows (on the Watchlist or started) that are still airing, and posts "New episode of …" for Watchlist
/// shows airing today. Library scans refresh shows only weekly, which is too slow for air dates.
/// </summary>
public sealed class UpcomingService : IDisposable
{
    /// <summary>A bit under a day, so the daily run always refreshes.</summary>
    public const long RefreshMs = 20L * 60 * 60 * 1000;
    public const int MaxAlerted = 200;

    private readonly PlansRepository _plans;
    private readonly CatalogDao _catalog;
    private readonly WatchDao _watch;
    private readonly SettingsStore _settings;
    private readonly Func<int, Task> _refreshShow;
    private readonly Func<bool> _isOnline;
    private readonly Func<DateTime> _localNow;
    private readonly SemaphoreSlim _running = new(1, 1);
    private Timer? _timer;
    private volatile bool _waitingForNetwork;

    /// <param name="refreshShow">Refetches /tv/{id} (TmdbRepository.EnsureShow with the 20 h limit).</param>
    public UpcomingService(PlansRepository plans, CatalogDao catalog, WatchDao watch, SettingsStore settings,
        Func<int, Task> refreshShow, Func<bool> isOnline, Func<DateTime>? localNow = null)
    {
        _plans = plans;
        _catalog = catalog;
        _watch = watch;
        _settings = settings;
        _refreshShow = refreshShow;
        _isOnline = isOnline;
        _localNow = localNow ?? (() => DateTime.Now);
    }

    public IPlanNotifier? Notifier { get; set; }

    /// <summary>Runs once now (or as soon as the network is back), then daily at the next 10:00.</summary>
    public void Start()
    {
        _timer ??= new Timer(_ =>
        {
            // Wake-ups before 10:00 only re-aim the timer.
            if (_localNow() >= _target) RunWhenOnline();
            ArmDaily();
        }, null, Timeout.Infinite, Timeout.Infinite);
        ArmDaily();
        RunWhenOnline();
    }

    /// <summary>Call when the network comes back: a run that was due while offline happens now.</summary>
    public void OnOnline()
    {
        if (_waitingForNetwork) RunWhenOnline();
    }

    private void ArmDaily()
    {
        var now = _localNow();
        var next = now.Date.AddHours(10);
        if (next <= now) next = next.AddDays(1);
        // Re-aim at least every 6 hours so sleep and clock changes don't skip a day.
        var wait = Math.Min((next - now).TotalMilliseconds, TimeSpan.FromHours(6).TotalMilliseconds);
        _target = next;
        _timer?.Change((long)Math.Max(wait, 1000), Timeout.Infinite);
    }

    private DateTime _target = DateTime.MaxValue;

    private void RunWhenOnline()
    {
        if (!_isOnline())
        {
            _waitingForNetwork = true;
            return;
        }
        _waitingForNetwork = false;
        _ = Task.Run(async () =>
        {
            try { await Run(); }
            catch (Exception) { }
        });
    }

    /// <summary>The worker's doWork. Public for tests and for a manual refresh.</summary>
    public async Task Run()
    {
        if (!await _running.WaitAsync(0)) return;
        try
        {
            var settings = _settings.Current;
            if (!settings.OnboardingComplete) return;
            var today = DateOnly.FromDateTime(_localNow());

            var watchlistShows = (await _plans.Watchlist()).Where(w => w.MediaType == Plans.Tv).Select(w => w.MediaId).ToHashSet();
            var followed = new HashSet<int>(watchlistShows);
            followed.UnionWith(await _watch.WatchedShowIds());

            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var id in followed)
            {
                var show = await _catalog.Show(id);
                if (show == null) continue;
                if (!Plans.StillAiring(show.Status) && show.NextEpisodeAirDate == null) continue;
                if (nowMs - show.UpdatedAt < RefreshMs) continue;
                try { await _refreshShow(id); }
                catch (Exception) { /* per show: one failure doesn't stop the rest */ }
            }

            if (settings.NewEpisodeAlerts) await CheckAlerts(watchlistShows, today);
        }
        finally
        {
            _running.Release();
        }
    }

    private async Task CheckAlerts(IEnumerable<int> watchlistShows, DateOnly today)
    {
        var day = today.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        // "2026-10-23|showId:season:episode": the date prefix sorts, so pruning keeps the newest.
        var alerted = new HashSet<string>(_settings.Current.AlertedEpisodes, StringComparer.Ordinal);
        var added = false;
        foreach (var id in watchlistShows)
        {
            var show = await _catalog.Show(id);
            if (show == null || show.NextEpisodeAirDate != day) continue;
            var key = AlertKey(day, id, show.NextEpisodeSeason, show.NextEpisodeNumber);
            if (alerted.Contains(key)) continue;
            var notifier = Notifier ?? _plans.Notifier;
            if (notifier == null || !notifier.CanPost) continue;
            try { await notifier.ShowNewEpisode(show); }
            catch (Exception) { }
            alerted.Add(key);
            added = true;
        }
        var pruned = Prune(alerted);
        if (added || pruned.Count != _settings.Current.AlertedEpisodes.Count)
            _settings.Update(s => s with { AlertedEpisodes = pruned });
    }

    /// <summary>Kotlin prints a null Int as "null" in a string template; keys keep that spelling.</summary>
    public static string AlertKey(string day, int showId, int? season, int? episode) =>
        $"{day}|{showId}:{season?.ToString() ?? "null"}:{episode?.ToString() ?? "null"}";

    /// <summary>The newest 200 keys (ordinal sort, keep the last).</summary>
    public static List<string> Prune(IEnumerable<string> keys)
    {
        var sorted = keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        return sorted.Count <= MaxAlerted ? sorted : sorted.GetRange(sorted.Count - MaxAlerted, MaxAlerted);
    }

    public void Dispose() => _timer?.Dispose();
}
