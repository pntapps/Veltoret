using Veltoret.Core.Data;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Library;

public sealed record EpisodeTarget(
    MediaFileEntity File,
    WatchStateEntity? State,
    /* True when this continues a partly watched episode rather than starting a new one. */
    bool Resuming,
    /* True when nothing of the show has been watched yet. */
    bool Fresh);

public static class PlayTargets
{
    /// <summary>
    /// Picks what "Play" should start for a show: the most recent in-progress episode if it is newer
    /// than anything finished, otherwise the first unwatched episode after the last finished one.
    /// </summary>
    public static EpisodeTarget? NextEpisode(IReadOnlyList<MediaFileEntity> files, IReadOnlyList<WatchStateEntity> states)
    {
        var seen = new HashSet<(int, int)>();
        var playable = files
            .Where(f => f.Season != null && f.Episode != null)
            .OrderBy(f => f.Season == 0 ? int.MaxValue : f.Season!.Value)
            .ThenBy(f => f.Episode!.Value)
            .Where(f => seen.Add((f.Season!.Value, f.Episode!.Value)))
            .ToList();
        if (playable.Count == 0) return null;
        var byKey = new Dictionary<string, WatchStateEntity>();
        foreach (var s in states) byKey[s.Key] = s;
        WatchStateEntity? StateOf(MediaFileEntity f) => byKey.GetValueOrDefault(WatchKeys.ForFile(f));

        var lastWatched = states.Where(s => s.Watched && s.Season != null).MaxByOrDefault(s => s.LastWatchedAt);
        var inProgress = states.Where(s => !s.Watched && s.PositionMs > 30_000 && s.Season != null).MaxByOrDefault(s => s.LastWatchedAt);

        if (inProgress != null && (lastWatched == null || inProgress.LastWatchedAt > lastWatched.LastWatchedAt))
        {
            var current = playable.FirstOrDefault(f => f.Season == inProgress.Season && f.Episode == inProgress.Episode);
            if (current != null) return new EpisodeTarget(current, inProgress, Resuming: true, Fresh: false);
        }
        if (lastWatched != null)
        {
            var lastSeason = lastWatched.Season!.Value;
            var lastEpisode = lastWatched.Episode ?? 0;
            var next = playable.FirstOrDefault(f =>
            {
                var s = f.Season!.Value;
                var after = lastSeason == 0
                    ? s == 0 && f.Episode!.Value > lastEpisode
                    : (s > lastSeason && s != 0) || (s == lastSeason && f.Episode!.Value > lastEpisode);
                return after && StateOf(f)?.Watched != true;
            });
            return next == null ? null : new EpisodeTarget(next, StateOf(next), Resuming: false, Fresh: false);
        }
        var first = playable.FirstOrDefault(f => f.Season != 0) ?? playable[0];
        return new EpisodeTarget(first, StateOf(first), Resuming: false, Fresh: true);
    }

    /// <summary>Kotlin's maxByOrNull: the first element with the largest key, or null.</summary>
    private static T? MaxByOrDefault<T>(this IEnumerable<T> source, Func<T, long> key) where T : class
    {
        T? best = null;
        long bestKey = 0;
        foreach (var item in source)
        {
            var k = key(item);
            if (best == null || k > bestKey) { best = item; bestKey = k; }
        }
        return best;
    }
}

/// <summary>Resolves what a "Play" button should start.</summary>
public sealed class PlaybackResolver(MediaFileDao files, WatchDao watch, Func<bool> isOnline)
{
    /// <summary>Best version of a movie: a device copy first, then highest resolution and largest file.</summary>
    public async Task<MediaFileEntity?> MovieFile(int movieId) => Playable(await files.ForMovie(movieId)).FirstOrDefault();

    public async Task<EpisodeTarget?> ShowTarget(int showId) =>
        PlayTargets.NextEpisode(Playable(await files.ForShow(showId)), await watch.ForShow(showId));

    /// <summary>What "Play" on a show starts: the next episode, or episode 1 again once everything is watched.</summary>
    public async Task<EpisodeTarget?> ShowPlayTarget(int showId) =>
        await ShowTarget(showId) ?? PlayTargets.NextEpisode(Playable(await files.ForShow(showId)), Array.Empty<WatchStateEntity>());

    /// <summary>Best copy of one episode (device first, then highest resolution).</summary>
    public async Task<MediaFileEntity?> EpisodeFile(int showId, int season, int episode) =>
        Playable(await files.ForShow(showId))
            .Where(f => f.Season == season && f.Episode == episode)
            .OrderByDescending(f => Accounts.IsLocal(f.AccountEmail))
            .ThenByDescending(f => f.Height)
            .FirstOrDefault();

    /// <summary>Offline, only device copies can play.</summary>
    private List<MediaFileEntity> Playable(List<MediaFileEntity> list) =>
        isOnline() ? list : list.Where(f => Accounts.IsLocal(f.AccountEmail)).ToList();
}
