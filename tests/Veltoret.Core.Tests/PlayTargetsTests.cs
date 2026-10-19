using Veltoret.Core.Data;
using Veltoret.Core.Library;

namespace Veltoret.Core.Tests;

/// <summary>Port of Android PlayTargetsTest.kt.</summary>
public class PlayTargetsTests
{
    private const int Show = 42;

    private static MediaFileEntity File(int season, int episode) => new()
    {
        DriveId = $"f{season}-{episode}", AccountEmail = "a@b.c", LibraryFolderId = 1, Name = $"S{season}E{episode}.mkv",
        ParentId = "p", RelativePath = "", SizeBytes = 1, ModifiedTime = null, MimeType = "video/x-matroska",
        DurationMs = 0, Width = 0, Height = 0, Kind = MediaKind.EPISODE, ParsedTitle = "Show", ParsedYear = null,
        Season = season, Episode = episode, EpisodeEnd = null, MovieId = null, ShowId = Show,
        MatchState = MatchState.MATCHED, AddedAt = 0,
    };

    private static WatchStateEntity State(int season, int episode, bool watched, long at, long position = 0) => new()
    {
        Key = WatchKeys.Episode(Show, season, episode), PositionMs = position, DurationMs = 3_000_000, Watched = watched,
        LastWatchedAt = at, LastFileId = null, MovieId = null, ShowId = Show, Season = season, Episode = episode,
    };

    private static readonly MediaFileEntity[] Files = { File(1, 1), File(1, 2), File(1, 3), File(2, 1), File(0, 1) };

    [Fact]
    public void FreshShowStartsAtS1E1()
    {
        var t = PlayTargets.NextEpisode(Files, Array.Empty<WatchStateEntity>())!;
        Assert.Equal((1, 1), (t.File.Season, t.File.Episode));
        Assert.True(t.Fresh);
    }

    [Fact]
    public void ContinuesAfterLastWatched()
    {
        var t = PlayTargets.NextEpisode(Files, new[] { State(1, 1, true, 10), State(1, 2, true, 20) })!;
        Assert.Equal((1, 3), (t.File.Season, t.File.Episode));
    }

    [Fact]
    public void CrossesSeasonBoundaryAndSkipsSpecials()
    {
        var t = PlayTargets.NextEpisode(Files, new[] { State(1, 3, true, 30) })!;
        Assert.Equal((2, 1), (t.File.Season, t.File.Episode));
    }

    [Fact]
    public void ResumesNewerInProgressEpisode()
    {
        var t = PlayTargets.NextEpisode(Files, new[] { State(1, 1, true, 10), State(1, 2, false, 20, position: 600_000) })!;
        Assert.Equal((1, 2), (t.File.Season, t.File.Episode));
        Assert.True(t.Resuming);
    }

    [Fact]
    public void AllCaughtUp() => Assert.Null(PlayTargets.NextEpisode(Files, new[] { State(2, 1, true, 99) }));
}
