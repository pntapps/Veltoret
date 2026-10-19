using System.Text.Json;

namespace Veltoret.Core.Settings;

/// <summary>Same settings as the Android app's AppSettings (DataStore), with the same defaults.</summary>
public sealed record AppSettings
{
    public bool OnboardingComplete { get; init; }
    /// <summary>Key the user typed in (TMDB v3 API key or v4 read access token).</summary>
    public string TmdbKeyOverride { get; init; } = "";
    public bool OledBlack { get; init; }
    public bool AutoPlayNext { get; init; } = true;
    public int SkipSeconds { get; init; } = 85;
    public int SeekSeconds { get; init; } = 10;
    public string PreferredAudioLanguage { get; init; } = "en";
    /// <summary>Empty = subtitles off by default.</summary>
    public string PreferredSubtitleLanguage { get; init; } = "";
    public float SubtitleScale { get; init; } = 1f;
    public bool SubtitleBackground { get; init; }
    public long LastScanAt { get; init; }
    /// <summary>Notify on the day a show on the Watchlist airs a new episode.</summary>
    public bool NewEpisodeAlerts { get; init; } = true;
    /// <summary>Windows: keep running in the notification area so reminders fire when the window is closed.</summary>
    public bool RunInBackground { get; init; } = true;
    /// <summary>Windows: start with Windows (minimized to the notification area).</summary>
    public bool StartWithWindows { get; init; }
    /// <summary>Episodes TMDB alerted about already ("showId:season:episode").</summary>
    public IReadOnlyList<string> AlertedEpisodes { get; init; } = Array.Empty<string>();

    /// <summary>The key to use: the user's, else one bundled at build time (never in public builds).</summary>
    public string TmdbKey => string.IsNullOrWhiteSpace(TmdbKeyOverride) ? BundledKeys.Tmdb : TmdbKeyOverride.Trim();
}

/// <summary>
/// A developer's TMDB key from the VELTORET_TMDB_KEY environment variable (the Android app's local.properties
/// key). Never commit a key: public builds have none and users enter their own.
/// </summary>
public static class BundledKeys
{
    public static string Tmdb => Environment.GetEnvironmentVariable("VELTORET_TMDB_KEY")?.Trim() ?? "";
}

/// <summary>Settings saved as JSON in %LOCALAPPDATA%\Veltoret\settings.json.</summary>
public sealed class SettingsStore
{
    private readonly string _path;
    private readonly object _lock = new();
    private AppSettings _current;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public event Action<AppSettings>? Changed;

    public SettingsStore(string path)
    {
        _path = path;
        _current = Load();
    }

    public AppSettings Current
    {
        get { lock (_lock) return _current; }
    }

    /// <summary>Applies <paramref name="edit"/> and saves: <c>settings.Update(s => s with { AutoPlayNext = false })</c>.</summary>
    public void Update(Func<AppSettings, AppSettings> edit)
    {
        AppSettings next;
        lock (_lock)
        {
            next = edit(_current);
            _current = next;
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(next, Json));
            File.Move(tmp, _path, overwrite: true);
        }
        Changed?.Invoke(next);
    }

    private AppSettings Load()
    {
        try
        {
            if (File.Exists(_path)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path)) ?? new AppSettings();
        }
        catch (JsonException) { }
        return new AppSettings();
    }
}
