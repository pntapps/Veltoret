using System.IO.Compression;
using Veltoret.Core.Drive;

namespace Veltoret.Core.Tests.Drive;

public class ZipExtractorTests
{
    private const int Chunk = 8 * 1024 * 1024;

    private static byte[] RandomBytes(int seed, int n)
    {
        var b = new byte[n];
        new Random(seed).NextBytes(b);
        return b;
    }

    /// <summary>A ZIP as Windows/Java would write it to a non-seekable stream (data descriptors, sizes unknown up front) or not.</summary>
    private static byte[] Zip(bool dataDescriptors, params (string Name, byte[] Bytes)[] entries)
    {
        var ms = new MemoryStream();
        Stream target = dataDescriptors ? new WriteOnly(ms) : ms;
        using (var zip = new ZipArchive(target, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, bytes) in entries)
            {
                using var s = zip.CreateEntry(name).Open();
                s.Write(bytes);
            }
        return ms.ToArray();
    }

    private static (FakeDriveClient Drive, string Parent, string ZipId) Setup(byte[] zip, string zipName = "Show.S01.zip")
    {
        var drive = new FakeDriveClient();
        var parent = drive.Add("root", "Shows", folder: true);
        var zipId = drive.Add(parent, zipName, zip);
        return (drive, parent, zipId);
    }

    private static Task<ExtractResult> Run(FakeDriveClient drive, string parent, string zipId, ZipAfterExtract after = ZipAfterExtract.Keep,
        string zipName = "Show.S01.zip") =>
        new ZipExtractor(drive).Run("a@b.c", zipId, zipName, parent, after, _ => { }, CancellationToken.None);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EntriesArriveByteIdenticalInAFolderNamedAfterTheZip(bool dataDescriptors)
    {
        var e1 = RandomBytes(4, Chunk + 500);
        var e2 = RandomBytes(5, 3000);
        var (drive, parent, zipId) = Setup(Zip(dataDescriptors, ("Season 1/S01E01.mkv", e1), ("Season 1/S01E02.mkv", e2)));

        var result = await Run(drive, parent, zipId);

        Assert.Equal(2, result.Count);
        Assert.Null(result.ZipNote);
        var root = drive.Items[result.FolderId];
        Assert.Equal("Show.S01", root.File.Name);
        var files = drive.Items.Values.Where(i => !i.File.IsFolder && i.File.Id != zipId).ToDictionary(i => drive.PathOf(i.File.Id)!);
        Assert.Equal(e1, files["Shows/Show.S01/Season 1/S01E01.mkv"].Bytes);
        Assert.Equal(e2, files["Shows/Show.S01/Season 1/S01E02.mkv"].Bytes);
        Assert.True(drive.Items.ContainsKey(zipId)); // Keep
    }

    [Fact]
    public async Task JunkIsSkippedAndDotDotSegmentsCantEscapeTheFolder()
    {
        var (drive, parent, zipId) = Setup(Zip(false,
            ("__MACOSX/Season 1/._S01E01.mkv", new byte[10]),
            ("Season 1/._S01E01.mkv", new byte[10]),
            ("Season 1/.DS_Store", new byte[10]),
            ("Thumbs.db", new byte[10]),
            ("desktop.ini", new byte[10]),
            ("../../evil.mkv", new byte[20]),
            ("Season 1/./../S01E03.mkv", new byte[30])));

        var result = await Run(drive, parent, zipId);

        Assert.Equal(2, result.Count);
        var paths = drive.Items.Values.Where(i => !i.File.IsFolder && i.File.Id != zipId).Select(i => drive.PathOf(i.File.Id)!).OrderBy(p => p, StringComparer.Ordinal).ToList();
        Assert.Equal(new[] { "Shows/Show.S01/Season 1/S01E03.mkv", "Shows/Show.S01/evil.mkv" }, paths);
    }

