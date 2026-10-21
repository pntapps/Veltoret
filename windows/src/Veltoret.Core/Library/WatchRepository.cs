using Veltoret.Core.Data;

namespace Veltoret.Core.Library;

public static class WatchKeys
{
    public static string Movie(int id) => $"movie:{id}";
    public static string Episode(int showId, int season, int episode) => $"ep:{showId}:{season}:{episode}";
    public static string File(string driveId) => $"file:{driveId}";

    public static string ForFile(MediaFileEntity file) =>
        file.MovieId is { } m ? Movie(m)
        : file is { ShowId: { } s, Season: { } se, Episode: { } e } ? Episode(s, se, e)
        : File(file.DriveId);
}

public sealed class WatchRepository(WatchDao dao)
{
    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public Task<List<WatchStateEntity>> All() => dao.All();
    public Task<List<WatchStateEntity>> ForShow(int showId) => dao.ForShow(showId);
    public Task<WatchStateEntity?> Get(string key) => dao.Get(key);

    /// <summary>Records playback progress; anything past 92% (or the last 2 minutes) counts as watched.</summary>
    public async Task SavePosition(MediaFileEntity? file, string fallbackFileId, long positionMs, long durationMs)
    {
        if (durationMs <= 0) return;
        var key = file != null ? WatchKeys.ForFile(file) : WatchKeys.File(fallbackFileId);
        var finished = positionMs >= durationMs * 0.92 || durationMs - positionMs < 120_000;
        var previous = await dao.Get(key);
        await dao.Upsert(new WatchStateEntity
        {
            Key = key,
            PositionMs = finished ? 0 : positionMs,
            DurationMs = durationMs,
            Watched = finished || (previous?.Watched == true && positionMs < 60_000),
            LastWatchedAt = Now,
            LastFileId = file?.DriveId ?? fallbackFileId,
            MovieId = file?.MovieId,
            ShowId = file?.ShowId,
            Season = file?.Season,
            Episode = file?.Episode,
        });
        // A multi-episode file (S01E01E02) also completes the episodes it spans.
        if (finished && file is { ShowId: { } showId, Season: { } season, Episode: { } episode, EpisodeEnd: { } end })
        {
            for (var ep = episode + 1; ep <= end; ep++) await SetEpisodeWatched(showId, season, ep, true);
        }
    }

    public async Task SetMovieWatched(int movieId, bool watched)
    {
        var key = WatchKeys.Movie(movieId);
        var prev = await dao.Get(key);
        await dao.Upsert(new WatchStateEntity
        {
            Key = key, PositionMs = 0, DurationMs = prev?.DurationMs ?? 0, Watched = watched,
            LastWatchedAt = watched ? Now : prev?.LastWatchedAt ?? 0,
            LastFileId = prev?.LastFileId, MovieId = movieId,
        });
    }

    public Task SetEpisodeWatched(int showId, int season, int episode, bool watched) =>
        SetEpisodesWatched(showId, new[] { (season, episode) }, watched);

    public async Task SetEpisodesWatched(int showId, IReadOnlyList<(int Season, int Episode)> episodes, bool watched)
    {
        var now = Now;
        var states = new List<WatchStateEntity>();
        for (var i = 0; i < episodes.Count; i++)
        {
            var (season, episode) = episodes[i];
            var key = WatchKeys.Episode(showId, season, episode);
            var prev = await dao.Get(key);
            states.Add(new WatchStateEntity
            {
                Key = key, PositionMs = 0, DurationMs = prev?.DurationMs ?? 0, Watched = watched,
                // Keep a stable order so "Next Up" continues after the last episode in the batch.
                LastWatchedAt = watched ? now + i : prev?.LastWatchedAt ?? 0,
                LastFileId = prev?.LastFileId, ShowId = showId, Season = season, Episode = episode,
            });
        }
        await dao.UpsertAll(states);
    }

    public async Task SetFileWatched(MediaFileEntity file, bool watched)
    {
        if (file.MovieId is { } m) await SetMovieWatched(m, watched);
        else if (file is { ShowId: { } s, Season: { } se, Episode: { } e }) await SetEpisodeWatched(s, se, e, watched);
        else
            await dao.Upsert(new WatchStateEntity
            {
                Key = WatchKeys.File(file.DriveId), PositionMs = 0, DurationMs = file.DurationMs, Watched = watched,
                LastWatchedAt = Now, LastFileId = file.DriveId,
            });
    }
}
