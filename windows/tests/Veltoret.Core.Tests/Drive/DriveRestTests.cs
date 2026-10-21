using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Veltoret.Core.Drive;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Tests.Drive;

public class DriveRestTests
{
    private static DriveRepository Repo(Func<HttpRequestMessage, HttpResponseMessage> answer) =>
        new(new HttpClient(new DriveAuthHandler(new FixedTokens(), new GoogleAuthTests.Answer(answer))));

    [Fact]
    public async Task ListFollowsPagesWithEscapedQuery()
    {
        var urls = new List<Uri>();
        var drive = Repo(r =>
        {
            urls.Add(r.RequestUri!);
            var second = r.RequestUri!.Query.Contains("pageToken=");
            var json = second
                ? """{"files":[{"id":"2","name":"b","mimeType":"video/x-matroska","size":"12345678901"}]}"""
                : """{"nextPageToken":"p2","files":[{"id":"1","name":"a","mimeType":"application/vnd.google-apps.folder"}]}""";
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        });
        var files = await drive.ListChildren("a@b.c", "it's\\id");
        Assert.Equal(2, files.Count);
        Assert.True(files[0].IsFolder);
        Assert.Equal(12345678901, files[1].SizeBytes);
        Assert.Equal(2, urls.Count);
        var q = Uri.UnescapeDataString(urls[0].Query);
        Assert.Contains("q='it\\'s\\\\id' in parents and trashed = false", q);
        Assert.Contains("orderBy=folder,name_natural", q);
        Assert.Contains("pageSize=1000", q);
        Assert.Contains("supportsAllDrives=true", q);
        Assert.Contains("includeItemsFromAllDrives=true", q);
        Assert.DoesNotContain("pageToken", q);
        Assert.Contains("pageToken=p2", Uri.UnescapeDataString(urls[1].Query));
    }

