using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Net;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;
using Veltoret.Core.Tmdb;
using StorageFacade = Veltoret.Core.Storage.Storage;

namespace Veltoret.Core.Tests;

/// <summary>An in-memory source: folder id → children.</summary>
public sealed class FakeSource(string account) : IFileSource
{
    public Dictionary<string, List<StorageItem>> Tree { get; } = new();
    public HashSet<string> Failing { get; } = new();

    public void Add(string parent, string name, bool folder = false, long size = 700L * 1024 * 1024)
    {
        if (!Tree.TryGetValue(parent, out var list)) Tree[parent] = list = new();
        var id = parent + "/" + name;
        list.Add(new StorageItem { Id = id, Name = name, IsFolder = folder, SizeBytes = folder ? 0 : size, MimeType = folder ? "folder" : "" });
        if (folder) Tree.TryAdd(id, new());
    }

    public bool Handles(string a) => a == account;
    public string RootId(string a) => "root";
    public string RootName(string a) => "Root";

    public Task<List<StorageItem>> List(string a, string folderId, CancellationToken ct = default)
    {
        if (Failing.Contains(folderId)) throw new IOException("Server went away");
        return Task.FromResult(Tree.TryGetValue(folderId, out var l) ? l.ToList() : new List<StorageItem>());
    }

