using System.Text.Json;

namespace Veltoret.Core.Player;

/// <summary>
/// What the user picked for one video, restored the next time it opens. Tracks are identified by their position
/// among tracks of the same type plus their language, which stays stable for a given file.
/// </summary>
public sealed record TrackMemory
{
    public const string SubOff = "off";
    public const string SubEmbedded = "embedded";
    public const string SubExternal = "external";

    public int? AudioIndex { get; init; }
    public string? AudioLanguage { get; init; }
    /// <summary><see cref="SubOff"/>, <see cref="SubEmbedded"/> or <see cref="SubExternal"/>; null = never chosen.</summary>
    public string? SubtitleMode { get; init; }
    public int? SubtitleIndex { get; init; }
    public string? SubtitleLanguage { get; init; }
    /// <summary>External subtitles: "drive:&lt;id&gt;" (any library source), "file:&lt;path&gt;" or "side:&lt;id&gt;".</summary>
    public string? ExternalSource { get; init; }
    public string? ExternalName { get; init; }
    public long SubtitleOffsetMs { get; init; }

    private const char Sep = '\u001F'; // unit separator; never appears in names or paths

    /// <summary>Android's SharedPreferences format: 8 fields joined with U+001F, empty = null.</summary>
    public string Encode() => string.Join(Sep, new[]
    {
        AudioIndex?.ToString(), AudioLanguage, SubtitleMode, SubtitleIndex?.ToString(), SubtitleLanguage,
        ExternalSource, ExternalName?.Replace(Sep, ' '), SubtitleOffsetMs.ToString(),
    }.Select(s => s ?? ""));

    public static TrackMemory Decode(string raw)
    {
        var f = raw.Split(Sep);
        string? At(int i) => i < f.Length && f[i].Length > 0 ? f[i] : null;
        return new TrackMemory
        {
            AudioIndex = int.TryParse(At(0), out var a) ? a : null,
            AudioLanguage = At(1),
            SubtitleMode = At(2),
            SubtitleIndex = int.TryParse(At(3), out var s) ? s : null,
            SubtitleLanguage = At(4),
            ExternalSource = At(5),
            ExternalName = At(6),
            SubtitleOffsetMs = long.TryParse(At(7), out var o) ? o : 0,
        };
    }
}

/// <summary>
/// Small player memory (Android: PlayerPrefs, SharedPreferences "player"): per-video track choices
/// ("video:{fileId}"), per-show audio ("audio:{showId}") and subtitle ("sub:{showId}", "off") languages, and the
/// last aspect mode ("resize"). Stored as a JSON object of the same keys and string values.
/// </summary>
public class PlayerPrefsStore
{
    public const string Off = "off";

    private readonly string _path;
    private readonly object _lock = new();
    private readonly Dictionary<string, string> _values;

    public PlayerPrefsStore(string path)
    {
        _path = path;
        _values = Load(path);
    }

    private static Dictionary<string, string> Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        return new();
    }

    private string? Get(string key)
    {
        lock (_lock) return _values.GetValueOrDefault(key);
    }

    private void Put(string key, string value)
    {
        lock (_lock)
        {
            _values[key] = value;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var tmp = _path + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(_values));
                File.Move(tmp, _path, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    // ---- Per video ----------------------------------------------------------------------------

    public TrackMemory? TrackMemory(string videoKey) => Get("video:" + videoKey) is { } raw ? Player.TrackMemory.Decode(raw) : null;

    public void UpdateTrackMemory(string videoKey, Func<TrackMemory, TrackMemory> change)
    {
        var m = change(TrackMemory(videoKey) ?? new TrackMemory());
        Put("video:" + videoKey, m.Encode());
    }

    // ---- Per show -----------------------------------------------------------------------------

    public string? AudioLanguage(int? showId) => showId == null ? null : Get($"audio:{showId}");

    public void SetAudioLanguage(int? showId, string? language)
    {
        if (showId == null || string.IsNullOrWhiteSpace(language)) return;
        Put($"audio:{showId}", language);
    }

    /// <summary>null = no preference, <see cref="Off"/> = subtitles off, otherwise a language code.</summary>
    public string? SubtitleLanguage(int? showId) => showId == null ? null : Get($"sub:{showId}");

    public void SetSubtitleLanguage(int? showId, string? language)
    {
        if (showId == null) return;
        Put($"sub:{showId}", language ?? Off);
    }

    /// <summary>"Fit", "Fill" or "Stretch" (default Fit).</summary>
    public string ResizeMode
    {
        get => Get("resize") is "Fill" or "Stretch" ? Get("resize")! : "Fit";
        set => Put("resize", value);
    }
}
