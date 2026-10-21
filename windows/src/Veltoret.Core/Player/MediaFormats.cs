using System.Collections.Concurrent;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Veltoret.Core.Player;

/// <summary>
/// Human-readable names for languages, codecs, channels and resolutions, used by the track lists and the info panel
/// (Android: player/MediaFormats.kt and PlayerViewModel.languageName). Codecs arrive as libVLC FourCCs.
/// </summary>
public static class MediaFormats
{
    // ---- Languages ------------------------------------------------------------------------------

    /// <summary>ISO 639-2/B (bibliographic) codes that differ from the terminology codes .NET knows.</summary>
    private static readonly Dictionary<string, string> Bibliographic = new(StringComparer.Ordinal)
    {
        ["fre"] = "fr", ["ger"] = "de", ["chi"] = "zh", ["cze"] = "cs", ["dut"] = "nl", ["gre"] = "el",
        ["per"] = "fa", ["rum"] = "ro", ["slo"] = "sk", ["alb"] = "sq", ["arm"] = "hy", ["baq"] = "eu",
        ["bur"] = "my", ["geo"] = "ka", ["ice"] = "is", ["mac"] = "mk", ["mao"] = "mi", ["may"] = "ms",
        ["tib"] = "bo", ["wel"] = "cy",
    };

    private static readonly Lazy<Dictionary<string, CultureInfo>> ThreeLetter = new(() =>
    {
        var map = new Dictionary<string, CultureInfo>(StringComparer.Ordinal);
        foreach (var c in CultureInfo.GetCultures(CultureTypes.NeutralCultures))
        {
            if (string.IsNullOrEmpty(c.Name)) continue;
            var three = c.ThreeLetterISOLanguageName.ToLowerInvariant();
            if (three.Length == 3) map.TryAdd(three, c);
        }
        return map;
    });

    private static readonly ConcurrentDictionary<string, CultureInfo?> CultureCache = new(StringComparer.Ordinal);

    /// <summary>The neutral culture for a language code ("en", "eng", "fre", "pt-BR"), or null when unknown.</summary>
    private static CultureInfo? NeutralCulture(string code) => CultureCache.GetOrAdd(code.Trim().ToLowerInvariant(), c =>
    {
        var primary = c.Split('-', '_')[0];
        if (primary.Length == 0) return null;
        if (Bibliographic.TryGetValue(primary, out var two)) primary = two;
        CultureInfo? culture = null;
        if (primary.Length == 3 && ThreeLetter.Value.TryGetValue(primary, out var byThree)) culture = byThree;
        if (culture == null)
        {
            try { culture = CultureInfo.GetCultureInfo(primary, predefinedOnly: true); }
            catch (CultureNotFoundException) { return null; }
        }
        while (!culture.IsNeutralCulture && !string.IsNullOrEmpty(culture.Parent.Name)) culture = culture.Parent;
        return string.IsNullOrEmpty(culture.Name) ? null : culture;
    });

    /// <summary>
    /// A language code made comparable: "eng" / "en-US" / "EN" → "en". "und", null or blank → null. Unknown codes
    /// are lowercased as they are. Persisted and compared languages always go through this.
    /// </summary>
    public static string? NormalizeLanguage(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        var trimmed = code.Trim().ToLowerInvariant();
        if (trimmed == "und") return null;
        var culture = NeutralCulture(trimmed);
        return culture?.TwoLetterISOLanguageName is { Length: > 0 } two && two != "iv" ? two : trimmed.Split('-', '_')[0];
    }

    /// <summary>"en" → "English"; unknown codes uppercased ("XX"); null/blank/"und" → null.</summary>
    public static string? LanguageName(string? code)
    {
        if (string.IsNullOrWhiteSpace(code) || code == "und") return null;
        var name = NeutralCulture(code)?.EnglishName;
        return !string.IsNullOrWhiteSpace(name) && name != code && !name.StartsWith("Unknown", StringComparison.Ordinal)
            ? name
            : code.ToUpperInvariant();
    }

    // ---- Labels -----------------------------------------------------------------------------------

    // Release sites rotate domains (.at, .town, .army, .zone…), so any "name.tld" with a lowercase ending
    // counts, not a fixed list. Real labels capitalise ("Dub.Intl", "DTS-HD.MA") and codecs are short ("H.264").
    private static readonly Regex JunkLabel = new(@"(?i:www\.|https?://|@)|\b[A-Za-z0-9-]{3,}\.[a-z]{2,10}\b",
        RegexOptions.CultureInvariant);

    /// <summary>A track's own label, unless it's a release group's web address or similar noise.</summary>
    public static string? CleanLabel(string? label)
    {
        var t = label?.Trim();
        return string.IsNullOrEmpty(t) || JunkLabel.IsMatch(t) ? null : t;
    }

    /// <summary>
    /// Display names for a list of tracks: language first ("English"), the track's own label only if it's
    /// meaningful, and a number when several tracks would otherwise look identical ("Hindi 2").
    /// </summary>
    public static List<string> TrackTitles(IReadOnlyList<(string? Language, string? Label)> tracks, string fallback,
        Func<string?, string?>? language = null)
    {
        language ??= LanguageName;
        var names = tracks.Select((t, i) => language(t.Language) ?? CleanLabel(t.Label) ?? $"{fallback} {i + 1}").ToList();
        var totals = names.GroupBy(n => n).ToDictionary(g => g.Key, g => g.Count());
        var seen = new Dictionary<string, int>();
        return names.Select(name =>
        {
            if (totals[name] <= 1) return name;
            var n = seen.GetValueOrDefault(name) + 1;
            seen[name] = n;
            return $"{name} {n}";
        }).ToList();
    }

