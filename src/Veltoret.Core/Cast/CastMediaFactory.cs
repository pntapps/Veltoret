using System.Globalization;
using Veltoret.Core.Data;
using Veltoret.Core.Tmdb;

namespace Veltoret.Core.Cast;

/// <summary>
/// Builds <see cref="CastMedia"/> for a file from the library: title and artwork from TMDB data, sidecar subtitles
/// converted to WebVTT, and the MKV audio tracks to choose from. Used when the player doesn't describe what it
/// plays itself, and for the next episode.
/// </summary>
public sealed class CastMediaFactory(
    MediaFileDao files,
    CatalogDao catalog,
    Func<string, string, CancellationToken, Task<Stream>> openRead,
    Func<string> preferredSubtitleLanguage,
    Func<string> preferredAudioLanguage)
{
    public async Task<CastMedia> ForFile(MediaFileEntity file, CancellationToken ct = default)
    {
        var media = await Describe(file);
        var subtitles = await Subtitles(file.AccountEmail, file.ParentId, file.Name, ct);
        var preferred = preferredSubtitleLanguage();
        var active = preferred.Length == 0 ? null
            : subtitles.FirstOrDefault(s => string.Equals(s.Language, preferred, StringComparison.OrdinalIgnoreCase)
                                            || string.Equals(LanguageNames.ToTwoLetter(s.Language), preferred, StringComparison.OrdinalIgnoreCase))?.Id;
        var (options, selected, codec, audioLanguage) = await Audio(file.AccountEmail, file.DriveId, file.Name, ct);
        return media with
        {
            Subtitles = subtitles,
            ActiveSubtitle = active,
            AudioOptions = options,
            AudioTrack = selected,
            AudioWarning = CastFormats.AudioWarning(codec, file.Name),
            AudioLanguage = LanguageNames.ToTwoLetter(audioLanguage),
            SubtitleLanguage = active == null ? Veltoret.Core.TvLink.LinkPlay.SubtitlesOff : subtitles.First(s => s.Id == active).Language,
        };
    }

    /// <summary>A file that isn't in the library (Files screen).</summary>
    public async Task<CastMedia> ForItem(string account, string fileId, string name, CancellationToken ct = default)
    {
        var known = await files.File(fileId);
        if (known != null) return await ForFile(known, ct);
        var (options, selected, codec, audioLanguage) = await Audio(account, fileId, name, ct);
        return new CastMedia
        {
            FileId = fileId, Account = account, FileName = name, Title = Path.GetFileNameWithoutExtension(name),
            AudioOptions = options, AudioTrack = selected, AudioWarning = CastFormats.AudioWarning(codec, name),
            AudioLanguage = LanguageNames.ToTwoLetter(audioLanguage),
        };
    }

    /// <summary>Title, subtitle and artwork only (no file reads).</summary>
    public async Task<CastMedia> Describe(MediaFileEntity file)
    {
        var media = new CastMedia
        {
            FileId = file.DriveId, Account = file.AccountEmail, File = file, FileName = file.Name,
            Title = string.IsNullOrWhiteSpace(file.ParsedTitle) ? Path.GetFileNameWithoutExtension(file.Name) : file.ParsedTitle,
            SizeBytes = file.SizeBytes > 0 ? file.SizeBytes : null, DurationMs = file.DurationMs,
        };
        if (file.MovieId is { } movieId && await catalog.Movie(movieId) is { } movie)
        {
            return media with
            {
                Title = movie.Title,
                Subtitle = movie.Year?.ToString(CultureInfo.InvariantCulture),
                PosterUrl = TmdbImages.Poster(movie.PosterPath, "w500"),
                BackdropUrl = TmdbImages.Backdrop(movie.BackdropPath, "w780"),
            };
        }
        if (file.ShowId is { } showId && await catalog.Show(showId) is { } show)
        {
            EpisodeEntity? ep = file is { Season: { } s, Episode: { } e } ? await catalog.Episode(showId, s, e) : null;
            string? subtitle = null;
            if (file is { Season: { } season, Episode: { } episode })
            {
                subtitle = $"S{season:00}E{episode:00}";
                if (!string.IsNullOrWhiteSpace(ep?.Name)) subtitle += " · " + ep!.Name;
            }
            return media with
            {
                Title = show.Name,
                Subtitle = subtitle,
                IsEpisode = true,
                PosterUrl = TmdbImages.Poster(show.PosterPath, "w500"),
                BackdropUrl = TmdbImages.Still(ep?.StillPath, "w780") ?? TmdbImages.Backdrop(show.BackdropPath, "w780"),
            };
        }
        return media with { IsEpisode = file.Kind == MediaKind.EPISODE };
    }

    /// <summary>The episode after <paramref name="file"/>'s (best copy: this PC first, then highest resolution).</summary>
    public async Task<MediaFileEntity?> NextEpisode(MediaFileEntity? file)
    {
        if (file is not { ShowId: { } showId, Season: { } season, Episode: { } episode }) return null;
        var last = file.EpisodeEnd ?? episode;
        var all = await files.ForShow(showId);
        return all
            .Where(f => f.Season != null && f.Episode != null && f.DriveId != file.DriveId)
            .Where(f => season == 0
                ? f.Season == 0 && f.Episode > last
                : (f.Season == season && f.Episode > last) || (f.Season > season && f.Season != 0))
            .OrderBy(f => f.Season)
            .ThenBy(f => f.Episode)
            .ThenByDescending(f => Storage.Accounts.IsLocal(f.AccountEmail))
            .ThenByDescending(f => f.Height)
            .FirstOrDefault();
    }

    /// <summary>Sidecar subtitles next to the video ("Movie.en.srt" for "Movie.mkv"), converted to WebVTT.</summary>
    public async Task<List<CastSubtitle>> Subtitles(string account, string parentId, string videoName, CancellationToken ct, long offsetUs = 0)
    {
        var result = new List<CastSubtitle>();
        if (string.IsNullOrEmpty(parentId)) return result;
        List<SubtitleFileEntity> subs;
        try { subs = await files.SubtitlesIn(parentId); }
        catch (Exception) { return result; }
        var stem = Path.GetFileNameWithoutExtension(videoName);
        foreach (var sub in subs.Where(s => s.AccountEmail == account && Path.GetFileName(s.Name).StartsWith(stem, StringComparison.OrdinalIgnoreCase)))
        {
            try
            {
                await using var stream = await openRead(account, sub.DriveId, ct);
                using var ms = new MemoryStream();
                await stream.CopyToAsync(ms, ct);
                var cues = CastSubtitles.Parse(CastSubtitles.Decode(ms.ToArray()), sub.Name);
                if (cues.Count == 0) continue;
                var language = CastSubtitles.LanguageFromName(sub.Name);
                var label = language != null ? LanguageNames.Name(language) : Path.GetFileNameWithoutExtension(sub.Name);
                result.Add(new CastSubtitle(sub.DriveId, label, LanguageNames.ToTwoLetter(language), CastSubtitles.ToVtt(cues, offsetUs)));
            }
            catch (Exception e) when (e is not OperationCanceledException) { }
        }
        return result;
    }

    /// <summary>The MKV audio tracks (2+), the one matching the preferred language (else the first), and its codec.</summary>
    public async Task<(List<CastAudioOption> Options, long? Selected, string? Codec, string? Language)> Audio(string account, string fileId, string name, CancellationToken ct)
    {
        var options = new List<CastAudioOption>();
        if (CastFormats.MimeFor(name) != "video/x-matroska" || name.EndsWith(".avi", StringComparison.OrdinalIgnoreCase)) return (options, null, null, null);
        List<CastAudio.Track> tracks;
        try
        {
            await using var stream = await openRead(account, fileId, ct);
            if (!stream.CanSeek) return (options, null, null, null);
            tracks = await Task.Run(() => CastAudio.AudioTracks(CastAudio.StreamReader(stream)), ct);
        }
        catch (Exception e) when (e is not OperationCanceledException) { return (options, null, null, null); }
        if (tracks.Count == 0) return (options, null, null, null);
        var single = tracks.Count < 2;
        for (var i = 0; i < tracks.Count; i++)
        {
            var t = tracks[i];
            var codec = CodecName(t.CodecId);
            var language = t.Language is { Length: > 0 } l && l != "und" ? LanguageNames.Name(l) : null;
            var label = !string.IsNullOrWhiteSpace(t.Name) && language != null && !t.Name!.Contains(language, StringComparison.OrdinalIgnoreCase)
                ? $"{language} · {t.Name}" : t.Name is { Length: > 0 } n ? n : language ?? $"Track {i + 1}";
            options.Add(new CastAudioOption(t.Number, label, codec ?? "", codec));
        }
        var preferred = preferredAudioLanguage();
        var chosen = options.FirstOrDefault(o => string.Equals(LanguageNames.ToTwoLetter(LanguageOf(o)), preferred, StringComparison.OrdinalIgnoreCase)) ?? options[0];
        // With one audio track there's nothing to choose and nothing to hide.
        var chosenLanguage = LanguageOf(chosen);
        return single ? (new List<CastAudioOption>(), null, chosen.Codec, chosenLanguage) : (options, chosen.Track, chosen.Codec, chosenLanguage);

        string? LanguageOf(CastAudioOption o) => tracks.FirstOrDefault(t => t.Number == o.Track)?.Language;
    }

    public static string? CodecName(string? codecId) => codecId?.ToUpperInvariant() switch
    {
        null => null,
        var c when c.StartsWith("A_DTS") => "DTS",
        "A_TRUEHD" or "A_MLP" => "TrueHD",
        "A_AC3" => "AC3",
        "A_EAC3" => "E-AC3",
        var c when c.StartsWith("A_AAC") => "AAC",
        "A_OPUS" => "Opus",
        "A_FLAC" => "FLAC",
        "A_VORBIS" => "Vorbis",
        "A_MPEG/L3" => "MP3",
        "A_MPEG/L2" => "MP2",
        var c when c.StartsWith("A_PCM") => "PCM",
        var c => c.StartsWith("A_") ? c[2..] : c,
    };
}

