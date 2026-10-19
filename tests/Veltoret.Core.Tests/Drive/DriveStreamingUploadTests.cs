using System.IO.Compression;
using SharpCompress.Readers;
using SharpCompress.Readers.Zip;
using Veltoret.Core.Drive;

namespace Veltoret.Core.Tests.Drive;

/// <summary>
/// Port of the Android DriveStreamingUploadTest: the resumable-upload protocol against a fake Drive, including
/// streams whose length is unknown (videos piped straight out of a ZIP).
/// </summary>
public class DriveStreamingUploadTests
{
    private const int Chunk = 8 * 1024 * 1024;

    private static DriveRepository Repository(FakeUploadHandler fake) =>
        new(new HttpClient(new DriveAuthHandler(new FixedTokens(), fake)) { Timeout = Timeout.InfiniteTimeSpan });

    private static byte[] RandomBytes(int seed, int n)
    {
        var b = new byte[n];
        new Random(seed).NextBytes(b);
        return b;
    }

    [Fact]
    public async Task UnknownSizeStreamsInChunksAndDeclaresTotalAtTheEnd()
    {
        var fake = new FakeUploadHandler();
        var data = RandomBytes(1, Chunk * 2 + 12345);
        var file = await Repository(fake).Upload("a@b.c", "p", "v.mkv", "video/x-matroska", -1, () => new MemoryStream(data));
        Assert.Equal("f1", file.Id);
        Assert.Equal(new[] { $"bytes 0-{Chunk - 1}/*", $"bytes {Chunk}-{2 * Chunk - 1}/*", $"bytes {2 * Chunk}-{data.Length - 1}/{data.Length}" }, fake.Ranges);
        Assert.Equal(data, fake.Received.ToArray());
    }

    [Fact]
    public async Task UnknownSizeExactMultipleFinishesWithEmptyFinalChunk()
    {
        var fake = new FakeUploadHandler();
        var data = RandomBytes(2, Chunk);
        await Repository(fake).Upload("a@b.c", "p", "v.mkv", "video/x-matroska", -1, () => new MemoryStream(data));
        Assert.Equal(new[] { $"bytes 0-{Chunk - 1}/*", $"bytes */{Chunk}" }, fake.Ranges);
    }

    [Fact]
    public async Task KnownSizeStillWorks()
    {
        var fake = new FakeUploadHandler();
        var data = RandomBytes(3, Chunk + 10);
        await Repository(fake).Upload("a@b.c", "p", "v.mkv", "video/x-matroska", data.Length, () => new MemoryStream(data));
        Assert.Equal(new[] { $"bytes 0-{Chunk - 1}/{data.Length}", $"bytes {Chunk}-{data.Length - 1}/{data.Length}" }, fake.Ranges);
    }

    /// <summary>Same piping the extractor uses: entries inflate straight into uploads, never touching disk.</summary>
    [Fact]
    public async Task ZipEntriesStreamStraightIntoUploads()
    {
        var episodes = new[] { ("Season 1/S01E01.mkv", RandomBytes(4, Chunk + 500)), ("Season 1/S01E02.mkv", RandomBytes(5, 3000)) };
        var zipBytes = new MemoryStream();
        using (var zip = new ZipArchive(zipBytes, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, bytes) in episodes)
            {
                await using var s = zip.CreateEntry(name).Open();
                s.Write(bytes);
            }

        var uploaded = new List<byte[]>();
        using (var reader = ZipReader.OpenReader(new NonSeekable(new MemoryStream(zipBytes.ToArray())), new ReaderOptions()))
        {
            while (reader.MoveToNextEntry())
            {
                var fake = new FakeUploadHandler();
                var size = reader.Entry.Size > 0 ? reader.Entry.Size : -1;
                await using var entry = reader.OpenEntryStream();
                await Repository(fake).Upload("a@b.c", "p", reader.Entry.Key!, "video/x-matroska", size, () => new NonClosingStream(entry));
                uploaded.Add(fake.Received.ToArray());
            }
        }
        Assert.Equal(episodes.Length, uploaded.Count);
        for (var i = 0; i < episodes.Length; i++) Assert.Equal(episodes[i].Item2, uploaded[i]);
    }

    [Fact]
    public async Task FullDriveIsReportedAsSuch()
    {
        var fake = new FakeUploadHandler
        {
            Refuse = (403, """{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"storageQuotaExceeded"}]}}"""),
        };
        await Assert.ThrowsAsync<DriveStorageFullException>(() =>
            Repository(fake).Upload("a@b.c", "p", "v.mkv", "video/x-matroska", 10, () => new MemoryStream(new byte[10])));
    }

    [Fact]
    public async Task OtherRefusalsStayOrdinaryErrors()
    {
        var fake = new FakeUploadHandler { Refuse = (403, """{"error":{"errors":[{"reason":"insufficientFilePermissions"}]}}""") };
        var e = await Assert.ThrowsAsync<IOException>(() =>
            Repository(fake).Upload("a@b.c", "p", "v.mkv", "video/x-matroska", 10, () => new MemoryStream(new byte[10])));
        Assert.IsNotType<DriveStorageFullException>(e);
    }
}
