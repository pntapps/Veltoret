using System.Net;
using Veltoret.Core.Images;
using Veltoret.Core.Local;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Tests;

public sealed class LocalFileSourceTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "veltoret-tests", Guid.NewGuid().ToString("N"));
    private readonly LocalFileSource _src = new();

    public LocalFileSourceTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); }
        catch { }
    }

    [Fact]
    public async Task RootListsReadyDrives()
    {
        Assert.Equal(LocalFileSource.Root, _src.RootId(Accounts.Device));
        Assert.Equal("This PC", _src.RootName(Accounts.Device));
        var drives = await _src.List(Accounts.Device, LocalFileSource.Root);
        Assert.NotEmpty(drives);
        Assert.All(drives, d => Assert.True(d.IsFolder));
        Assert.Contains(drives, d => d.Id.EndsWith(":\\") && d.Name.Contains('('));
    }

    [Fact]
    public async Task ListsFoldersFirstWithMimeTypes()
    {
        File.WriteAllText(Path.Combine(_dir, "b.mkv"), "x");
        File.WriteAllText(Path.Combine(_dir, "a.srt"), "x");
        Directory.CreateDirectory(Path.Combine(_dir, "Season 1"));
        var items = await _src.List(Accounts.Device, _dir + "\\");
        Assert.Equal(new[] { "Season 1", "a.srt", "b.mkv" }, items.Select(i => i.Name));
        Assert.True(items[0].IsFolder);
        Assert.Equal("video/x-matroska", items[2].MimeType);
        Assert.Equal(1, items[2].SizeBytes);
        Assert.Equal(Path.Combine(_dir, "b.mkv"), items[2].Id);
        Assert.Equal(_dir, items[2].Parents[0]);
        Assert.Single(await _src.Search(Accounts.Device, "SEASON", _dir));
    }

    [Fact]
    public async Task MissingFolderExplains()
    {
        var e = await Assert.ThrowsAsync<DirectoryNotFoundException>(() => _src.List(Accounts.Device, Path.Combine(_dir, "nope")));
        Assert.StartsWith("This folder isn't available", e.Message);
    }

    [Fact]
    public async Task RenameMoveCreateAndRead()
    {
        var file = Path.Combine(_dir, "old.mkv");
        File.WriteAllText(file, "hello");
        var renamed = await _src.Rename(Accounts.Device, file, " new.mkv ");
        Assert.Equal(Path.Combine(_dir, "new.mkv"), renamed);
        Assert.True(File.Exists(renamed));

        await _src.CreateFolder(Accounts.Device, _dir, "Sub");
        await _src.Move(Accounts.Device, renamed, _dir, Path.Combine(_dir, "Sub"));
        var moved = Path.Combine(_dir, "Sub", "new.mkv");
        Assert.True(File.Exists(moved));

        await using var s = await _src.OpenRead(Accounts.Device, moved);
        Assert.True(s.CanSeek);
        Assert.Equal(5, s.Length);

        var space = await _src.Space(Accounts.Device, _dir);
        Assert.NotNull(space);
        Assert.True(space!.Total > 0);
        Assert.Equal(Path.GetPathRoot(_dir)!.ToUpperInvariant(), _src.SpaceKey(Accounts.Device, _dir));
        Assert.Null(_src.SpaceKey(Accounts.Device, LocalFileSource.Root));
    }

    [Fact]
    public void NormalizeKeepsDriveRootSeparator()
    {
        Assert.Equal(@"C:\", LocalFileSource.Normalize(@"C:\"));
        Assert.Equal(@"C:\", LocalFileSource.Normalize("C:"[..2] + "\\"));
        Assert.Equal(@"C:\Movies", LocalFileSource.Normalize(@"C:\Movies\"));
    }
}

public sealed class ImageCacheTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "veltoret-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); }
        catch { }
    }

    private sealed class CountingHandler : HttpMessageHandler
    {
        public int Calls;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Calls);
            await Task.Delay(50, ct);
            if (request.RequestUri!.AbsolutePath.Contains("missing")) return new HttpResponseMessage(HttpStatusCode.NotFound);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[] { 1, 2, 3 }) };
        }
    }

    [Fact]
    public async Task DownloadsOnceAndServesFromDisk()
    {
        var handler = new CountingHandler();
        var cache = new ImageCache(_dir, new HttpClient(handler));
        const string url = "https://image.tmdb.org/t/p/w342/abc.jpg";
        var results = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => cache.GetFile(url)));
        Assert.Equal(1, handler.Calls);
        Assert.All(results, p => Assert.Equal(cache.PathFor(url), p));
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(results[0]!));

        // Offline later: still served from disk.
        var again = new ImageCache(_dir, new HttpClient(new CountingHandler()));
        Assert.Equal(results[0], await again.GetFile(url));

        Assert.Null(await cache.GetFile("https://image.tmdb.org/t/p/w342/missing.jpg"));
        Assert.Null(await cache.GetFile(null));
        await cache.Prefetch(new[] { url, "https://image.tmdb.org/t/p/w500/abc.jpg" });
        Assert.Equal(3, handler.Calls);
    }
}