/// <summary>Language codes ("en", "eng", "pt-BR") to English names, and to two-letter codes.</summary>
public static class LanguageNames
{
    private static readonly Lazy<Dictionary<string, CultureInfo>> ByThreeLetter = new(() =>
    {
        var map = new Dictionary<string, CultureInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in CultureInfo.GetCultures(CultureTypes.NeutralCultures))
        {
            if (c.ThreeLetterISOLanguageName.Length == 3) map.TryAdd(c.ThreeLetterISOLanguageName, c);
            // Matroska uses ISO 639-2/B ("fre", "ger"); Windows knows the /T codes.
        }
        foreach (var (b, t) in new[] { ("fre", "fra"), ("ger", "deu"), ("dut", "nld"), ("chi", "zho"), ("cze", "ces"), ("gre", "ell"), ("per", "fas"), ("rum", "ron"), ("slo", "slk"), ("ice", "isl"), ("alb", "sqi"), ("arm", "hye"), ("baq", "eus"), ("bur", "mya"), ("geo", "kat"), ("mac", "mkd"), ("mao", "mri"), ("may", "msa"), ("tib", "bod"), ("wel", "cym") })
            if (map.TryGetValue(t, out var c)) map.TryAdd(b, c);
        return map;
    });

    private static CultureInfo? Culture(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        if (code.Length == 3 && ByThreeLetter.Value.TryGetValue(code, out var c3)) return c3;
        try
        {
            var c = CultureInfo.GetCultureInfo(code);
            return c.ThreeLetterISOLanguageName == "ivl" ? null : c;
        }
        catch (CultureNotFoundException) { return null; }
    }

    public static string Name(string code)
    {
        var c = Culture(code);
        return c == null ? code : c.EnglishName;
    }

    public static string? ToTwoLetter(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        var c = Culture(code);
        return c?.TwoLetterISOLanguageName ?? code;
    }
}
