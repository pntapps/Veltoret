namespace Veltoret.Core.Plans;

/// <summary>
/// In-process reminder alarms: one timer aimed at the earliest reminder. Veltoret keeps running in the
/// notification area when its window is closed, so this covers reminders while the user is signed in; reminders
/// that came due while it wasn't running are handled by <see cref="PlansRepository.Restore"/> at the next start.
/// The timer re-checks at least every 30 minutes, so sleep and clock changes can't push a reminder far off.
/// </summary>
public sealed class ReminderScheduler : IReminderAlarms, IDisposable
{
    private static readonly long MaxWaitMs = (long)TimeSpan.FromMinutes(30).TotalMilliseconds;

    private readonly Func<long, Task> _fire;
    private readonly Func<long> _now;
    private readonly Dictionary<long, long> _pending = new();
    private readonly object _lock = new();
    private readonly Timer _timer;

    public ReminderScheduler(Func<long, Task> fire, Func<long>? now = null)
    {
        _fire = fire;
        _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        _timer = new Timer(_ => Tick(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public void Schedule(Data.ReminderEntity reminder)
    {
        lock (_lock) _pending[reminder.Id] = reminder.At;
        Arm();
    }

    public void Cancel(long id)
    {
        lock (_lock) _pending.Remove(id);
        Arm();
    }

    private void Arm()
    {
        lock (_lock)
        {
            if (_pending.Count == 0)
            {
                _timer.Change(Timeout.Infinite, Timeout.Infinite);
                return;
            }
            var wait = Math.Clamp(_pending.Values.Min() - _now(), 0, MaxWaitMs);
            _timer.Change(wait, Timeout.Infinite);
        }
    }

    private void Tick()
    {
        List<long> due;
        lock (_lock)
        {
            var now = _now();
            due = _pending.Where(p => p.Value <= now).OrderBy(p => p.Value).Select(p => p.Key).ToList();
            foreach (var id in due) _pending.Remove(id);
        }
        Arm();
        foreach (var id in due)
        {
            _ = Task.Run(async () =>
            {
                try { await _fire(id); }
                catch (Exception) { /* a failed fire is retried by the next Restore while it isn't stale */ }
            });
        }
    }

    public void Dispose() => _timer.Dispose();
}
