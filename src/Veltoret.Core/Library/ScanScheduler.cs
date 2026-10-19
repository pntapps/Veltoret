using Veltoret.Core.Net;
using Veltoret.Core.Settings;

namespace Veltoret.Core.Library;

/// <summary>
/// When library scans run (Android SyncWorker + WorkManager). One scan at a time from a serial queue:
/// <list type="bullet">
/// <item>User scans (<see cref="RunNow"/>: "Scan library now", a folder's scan, adding a folder, saving a TMDB key)
/// queue up behind the running one.</item>
/// <item>Automatic scans (<see cref="RequestAutomatic"/>: after renames, moves, extraction, Fix match, coming back
/// online, every 12 hours) are dropped while another scan is queued or running, since that scan covers them.</item>
/// </list>
/// A failed scan is retried twice. After a scan that went online and wasn't cancelled, artwork is prefetched.
/// </summary>
public sealed class ScanScheduler : IDisposable
{
    public static readonly TimeSpan Period = TimeSpan.FromHours(12);

    private readonly LibraryScanner _scanner;
    private readonly Connectivity _connectivity;
    private readonly SettingsStore _settings;
    private readonly ArtworkPrefetch _prefetch;

    private readonly object _lock = new();
    private readonly Queue<Request> _queue = new();
    private bool _running;
    private bool _started;
    private Timer? _timer;
    private int _prefetching;

    private sealed record Request(IReadOnlySet<long>? FolderIds, bool Automatic, TaskCompletionSource Done);

    public ScanScheduler(LibraryScanner scanner, Connectivity connectivity, SettingsStore settings, ArtworkPrefetch prefetch)
    {
        _scanner = scanner;
        _connectivity = connectivity;
        _settings = settings;
        _prefetch = prefetch;
    }

    /// <summary>True while a scan runs or waits in the queue.</summary>
    public bool Busy
    {
        get { lock (_lock) return _running || _queue.Count > 0; }
    }

    /// <summary>Starts the 12-hour schedule (checked hourly against the last whole-library scan) and the back-online trigger.</summary>
    public void Start()
    {
        lock (_lock)
        {
            if (_started) return;
            _started = true;
        }
        _connectivity.OnlineChanged += online =>
        {
            if (online && _settings.Current.OnboardingComplete) RequestAutomatic();
        };
        // First check shortly after startup, then every hour: a periodic scan is due 12 h after the last one.
        _timer = new Timer(_ => PeriodicCheck(), null, TimeSpan.FromSeconds(20), TimeSpan.FromHours(1));
    }

    private void PeriodicCheck()
    {
        var s = _settings.Current;
        if (!s.OnboardingComplete) return;
        var last = DateTimeOffset.FromUnixTimeMilliseconds(Math.Max(0, s.LastScanAt));
        if (DateTimeOffset.UtcNow - last >= Period) RequestAutomatic();
    }

    /// <summary>A scan the user asked for: queued behind a running one. Completes when this scan has finished.</summary>
    public Task RunNow(IReadOnlySet<long>? folderIds = null) => Enqueue(folderIds, automatic: false);

    /// <summary>An automatic whole-library scan; ignored when a scan is already queued or running.</summary>
    public void RequestAutomatic()
    {
        lock (_lock)
        {
            if (_running || _queue.Count > 0) return;
        }
        _ = Enqueue(null, automatic: true);
    }

    /// <summary>Stops the running scan (keeping what it already found) and drops queued ones.</summary>
    public void Cancel()
    {
        List<Request> dropped;
        lock (_lock)
        {
            dropped = _queue.ToList();
            _queue.Clear();
        }
        _scanner.Cancel();
        foreach (var r in dropped) r.Done.TrySetResult();
    }

    private Task Enqueue(IReadOnlySet<long>? folderIds, bool automatic)
    {
        var request = new Request(folderIds, automatic, new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        bool start;
        lock (_lock)
        {
            if (automatic && (_running || _queue.Count > 0)) return Task.CompletedTask;
            _queue.Enqueue(request);
            start = !_running;
            if (start) _running = true;
        }
        if (start) _ = Task.Run(Drain);
        return request.Done.Task;
    }

    private async Task Drain()
    {
        while (true)
        {
            Request next;
            lock (_lock)
            {
                if (_queue.Count == 0)
                {
                    _running = false;
                    return;
                }
                next = _queue.Dequeue();
            }
            try
            {
                await RunOne(next).ConfigureAwait(false);
            }
            finally
            {
                next.Done.TrySetResult();
            }
        }
    }

    private async Task RunOne(Request request)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                // A scan started directly on the scanner (not through here) holds it: wait for that one first.
                while (_scanner.IsBusy) await Task.Delay(500).ConfigureAwait(false);
                await _scanner.Scan(request.FolderIds).ConfigureAwait(false);
                break;
            }
            catch (Exception)
            {
                if (attempt == 2) return;
                await Task.Delay(TimeSpan.FromSeconds(30 * (attempt + 1))).ConfigureAwait(false);
            }
        }
        // Keep artwork on this PC for offline use; a failure here never fails the scan.
        if (_connectivity.IsOnline && !_scanner.State.Cancelled && Interlocked.Exchange(ref _prefetching, 1) == 0)
        {
            _ = Task.Run(async () =>
            {
                try { await _prefetch.Run().ConfigureAwait(false); }
                catch { }
                finally { Interlocked.Exchange(ref _prefetching, 0); }
            });
        }
    }

    public void Dispose() => _timer?.Dispose();
}
