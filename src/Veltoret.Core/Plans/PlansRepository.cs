using Veltoret.Core.Data;

namespace Veltoret.Core.Plans;

/// <summary>Posts reminder and new-episode notifications (Windows toasts, implemented by the app).</summary>
public interface IPlanNotifier
{
    /// <summary>False when Windows notifications are off for Veltoret (reminders then stay pending).</summary>
    bool CanPost { get; }
    Task ShowReminder(ReminderEntity reminder);
    Task ShowNewEpisode(ShowEntity show);
}

/// <summary>Wakes the repository when a reminder comes due (Android: AlarmManager).</summary>
public interface IReminderAlarms
{
    void Schedule(ReminderEntity reminder);
    void Cancel(long id);
}

/// <summary>
/// The watchlist ("Watch later") and reminders ("Remind me"), Android's PlansRepository. Reminders fire through
/// <see cref="IReminderAlarms"/> while Veltoret runs (it stays in the notification area); <see cref="Restore"/> on
/// every start shows the ones that came due while it wasn't running (up to 12 hours late) exactly once.
/// </summary>
public sealed class PlansRepository
{
    /// <summary>"Snooze 1 hour".</summary>
    public const long SnoozeMs = 60L * 60 * 1000;

    private readonly PlansDao _dao;
    private readonly Func<long> _now;

    public PlansRepository(PlansDao dao, Func<long>? now = null)
    {
        _dao = dao;
        _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }

    public IPlanNotifier? Notifier { get; set; }
    public IReminderAlarms? Alarms { get; set; }

    // Watchlist

    public Task<bool> IsInWatchlist(string type, int id) => _dao.IsInWatchlist(type, id);

    /// <summary>Newest first.</summary>
    public Task<List<WatchlistEntity>> Watchlist() => _dao.Watchlist();

    public Task SetWatchlist(string type, int id, bool on) =>
        on ? _dao.AddToWatchlist(new WatchlistEntity { MediaType = type, MediaId = id, AddedAt = _now() })
           : _dao.RemoveFromWatchlist(type, id);

    // Reminders

    /// <summary>All pending reminders, soonest first.</summary>
    public Task<List<ReminderEntity>> Reminders() => _dao.Reminders();

    public Task<List<ReminderEntity>> RemindersFor(string type, int id) => _dao.RemindersFor(type, id);

    public Task<long> AddReminder(string type, int id, int? season, int? episode, string title, DateTimeOffset at) =>
        AddReminder(type, id, season, episode, title, at.ToUnixTimeMilliseconds(), addToWatchlist: true);

    /// <summary>Saves and schedules a reminder; a new one also puts the title on the watchlist (a snooze doesn't).</summary>
    public async Task<long> AddReminder(string type, int id, int? season, int? episode, string title, long at, bool addToWatchlist)
    {
        var r = new ReminderEntity
        {
            MediaType = type, MediaId = id, Season = season, Episode = episode, Title = title, At = at, CreatedAt = _now(),
        };
        var saved = r with { Id = await _dao.InsertReminder(r) };
        Alarms?.Schedule(saved);
        if (addToWatchlist && !await _dao.IsInWatchlist(type, id)) await SetWatchlist(type, id, true);
        return saved.Id;
    }

    /// <summary>"Snooze 1 hour" on a reminder toast: the same reminder an hour from now, without touching the watchlist.</summary>
    public Task<long> Snooze(string type, int id, int? season, int? episode, string title) =>
        AddReminder(type, id, season, episode, title, _now() + SnoozeMs, addToWatchlist: false);

    public async Task RemoveReminder(long id)
    {
        await _dao.DeleteReminder(id);
        Alarms?.Cancel(id);
    }

    /// <summary>
    /// Shows a due reminder exactly once: the timer, app start and resume can all find the same row at the same
    /// time, and only the caller whose delete removes it posts the notification. When notifications are off the
    /// row is kept (Settings shows it with a warning) until it goes stale.
    /// </summary>
    public async Task<bool> Fire(long id)
    {
        var r = await _dao.Reminder(id);
        if (r == null) return false;
        var notifier = Notifier;
        if (notifier == null || !notifier.CanPost) return false;
        if (await _dao.DeleteReminder(id) == 0) return false;
        try { await notifier.ShowReminder(r); }
        catch (Exception) { /* the row is gone either way: never show it twice */ }
        return true;
    }

    /// <summary>Schedules what's ahead, drops what's more than 12 hours late, and returns what's slightly late.</summary>
    public async Task<List<ReminderEntity>> RescheduleAll()
    {
        var now = _now();
        var overdue = new List<ReminderEntity>();
        foreach (var r in await _dao.Reminders())
        {
            switch (Plans.Due(r.At, now))
            {
                case Plans.DueKind.Schedule: Alarms?.Schedule(r); break;
                case Plans.DueKind.FireNow: overdue.Add(r); break;
                default: await _dao.DeleteReminder(r.Id); break;
            }
        }
        return overdue;
    }

    /// <summary>Every start (and after the PC resumes or the clock changes): <see cref="RescheduleAll"/>, then shows what came due.</summary>
    public async Task Restore()
    {
        foreach (var r in await RescheduleAll()) await Fire(r.Id);
    }
}