    [Fact]
    public async Task SearchReadsOnlyTheFirstPage()
    {
        var calls = 0;
        var drive = Repo(r =>
        {
            calls++;
            Assert.Contains("pageSize=200", r.RequestUri!.Query);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"nextPageToken":"more","files":[]}""") };
        });
        await drive.Search("a@b.c", "dune");
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task TrashAndMoveSendTheRightBodies()
    {
        var seen = new List<(string Method, string Url, string Body)>();
        var drive = Repo(r =>
        {
            seen.Add((r.Method.Method, Uri.UnescapeDataString(r.RequestUri!.ToString()), r.Content?.ReadAsStringAsync().Result ?? ""));
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"id":"x"}""") };
        });
        await drive.Trash("a@b.c", "x");
        await drive.Move("a@b.c", "x", "from", "to");
        await drive.Move("a@b.c", "x", null, "to");
        Assert.Equal(("PATCH", "{\"trashed\":true}"), (seen[0].Method, seen[0].Body));
        Assert.Equal("{}", seen[1].Body);
        Assert.Contains("addParents=to", seen[1].Url);
        Assert.Contains("removeParents=from", seen[1].Url);
        Assert.DoesNotContain("removeParents", seen[2].Url);
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden, "Only the owner of this file can delete it permanently")]
    [InlineData(HttpStatusCode.InternalServerError, "Delete failed (HTTP 500)")]
    public async Task DeleteErrors(HttpStatusCode code, string message)
    {
        var drive = Repo(_ => new HttpResponseMessage(code) { Content = new StringContent("") });
        var e = await Assert.ThrowsAsync<IOException>(() => drive.DeletePermanently("a@b.c", "x"));
        Assert.Equal(message, e.Message);
    }

    [Theory]
    [InlineData("""{"storageQuota":{"limit":"16106127360","usage":"4509715660"}}""", 16106127360L - 4509715660L)]
    [InlineData("""{"storageQuota":{"usage":"4509715660"}}""", null)]
    [InlineData("""{"storageQuota":{"limit":"100","usage":"200"}}""", 0L)]
    public async Task FreeBytes(string json, long? free)
    {
        var drive = Repo(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) });
        Assert.Equal(free, await drive.FreeBytes("a@b.c"));
    }

    [Fact]
    public void StorageSummaryText()
    {
        var space = DriveRepository.SpaceFrom(new StorageQuota { Limit = "16106127360", Usage = "4509715660" })!;
        Assert.Equal("Google storage · 4.2 GB used of 15.0 GB · 10.8 GB free", DriveFormat.StorageSummary(space));
        Assert.False(DriveFormat.StorageAlmostFull(space));
        Assert.True(DriveFormat.StorageAlmostFull(new StorageSpace("Google storage", 90, 100, 10)));
        Assert.False(DriveFormat.StorageAlmostFull(new StorageSpace("Google storage", 89, 100, 11)));
        Assert.Null(DriveFormat.StorageFraction(new StorageSpace("Google storage", 5, null, null)));
        Assert.Equal("Google storage · 0 B used", DriveFormat.StorageSummary(new StorageSpace("Google storage", 0, null, null)));
    }

    [Theory]
    [InlineData(0L, "—")]
    [InlineData(-5L, "—")]
    [InlineData(512L, "512 B")]
    [InlineData(1536L, "2 KB")]
    [InlineData(5L * 1024 * 1024, "5 MB")]
    [InlineData(1610612736L, "1.5 GB")]
    [InlineData(2199023255552L, "2.0 TB")]
    public void Bytes(long n, string text) => Assert.Equal(text, DriveFormat.Bytes(n));

    [Fact]
    public void Clock()
    {
        Assert.Equal("4:05", DriveFormat.Clock(245_000));
        Assert.Equal("1:02:09", DriveFormat.Clock(3_729_000));
    }

    /// <summary>A Drive file served by byte ranges, like alt=media.</summary>
    private sealed class RangeServer(byte[] data) : HttpMessageHandler
    {
        public int Opens;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Opens++;
            Assert.Contains("alt=media", request.RequestUri!.Query);
            Assert.NotNull(request.Headers.Authorization);
            var from = request.Headers.Range!.Ranges.Single().From!.Value;
            if (from >= data.Length) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.RequestedRangeNotSatisfiable));
            var content = new ByteArrayContent(data, (int)from, data.Length - (int)from);
            content.Headers.ContentRange = new ContentRangeHeaderValue(from, data.Length - 1, data.Length);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = content });
        }
    }

    [Fact]
    public async Task RangeStreamSeeksAndReadsTheRightBytes()
    {
        var data = new byte[10 * 1024 * 1024 + 123];
        new Random(11).NextBytes(data);
        var server = new RangeServer(data);
        var drive = new DriveRepository(new HttpClient(new DriveAuthHandler(new FixedTokens(), server)));
        await using var s = new DriveRangeStream(drive, "a@b.c", "id", data.Length);
        Assert.True(s.CanSeek);
        Assert.Equal(data.Length, s.Length);

        async Task Check(long at, int n)
        {
            s.Position = at;
            var buf = new byte[n];
            var total = 0;
            while (total < n)
            {
                var r = await s.ReadAsync(buf.AsMemory(total));
                if (r == 0) break;
                total += r;
            }
            Assert.Equal(Math.Min(n, data.Length - at), total);
            Assert.Equal(data.AsSpan((int)at, total).ToArray(), buf.AsSpan(0, total).ToArray());
        }

        await Check(0, 1000);
        await Check(1000, 600_000);         // sequential: same connection
        await Check(2_000_000, 1000);       // short forward seek: read through
        var opensBefore = server.Opens;
        await Check(9_000_000, 3000);       // far seek: new range
        Assert.Equal(opensBefore + 1, server.Opens);
        await Check(10, 10);                // backwards
        await Check(data.Length - 50, 500); // tail
        s.Position = data.Length;
        Assert.Equal(0, s.Read(new byte[10], 0, 10));
    }
}
