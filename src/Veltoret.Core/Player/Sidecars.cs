using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Player;

/// <summary>A subtitle file next to the video whose name starts with the video's ("Movie.en.srt").</summary>
public sealed record SidecarMatch<T>(T File, string Name, string? Language);

public static class Sidecars
{
    /// <summary>
    /// Subtitle files beside <paramref name="videoName"/>: names starting with the video's base name, with the
    /// language taken from the part after it when that is a 2–3 letter code ("Movie.en.srt" → "en";
    /// "Movie.forced.en.srt" → none).
    /// </summary>
    public static List<SidecarMatch<T>> Match<T>(string videoName, IEnumerable<T> files, Func<T, string> name)
    {
        var baseName = FilenameParser.BaseName(videoName).ToLowerInvariant();
        var result = new List<SidecarMatch<T>>();
        foreach (var f in files)
        {
            var n = name(f);
            if (!FilenameParser.IsSubtitle(n)) continue;
            if (!n.ToLowerInvariant().StartsWith(baseName, StringComparison.Ordinal)) continue;
            var subBase = FilenameParser.BaseName(n);
            var tail = subBase.Length >= baseName.Length ? subBase[baseName.Length..].Trim('.', ' ', '_', '-') : "";
            var dot = tail.IndexOf('.');
            var first = (dot < 0 ? tail : tail[..dot]).ToLowerInvariant();
            var lang = first.Length is >= 2 and <= 3 && first.All(char.IsLetter) ? first : null;
            result.Add(new SidecarMatch<T>(f, n, lang));
        }
        return result;
    }
}

/// <summary>Next / previous episode files (Android LibraryRepository.nextEpisodeFile / previousEpisodeFile).</summary>
public static class EpisodeNav
{
    private static bool IsAfter((int S, int E) a, (int S, int E) b) => a.S > b.S || (a.S == b.S && a.E > b.E);

    private static IEnumerable<MediaFileEntity> Candidates(IEnumerable<MediaFileEntity> showFiles, bool online) =>
        showFiles.Where(f => f.Season is > 0 && f.Episode != null && (online || Accounts.IsLocal(f.AccountEmail)));

    /// <summary>The episode file after <paramref name="file"/>, preferring the same account. Specials are skipped.</summary>
    public static MediaFileEntity? Next(MediaFileEntity file, IEnumerable<MediaFileEntity> showFiles, bool online)
    {
        if (file.ShowId == null || file.Season is not { } season) return null;
        if ((file.EpisodeEnd ?? file.Episode) is not { } last) return null;
        return Candidates(showFiles, online)
            .Where(f => IsAfter((f.Season!.Value, f.Episode!.Value), (season, last)))
            .OrderBy(f => f.Season).ThenBy(f => f.Episode)
            .ThenBy(f => f.AccountEmail == file.AccountEmail ? 0 : 1)
            .FirstOrDefault();
    }

    public static MediaFileEntity? Previous(MediaFileEntity file, IEnumerable<MediaFileEntity> showFiles, bool online)
    {
        if (file.ShowId == null || file.Season is not { } season || file.Episode is not { } episode) return null;
        return Candidates(showFiles, online)
            .Where(f => IsAfter((season, episode), (f.Season!.Value, f.EpisodeEnd ?? f.Episode!.Value)))
            .OrderByDescending(f => f.Season).ThenByDescending(f => f.Episode)
            .ThenBy(f => f.AccountEmail == file.AccountEmail ? 0 : 1)
            .FirstOrDefault();
    }

    /// <summary>In-player episode list: one file per (season, episode), specials last.</summary>
    public static List<MediaFileEntity> EpisodeList(IEnumerable<MediaFileEntity> showFiles)
    {
        var seen = new HashSet<(int, int)>();
        return showFiles.Where(f => f.Season != null && f.Episode != null)
            .Where(f => seen.Add((f.Season!.Value, f.Episode!.Value)))
            .OrderBy(f => f.Season == 0 ? int.MaxValue : f.Season!.Value)
            .ThenBy(f => f.Episode)
            .ToList();
    }
}
