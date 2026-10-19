using System.Text.RegularExpressions;
using Veltoret.Core.Data;
using Veltoret.Core.TvLink;

namespace Veltoret.Core.Cast;

/// <summary>An audio track the TV can play instead of the file's default one (<see cref="CastAudio"/>).</summary>
/// <param name="Track">The MKV TrackNumber.</param>
/// <param name="Codec">The codec name as the player knows it ("DTS", "E-AC3"…), for the DTS / TrueHD warning.</param>
public sealed record CastAudioOption(long Track, string Label, string Detail, string? Codec = null);

/// <summary>One subtitle for the Chromecast, already converted to WebVTT.</summary>
public sealed record CastSubtitle(string Id, string Label, string? Language, string Vtt);

/// <summary>What to cast: a library file (or a Files-screen file) with what the TV shows about it.</summary>
public sealed record CastMedia
{
    public string FileId { get; init; } = "";
    /// <summary>The source account: a Google email, "device" or "smb://host" (Storage.OpenRead).</summary>
    public string Account { get; init; } = "";
    public MediaFileEntity? File { get; init; }
    /// <summary>The file name (MIME type by extension); defaults to <see cref="MediaFileEntity.Name"/>.</summary>
    public string? FileName { get; init; }
    public string Title { get; init; } = "";
    public string? Subtitle { get; init; }
    public string? PosterUrl { get; init; }
    public string? BackdropUrl { get; init; }
    public bool IsEpisode { get; init; }
    public IReadOnlyList<CastSubtitle> Subtitles { get; init; } = Array.Empty<CastSubtitle>();
    public string? ActiveSubtitle { get; init; }
    /// <summary>Set when the audio is a format Chromecasts usually can't decode (DTS, TrueHD).</summary>
    public string? AudioWarning { get; init; }
    /// <summary>The MKV track number of the audio to play; the other audio tracks are hidden from the TV.</summary>
    public long? AudioTrack { get; init; }
    /// <summary>Audio tracks to choose from (MKV with several); empty when the TV gets the file as it is.</summary>
    public IReadOnlyList<CastAudioOption> AudioOptions { get; init; } = Array.Empty<CastAudioOption>();
    /// <summary>"Play on TV": the PC's audio language and subtitle choice (a language or LinkPlay.SubtitlesOff).</summary>
    public string? AudioLanguage { get; init; }
    public string? SubtitleLanguage { get; init; }
    /// <summary>File size when known (library files), else probed on first request.</summary>
    public long? SizeBytes { get; init; }
    public long DurationMs { get; init; }

    public string Name => FileName ?? File?.Name ?? Title;
}

public enum CastDeviceKind { Chromecast, Veltoret }

/// <summary>A TV in the device picker: a Chromecast or Veltoret on a TV ("Play on TV").</summary>
public sealed record CastDevice(string Id, string Name, CastDeviceKind Kind, string Host, int Port, string? Model = null, bool Paired = false)
{
    public string Detail => Kind == CastDeviceKind.Veltoret
        ? Paired ? "Veltoret · all audio tracks and subtitles" : "Veltoret · pair once with a code"
        : "Chromecast";

    public LinkTv AsLinkTv() => new(Id, Name, Host, Port, Paired);
}

public sealed record CastState
{
    public bool Available { get; init; } = true;
    /// <summary>Connecting to a Chromecast (TLS + launching the receiver).</summary>
    public bool Connecting { get; init; }
    public bool Connected { get; init; }
    public string? DeviceName { get; init; }
    public CastMedia? Media { get; init; }
    public bool Playing { get; init; }
    public bool Buffering { get; init; }
    public long PositionMs { get; init; }
    public long DurationMs { get; init; }
    /// <summary>The video played to the end on the TV.</summary>
    public bool Finished { get; init; }
    public string? Error { get; init; }
    public string? ActiveSubtitle { get; init; }
    /// <summary>Chromecast volume 0..1 (null when unknown or a Veltoret TV).</summary>
    public double? Volume { get; init; }
    public bool Muted { get; init; }
    /// <summary>Connected to Veltoret on a TV ("Play on TV") rather than a Chromecast.</summary>
    public LinkTv? Link { get; init; }
    /// <summary>"Play on TV": LinkStatus.SourceTv (its own copy) or SourcePhone (streaming from this PC).</summary>
    public string? LinkSource { get; init; }
    public IReadOnlyList<LinkTrack> LinkAudio { get; init; } = Array.Empty<LinkTrack>();
    public string? LinkAudioSelected { get; init; }
    public IReadOnlyList<LinkTrack> LinkSubtitles { get; init; } = Array.Empty<LinkTrack>();
    public string? LinkSubtitleSelected { get; init; }
    /// <summary>The show has an episode after the one on the TV.</summary>
    public bool HasNext { get; init; }
}

public static class CastFormats
{
    /// <summary>The MIME type Chromecasts expect for the file's container (by file name extension).</summary>
    public static string MimeFor(string name)
    {
        var dot = name.LastIndexOf('.');
        var ext = dot >= 0 ? name[(dot + 1)..].ToLowerInvariant() : "";
        return ext switch
        {
            "mp4" or "m4v" or "mov" => "video/mp4",
            "webm" => "video/webm",
            "ts" or "m2ts" => "video/mp2t",
            "avi" => "video/x-msvideo",
            _ => "video/x-matroska",
        };
    }

    private static readonly Regex TrueHdName = new(@"\bTRUEHD\b", RegexOptions.CultureInvariant);
    private static readonly Regex DtsName = new(@"\bDTS", RegexOptions.CultureInvariant);

    /// <summary>
    /// Chromecasts usually can't play DTS or TrueHD. Checks the selected audio's <paramref name="codec"/>, or the
    /// file name when the tracks aren't known yet (codec null).
    /// </summary>
    public static string? AudioWarning(string? codec, string? fileName)
    {
        string? kind;
        if (codec != null)
        {
            var c = codec.ToUpperInvariant();
            kind = c.Contains("DTS") ? "DTS"
                : c.Contains("TRUEHD") || c.Contains("TRUE HD") || c.Contains("MLP") || c.Contains("TRHD") ? "Dolby TrueHD"
                : null;
        }
        else
        {
            var name = (fileName ?? "").ToUpperInvariant();
            kind = TrueHdName.IsMatch(name) ? "Dolby TrueHD" : DtsName.IsMatch(name) ? "DTS" : null;
        }
        return kind == null ? null
            : $"This video's audio is {kind}, which most Chromecasts can't play, so there may be no sound. Another version of it may work.";
    }

    /// <summary>Java's String.hashCode() as an unsigned decimal (Android: <c>hashCode().toUInt()</c>).</summary>
    public static uint JavaHash(string s)
    {
        var h = 0;
        unchecked
        {
            foreach (var c in s) h = 31 * h + c;
        }
        return (uint)h;
    }
}