    // ---- Codecs (libVLC FourCCs) ---------------------------------------------------------------

    /// <summary>libVLC's codec value (VLC_FOURCC: first character in the lowest byte) as its four characters.</summary>
    public static string FourCC(uint codec)
    {
        if (codec == 0) return "";
        Span<char> c = stackalloc char[4];
        for (var i = 0; i < 4; i++) c[i] = (char)((codec >> (8 * i)) & 0xFF);
        return new string(c);
    }

    public static string? AudioCodec(string? fourcc) => fourcc?.Trim() switch
    {
        null or "" => null,
        "mp4a" or "aac" => "AAC",
        "a52" or "ac-3" or "ac3" => "Dolby Digital",
        "eac3" => "Dolby Digital+",
        "ac-4" or "ac4" => "Dolby AC-4",
        "mlp" or "trhd" => "Dolby TrueHD",
        "dts" => "DTS",
        "dtsh" => "DTS-HD",
        "dtse" => "DTS Express",
        "opus" or "Opus" => "Opus",
        "flac" => "FLAC",
        "vorb" => "Vorbis",
        "mpga" or "mp3" or "mp2a" or "mpg3" => "MP3",
        "alac" => "ALAC",
        "araw" or "lpcm" or "u8" or "s8" or "s16l" or "s16b" or "s24l" or "s24b" or "s32l" or "s32b" or "f32l" or "f32b"
            or "fl32" or "f64l" or "fl64" or "pcm" => "PCM",
        var other => other.ToUpperInvariant(),
    };

    public static string? VideoCodec(string? fourcc) => fourcc?.Trim() switch
    {
        null or "" => null,
        "h264" or "H264" or "avc1" or "x264" => "H.264",
        "hevc" or "hvc1" or "hev1" or "h265" => "HEVC",
        "dvh1" or "dvhe" or "dva1" or "dvav" => "Dolby Vision",
        "VP80" or "vp80" or "VP8" => "VP8",
        "VP90" or "vp90" or "VP9" => "VP9",
        "av01" or "AV01" => "AV1",
        "mp4v" or "DIVX" or "XVID" or "FMP4" => "MPEG-4 Part 2",
        "mp2v" or "mpgv" => "MPEG-2",
        "WVC1" or "VC-1" or "vc1" => "VC-1",
        "h263" or "H263" => "H.263",
        var other => other.ToUpperInvariant(),
    };

    /// <summary>Subtitle format name, or null when unknown.</summary>
    public static string? SubtitleFormat(string? fourcc) => fourcc?.Trim() switch
    {
        "ssa" => "ASS",
        "subt" => "SRT",
        "wvtt" => "WebVTT",
        "ttml" => "TTML",
        "pgss" or "pgs" => "PGS",
        "spu" => "VobSub",
        "dvbs" => "DVB",
        "tx3g" => "Timed text",
        _ => null,
    };

    public static string? Channels(int count) => count switch
    {
        <= 0 => null,
        1 => "Mono",
        2 => "Stereo",
        6 => "5.1",
        8 => "7.1",
        _ => $"{count} ch",
    };

    /// <summary>"1920×1080 · 1080p"; null when unknown.</summary>
    public static string? Resolution(int width, int height)
    {
        if (width <= 0 || height <= 0) return null;
        var label = height >= 2000 || width >= 3800 ? "4K"
            : height >= 1400 ? "1440p"
            : height >= 1000 || width >= 1900 ? "1080p"
            : height >= 700 ? "720p"
            : "SD";
        return $"{width}×{height} · {label}";
    }

    public static string? Bitrate(long bps) => bps switch
    {
        <= 0 => null,
        >= 1_000_000 => string.Format(CultureInfo.InvariantCulture, "{0:0.0} Mbps", bps / 1_000_000f),
        _ => $"{bps / 1000} kbps",
    };

    /// <summary>Java's "%.3g fps": three significant digits ("24.0 fps", "120 fps").</summary>
    public static string? FrameRate(double fps)
    {
        if (fps <= 0 || double.IsNaN(fps) || double.IsInfinity(fps)) return null;
        var exponent = (int)Math.Floor(Math.Log10(fps));
        var rounded = Math.Round(fps / Math.Pow(10, exponent - 2), MidpointRounding.AwayFromZero) * Math.Pow(10, exponent - 2);
        exponent = (int)Math.Floor(Math.Log10(rounded));
        var decimals = Math.Max(0, 2 - exponent);
        return rounded.ToString("F" + decimals, CultureInfo.InvariantCulture) + " fps";
    }

    /// <summary>"48.0 kHz" (Kotlin prints a Double with at least one decimal).</summary>
    public static string? SampleRate(int hz) =>
        hz <= 0 ? null : (hz / 1000.0).ToString("0.0###", CultureInfo.InvariantCulture) + " kHz";
}