    [Fact]
    public async Task ResumeSkipsFilesAlreadyThereWithTheSameSize()
    {
        var e1 = RandomBytes(6, 5000);
        var e2 = RandomBytes(7, 6000);
        var (drive, parent, zipId) = Setup(Zip(false, ("S01E01.mkv", e1), ("S01E02.mkv", e2)));
        var earlier = drive.Add(parent, "Show.S01", folder: true);
        drive.Add(earlier, "S01E01.mkv", e1);           // finished on an earlier run
        drive.Add(earlier, "S01E02.mkv", new byte[100]); // cut short: different size, uploaded again

        var result = await Run(drive, parent, zipId);

        Assert.Equal(earlier, result.FolderId);
        Assert.Equal(2, result.Count);
        Assert.Equal(1, drive.UploadCalls);
    }

    [Theory]
    [InlineData(ZipAfterExtract.Trash, "ZIP moved to trash")]
    [InlineData(ZipAfterExtract.Delete, "ZIP deleted")]
    public async Task ArchiveIsRemovedOnlyAfterEverythingWasExtracted(ZipAfterExtract after, string note)
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("S01E01.mkv", new byte[100])));
        var forgotten = new List<string>();
        var result = await new ZipExtractor(drive, id => { forgotten.Add(id); return Task.CompletedTask; })
            .Run("a@b.c", zipId, "Show.S01.zip", parent, after, _ => { }, CancellationToken.None);
        Assert.Equal(note, result.ZipNote);
        Assert.Equal(new[] { zipId }, forgotten);
        Assert.Equal(after == ZipAfterExtract.Trash, drive.Trashed.Contains(zipId));
        Assert.Equal(after == ZipAfterExtract.Delete, drive.Deleted.Contains(zipId));
    }

    [Theory]
    [InlineData(ZipAfterExtract.Trash)]
    [InlineData(ZipAfterExtract.Delete)]
    public async Task ArchiveThatProducedNothingIsKept(ZipAfterExtract after)
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("__MACOSX/x", new byte[3]), (".DS_Store", new byte[3])));
        var result = await Run(drive, parent, zipId, after);
        Assert.Equal(0, result.Count);
        Assert.Null(result.ZipNote);
        Assert.Empty(drive.Trashed);
        Assert.Empty(drive.Deleted);
    }

    [Fact]
    public async Task ArchiveIsKeptWhenAnUploadFails()
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("a.mkv", new byte[10]), ("b.mkv", new byte[10])));
        drive.UploadFailure = n => n == "b.mkv" ? new IOException("network") : null;
        await Assert.ThrowsAsync<IOException>(() => Run(drive, parent, zipId, ZipAfterExtract.Delete));
        Assert.Empty(drive.Deleted);
    }

    [Fact]
    public async Task FullDriveFailsWithCountAndAdvice()
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("a.mkv", new byte[10]), ("b.mkv", new byte[10])));
        drive.UploadFailure = n => n == "b.mkv" ? new DriveStorageFullException() : null;
        var e = await Assert.ThrowsAsync<ExtractFailedException>(() => Run(drive, parent, zipId));
        Assert.Equal("Google Drive is full after 1 file. Free up space (and empty Drive's trash), then extract again: it continues where it stopped.", e.Message);
    }

    [Fact]
    public async Task DamagedZipIsReported()
    {
        var whole = Zip(false, ("a.mkv", new byte[200_000]), ("b.mkv", new byte[200_000]));
        // Cut off part-way through the first entry's compressed data.
        var (drive, parent, zipId) = Setup(whole[..60]);
        var e = await Assert.ThrowsAnyAsync<Exception>(() => Run(drive, parent, zipId));
        // Either flagged as an unreadable archive (no retry) or as a read error the job retries.
        Assert.True(e is ExtractFailedException or IOException, e.GetType().Name + ": " + e.Message);
    }

    [Fact]
    public async Task QuotaErrorFailsTheJobWithoutRetry()
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("a.mkv", new byte[10])));
        drive.UploadFailure = _ => new DriveStorageFullException();
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var service = new TransferService(drive, path) { Backoff = new[] { TimeSpan.Zero } };
            var finished = new TaskCompletionSource<TransferJob>();
            service.JobFinished += j => finished.TrySetResult(j);
            service.Extract("a@b.c", zipId, "Show.S01.zip", 100, parent, ZipAfterExtract.Keep, wifiOnly: false);
            var job = await finished.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(TransferState.Failed, job.State);
            Assert.Equal(1, job.Attempt);
            Assert.Equal(1, drive.Downloads);
            Assert.StartsWith("Google Drive is full.", job.Error);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task NetworkErrorsAreRetriedFourTimesThenFail()
    {
        var (drive, parent, zipId) = Setup(Zip(false, ("a.mkv", new byte[10])));
        drive.UploadFailure = _ => new IOException("Connection reset");
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var service = new TransferService(drive, path) { Backoff = new[] { TimeSpan.Zero } };
            var finished = new TaskCompletionSource<TransferJob>();
            service.JobFinished += j => finished.TrySetResult(j);
            var first = service.Extract("a@b.c", zipId, "Show.S01.zip", 100, parent, ZipAfterExtract.Keep, wifiOnly: false);
            // Extracting the same ZIP again while it runs doesn't start a second job.
            Assert.Equal(first.Id, service.Extract("a@b.c", zipId, "Show.S01.zip", 100, parent, ZipAfterExtract.Keep, false).Id);
            var job = await finished.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(TransferState.Failed, job.State);
            Assert.Equal(4, job.Attempt);
            Assert.Equal(4, drive.Downloads);
            Assert.Equal("Connection reset", job.Error);

            // Jobs survive a restart: the failed one is still listed.
            var reloaded = new TransferService(drive, path);
            Assert.Contains(reloaded.Jobs, j => j.Id == job.Id && j.State == TransferState.Failed);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task UploadJobUploadsTheLocalFile()
    {
        var drive = new FakeDriveClient();
        var parent = drive.Add("root", "Movies", folder: true);
        var local = Path.Combine(Path.GetTempPath(), "veltoret-upload-" + Guid.NewGuid().ToString("N") + ".mkv");
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid().ToString("N") + ".json");
        var bytes = RandomBytes(9, 12345);
        await File.WriteAllBytesAsync(local, bytes);
        try
        {
            var service = new TransferService(drive, path) { Backoff = new[] { TimeSpan.Zero } };
            var finished = new TaskCompletionSource<TransferJob>();
            service.JobFinished += j => finished.TrySetResult(j);
            service.Upload("a@b.c", parent, local);
            var job = await finished.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(TransferState.Succeeded, job.State);
            var uploaded = drive.Children(parent).Single();
            Assert.Equal(Path.GetFileName(local), uploaded.File.Name);
            Assert.Equal(bytes, uploaded.Bytes);
        }
        finally
        {
            File.Delete(local);
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("__MACOSX/a/b.mkv", true)]
    [InlineData("Season 1/._S01E01.mkv", true)]
    [InlineData("x/.DS_Store", true)]
    [InlineData("Thumbs.db", true)]
    [InlineData("a/desktop.ini", true)]
    [InlineData("Season 1/S01E01.mkv", false)]
    [InlineData("MACOSX/a.mkv", false)]
    public void Junk(string path, bool junk) => Assert.Equal(junk, ZipExtractor.IsJunk(path));

    /// <summary>Forces ZipArchive to write data descriptors (it can't seek back to fill in sizes).</summary>
    private sealed class WriteOnly(Stream inner) : Stream
    {
        private long _written;
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _written; set => throw new NotSupportedException(); }
        public override void Flush() => inner.Flush();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count)
        {
            inner.Write(buffer, offset, count);
            _written += count;
        }
    }
}
