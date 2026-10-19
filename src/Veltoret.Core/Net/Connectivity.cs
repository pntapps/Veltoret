using System.Net.NetworkInformation;

namespace Veltoret.Core.Net;

/// <summary>
/// Whether this PC can reach the internet right now. Drives "offline mode": when it's false the library shows
/// only titles that can play from this PC, scans skip Drive/network folders and TMDB, and Drive-only actions
/// explain that they need a connection.
///
/// Re-evaluated when Windows reports a network change (debounced) and every minute. The check is
/// <see cref="SystemCheck"/> when the app sets one (Windows' NCSI "internet access" level), else an HTTP probe.
/// <see cref="OnlineChanged"/> fires on a background thread; UI code must marshal to its dispatcher.
/// </summary>
public sealed class Connectivity : IDisposable
{
    private static readonly string[] ProbeUrls =
    {
        "http://www.msftconnecttest.com/connecttest.txt",
        "https://api.themoviedb.org/",
        "https://www.googleapis.com/generate_204",
    };

    private readonly HttpClient _probe = new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(5),
        AllowAutoRedirect = false,
        UseProxy = true,
    })
    {
        Timeout = TimeSpan.FromSeconds(8),
    };

    private readonly object _lock = new();
    private volatile bool _online;
    private Timer? _periodic;
    private Timer? _debounce;
    private int _checking;
    private bool _started;

    public Connectivity()
    {
        // Optimistic until the first check: a network adapter is up.
        _online = SafeNetworkAvailable();
    }

    public bool IsOnline => _online;

    /// <summary>Metered connection (mobile hotspot, metered Wi-Fi). Uses <see cref="MeteredCheck"/>; false when not set.</summary>
    public bool IsMetered
    {
        get
        {
            try { return MeteredCheck?.Invoke() ?? false; }
            catch { return false; }
        }
    }

    /// <summary>Set by the app (WinRT ConnectionProfile cost). Core can't reach Windows.Networking.Connectivity.</summary>
    public Func<bool>? MeteredCheck { get; set; }

    /// <summary>
    /// Optional system check set by the app: true/false when Windows knows (NCSI), null to fall back to the HTTP probe.
    /// </summary>
    public Func<bool?>? SystemCheck { get; set; }

    /// <summary>Raised with the new value whenever online/offline changes (distinct values only).</summary>
    public event Action<bool>? OnlineChanged;

    public void Start()
    {
        lock (_lock)
        {
            if (_started) return;
            _started = true;
        }
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        _periodic = new Timer(_ => _ = Refresh(), null, TimeSpan.Zero, TimeSpan.FromMinutes(1));
    }

    private void OnNetworkChanged(object? sender, EventArgs e)
    {
        // Adapters flap while connecting; wait for things to settle.
        lock (_lock)
        {
            _debounce ??= new Timer(_ => _ = Refresh(), null, Timeout.Infinite, Timeout.Infinite);
            _debounce.Change(TimeSpan.FromSeconds(1.5), Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>Checks now and updates <see cref="IsOnline"/>. Returns the new value.</summary>
    public async Task<bool> Refresh()
    {
        if (Interlocked.Exchange(ref _checking, 1) == 1) return _online;
        try
        {
            var online = await Check().ConfigureAwait(false);
            Set(online);
            return online;
        }
        finally
        {
            Interlocked.Exchange(ref _checking, 0);
        }
    }

    /// <summary>For tests and the app: force a value (e.g. from a WinRT status event).</summary>
    public void Set(bool online)
    {
        if (_online == online) return;
        _online = online;
        try { OnlineChanged?.Invoke(online); }
        catch { /* a subscriber's failure must not break connectivity tracking */ }
    }

    private async Task<bool> Check()
    {
        if (!SafeNetworkAvailable()) return false;
        try
        {
            var system = SystemCheck?.Invoke();
            if (system != null) return system.Value;
        }
        catch { /* fall back to probing */ }
        foreach (var url in ProbeUrls)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                using var response = await _probe.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
                if (url.StartsWith("http://", StringComparison.Ordinal))
                {
                    // Plain HTTP can be answered by a captive portal: only Microsoft's exact text counts.
                    var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (response.IsSuccessStatusCode && body.Contains("Microsoft Connect Test", StringComparison.Ordinal)) return true;
                    continue;
                }
                return true; // any HTTPS answer means the internet is reachable
            }
            catch
            {
                // try the next host
            }
        }
        return false;
    }

    private static bool SafeNetworkAvailable()
    {
        try { return NetworkInterface.GetIsNetworkAvailable(); }
        catch { return true; }
    }

    public void Dispose()
    {
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _periodic?.Dispose();
        _debounce?.Dispose();
        _probe.Dispose();
    }
}
