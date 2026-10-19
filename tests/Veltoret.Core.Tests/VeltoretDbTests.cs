using Veltoret.Core.Data;

namespace Veltoret.Core.Tests;

public class VeltoretDbTests
{
    private static MediaFileEntity File(string id, string account = "a@b.c", int? movieId = null, int height = 1080, long addedAt = 100) => new()
    {
        DriveId = id, AccountEmail = account, LibraryFolderId = 7, Name = id + ".mkv", ParentId = "p", RelativePath = "A/B",
        SizeBytes = 1234567890123, ModifiedTime = null, MimeType = "video/x-matroska", DurationMs = 5_400_000, Width = 1920,
        Height = height, Kind = MediaKind.MOVIE, ParsedTitle = "Title", ParsedYear = null, Season = null, Episode = 3,
        EpisodeEnd = null, MovieId = movieId, ShowId = null, MatchState = MatchState.MANUAL, AddedAt = addedAt,
    };

    [Fact]
    public async Task MediaFileRoundTripsEnumsAndNullableInts()
    {
        using var t = new TestDb();
        var original = File("x1", movieId: 603) with { ParsedYear = 1999, ModifiedTime = "2024-01-01T00:00:00.000Z" };
        await t.Files.Upsert(new[] { original, File("x2") });

        var back = await t.Files.File("x1");
        Assert.Equal(original, back);
        var other = await t.Files.File("x2");
        Assert.NotNull(other);
        Assert.Null(other!.MovieId);
        Assert.Null(other.ParsedYear);
        Assert.Equal(3, other.Episode);
        Assert.Equal(MatchState.MANUAL, other.MatchState);
        Assert.Equal(MediaKind.MOVIE, other.Kind);

        await t.Files.SetMatchState(new[] { "x1" }, MatchState.IGNORED);
        Assert.Equal(MatchState.IGNORED, (await t.Files.File("x1"))!.MatchState);
        Assert.Null((await t.Files.File("x1"))!.MovieId);
    }

    [Fact]
    public async Task MoviesAggregateCountsCopiesAndDeviceFiles()
    {
        using var t = new TestDb();
        await t.Catalog.UpsertMovie(new MovieEntity { TmdbId = 603, Title = "The Matrix", Year = 1999, Genres = "Action,Science Fiction", UpdatedAt = 1 });
        await t.Catalog.UpsertMovie(new MovieEntity { TmdbId = 604, Title = "Not in library", UpdatedAt = 1 });
        await t.Files.Upsert(new[]
        {
            File("m1", movieId: 603, height: 1080, addedAt: 300),
            File("m2", account: "device", movieId: 603, height: 2160, addedAt: 200),
        });

        var rows = await t.Catalog.Movies();
        var row = Assert.Single(rows);
        Assert.Equal(603, row.Movie.TmdbId);
        Assert.Equal("The Matrix", row.Movie.Title);
        Assert.Equal(1999, row.Movie.Year);
        Assert.Equal(new[] { "Action", "Science Fiction" }, row.Movie.GenreList);
        Assert.Equal(200, row.AddedAt);
        Assert.Equal(2160, row.MaxHeight);
        Assert.Equal(2, row.FileCount);
        Assert.Equal(1, row.DeviceFiles);

        // Device copies come first.
        Assert.Equal("m2", (await t.Files.ForMovie(603))[0].DriveId);

        await t.Catalog.Prune();
        Assert.Null(await t.Catalog.Movie(604));
        Assert.NotNull(await t.Catalog.Movie(603));
    }

    [Fact]
    public async Task ShowsAggregateCountsDistinctEpisodes()
    {
        using var t = new TestDb();
        await t.Catalog.UpsertShow(new ShowEntity { TmdbId = 1396, Name = "Breaking Bad", UpdatedAt = 1 });
        MediaFileEntity Ep(string id, string account, int s, int e) => File(id, account) with
        {
            Kind = MediaKind.EPISODE, ShowId = 1396, Season = s, Episode = e, MatchState = MatchState.MATCHED,
        };
        await t.Files.Upsert(new[] { Ep("e1", "a@b.c", 1, 1), Ep("e2", "device", 1, 1), Ep("e3", "a@b.c", 1, 2) });
        var row = Assert.Single(await t.Catalog.Shows());
        Assert.Equal(2, row.AvailableEpisodes);
        Assert.Equal(1, row.DeviceEpisodes);
    }

    [Fact]
    public async Task FolderInsertIgnoresDuplicates()
    {
        using var t = new TestDb();
        var f = new LibraryFolderEntity { AccountEmail = "device", DriveFolderId = @"D:\Movies", Name = "Movies", Type = LibraryType.MOVIES };
        var id = await t.Accounts.InsertFolder(f);
        Assert.True(id > 0);
        Assert.Equal(-1, await t.Accounts.InsertFolder(f));
        var folder = Assert.Single(await t.Accounts.Folders());
        Assert.Equal(LibraryType.MOVIES, folder.Type);
    }
}