    public Task<List<StorageItem>> Search(string a, string q, string c, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<string> Rename(string a, string id, string n, CancellationToken ct = default) => throw new NotSupportedException();
    public Task Remove(string a, string id, CancellationToken ct = default) => throw new NotSupportedException();
    public Task DeletePermanently(string a, string id, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<StorageSpace?> Space(string a, string f, CancellationToken ct = default) => Task.FromResult<StorageSpace?>(null);
    public string? SpaceKey(string a, string f) => null;
    public Task Move(string a, string id, string? from, string to, CancellationToken ct = default) => throw new NotSupportedException();
    public Task CreateFolder(string a, string p, string n, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<Stream> OpenRead(string a, string id, CancellationToken ct = default) => throw new NotSupportedException();
}

public sealed class LibraryScannerTests : IDisposable
{
    private readonly TestDb _t = new();
    private readonly FakeSource _drive = new("me@example.com");
    private readonly FakeSource _device = new(Accounts.Device);
    private readonly Connectivity _connectivity = new();
    private readonly SettingsStore _settings;
    private readonly LibraryScanner _scanner;
    private readonly FakeTmdbHandler _tmdb;

    public LibraryScannerTests()
    {
        _settings = new SettingsStore(Path.Combine(_t.Dir, "settings.json"));
        var storage = new StorageFacade();
        storage.Register(_drive);
        storage.Register(_device);
        _tmdb = new FakeTmdbHandler(Respond);
        var repo = new TmdbRepository(new TmdbClient(new HttpClient(_tmdb), () => "key"), _t.Catalog);
        _scanner = new LibraryScanner(_t.Accounts, _t.Files, _t.Catalog, storage, repo, _settings, _connectivity);
        _connectivity.Set(true);
    }

    public void Dispose() => _t.Dispose();

    private static string? Respond(Uri uri)
    {
        var path = uri.AbsolutePath;
        var query = Uri.UnescapeDataString(uri.Query);
        if (path.EndsWith("/search/movie"))
            return query.Contains("query=The Matrix")
                ? """{"results":[{"id":603,"title":"The Matrix","release_date":"1999-03-30","vote_count":20000}],"total_pages":1}"""
                : """{"results":[],"total_pages":1}""";
        if (path.EndsWith("/movie/603")) return """{"id":603,"title":"The Matrix","release_date":"1999-03-30","genres":[]}""";
        if (path.EndsWith("/search/tv"))
            return query.Contains("query=Dark")
                ? """{"results":[{"id":70523,"name":"Dark","first_air_date":"2017-12-01","vote_count":5000}],"total_pages":1}"""
                : """{"results":[],"total_pages":1}""";
        if (path.EndsWith("/tv/70523")) return """{"id":70523,"name":"Dark","first_air_date":"2017-12-01","seasons":[{"season_number":1,"episode_count":10}]}""";
        if (path.EndsWith("/tv/70523/season/1")) return """{"season_number":1,"episodes":[{"episode_number":1,"season_number":1,"name":"Secrets"}]}""";
        if (path.Contains("/recommendations")) return """{"results":[],"total_pages":1}""";
        return null;
    }

    private async Task<long> AddFolder(string account, string id, LibraryType type) =>
        await _t.Accounts.InsertFolder(new LibraryFolderEntity { AccountEmail = account, DriveFolderId = id, Name = id, Type = type });

    [Fact]
    public async Task ScansMatchesAndSkipsSamples()
    {
        _drive.Add("movies", "The.Matrix.1999.1080p.BluRay.x264.mkv");
        _drive.Add("movies", "The.Matrix.1999.sample.mkv", size: 20 * 1024 * 1024);
        _drive.Add("movies", "Unknown.Clip.Thing.2011.mkv");
        _drive.Add("movies", "The.Matrix.1999.srt");
        _drive.Add("movies", "Extras.zip");
        _drive.Add("shows", "Dark", folder: true);
        _drive.Add("shows/Dark", "Season 1", folder: true);
        _drive.Add("shows/Dark/Season 1", "Dark.S01E01.mkv");
        await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        await AddFolder("me@example.com", "shows", LibraryType.SHOWS);

        await _scanner.ScanAll();

        var s = _scanner.State;
        Assert.False(s.Running);
        Assert.Null(s.Error);
        Assert.Equal(3, s.FilesFound);
        Assert.Equal(3, s.NewFiles);
        Assert.Equal(2, s.Identified);
        Assert.True(_settings.Current.LastScanAt > 0);

        var matrix = (await _t.Files.File("movies/The.Matrix.1999.1080p.BluRay.x264.mkv"))!;
        Assert.Equal(MatchState.MATCHED, matrix.MatchState);
        Assert.Equal(603, matrix.MovieId);
        Assert.Null(await _t.Files.File("movies/The.Matrix.1999.sample.mkv"));
        Assert.Equal(MatchState.UNMATCHED, (await _t.Files.File("movies/Unknown.Clip.Thing.2011.mkv"))!.MatchState);
        var ep = (await _t.Files.File("shows/Dark/Season 1/Dark.S01E01.mkv"))!;
        Assert.Equal(70523, ep.ShowId);
        Assert.Equal("Dark/Season 1", ep.RelativePath);
        Assert.Single(await _t.Files.SubtitlesIn("movies"));
        Assert.Single(await _t.Files.Archives());
        Assert.NotNull(await _t.Catalog.Episode(70523, 1, 1));
        Assert.Single(await _t.Catalog.Movies());
    }

    [Fact]
    public async Task ManualMatchesSurviveRescansAndGoneFilesAreRemoved()
    {
        _drive.Add("movies", "Unknown.Clip.Thing.2011.mkv");
        _drive.Add("movies", "Other.Clip.2012.mkv");
        await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        await _scanner.ScanAll();
        await _scanner.ApplyManualMatch(new[] { "movies/Unknown.Clip.Thing.2011.mkv" }, MediaKind.MOVIE, 603);
        await _scanner.Ignore(new[] { "movies/Other.Clip.2012.mkv" });

        await _scanner.ScanAll();
        var manual = (await _t.Files.File("movies/Unknown.Clip.Thing.2011.mkv"))!;
        Assert.Equal(MatchState.MANUAL, manual.MatchState);
        Assert.Equal(603, manual.MovieId);
        Assert.Equal(MatchState.IGNORED, (await _t.Files.File("movies/Other.Clip.2012.mkv"))!.MatchState);

        _drive.Tree["movies"].RemoveAll(i => i.Name.StartsWith("Other"));
        await _scanner.ScanAll();
        Assert.Null(await _t.Files.File("movies/Other.Clip.2012.mkv"));
    }

    [Fact]
    public async Task FailedFolderKeepsItsFilesAndReportsTheError()
    {
        _drive.Add("movies", "The.Matrix.1999.mkv");
        var id = await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        await _scanner.ScanAll();

        _drive.Failing.Add("movies");
        await _scanner.ScanAll();
        Assert.NotNull(await _t.Files.File("movies/The.Matrix.1999.mkv"));
        Assert.Equal("Server went away", _scanner.State.FolderErrors[id]);
        Assert.Contains("Server went away", _scanner.State.Error);

        _drive.Failing.Clear();
        await _scanner.ScanAll();
        Assert.Empty(_scanner.State.FolderErrors);
    }

    [Fact]
    public async Task OfflineScansOnlyThisPcAndSkipsTmdb()
    {
        _drive.Add("movies", "The.Matrix.1999.mkv");
        _device.Add(@"D:\Movies", "The.Matrix.1999.2160p.mkv");
        await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        await AddFolder(Accounts.Device, @"D:\Movies", LibraryType.MOVIES);
        _connectivity.Set(false);

        await _scanner.ScanAll();
        Assert.Null(await _t.Files.File("movies/The.Matrix.1999.mkv"));
        Assert.Equal(MatchState.PENDING, (await _t.Files.File(@"D:\Movies/The.Matrix.1999.2160p.mkv"))!.MatchState);
        Assert.Empty(_tmdb.Requests);
    }

    [Fact]
    public async Task CancelStopsAtNextCheckpoint()
    {
        _drive.Add("movies", "The.Matrix.1999.mkv");
        await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        _scanner.StateChanged += s =>
        {
            if (s.Running && s.CurrentFolderId != null) _scanner.Cancel();
        };
        await _scanner.ScanAll();
        Assert.True(_scanner.State.Cancelled);
        Assert.False(_scanner.State.Running);
        Assert.Empty(_tmdb.Requests);
    }

    [Fact]
    public async Task RenameToANewIdKeepsTheMatch()
    {
        _drive.Add("movies", "The.Matrix.1999.mkv");
        await AddFolder("me@example.com", "movies", LibraryType.MOVIES);
        await _scanner.ScanAll();
        await _scanner.OnFileRenamed("movies/The.Matrix.1999.mkv", "movies/Matrix.mkv", "Matrix.mkv");
        Assert.Null(await _t.Files.File("movies/The.Matrix.1999.mkv"));
        Assert.Equal(603, (await _t.Files.File("movies/Matrix.mkv"))!.MovieId);
    }
}
