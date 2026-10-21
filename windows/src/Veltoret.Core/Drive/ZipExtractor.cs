using SharpCompress.Common;
using SharpCompress.Compressors.Deflate;
using SharpCompress.Readers;
using SharpCompress.Readers.Zip;
using Veltoret.Core.Library;

namespace Veltoret.Core.Drive;

public sealed record ExtractProgress(float Fraction, string Current, int Done);

public sealed record ExtractResult(int Count, string FolderId, string? ZipNote);

/// <summary>An extraction that must not be retried (full Drive, unreadable ZIP). Message is for the user.</summary>
public sealed class ExtractFailedException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Unpacks a ZIP that lives in Google Drive back into Google Drive (Android: ExtractWorker.doWork).
///
/// Nothing is written to this PC: the archive is downloaded as a stream, read forward-only (SharpCompress
/// ZipReader; never System.IO.Compression.ZipArchive, which buffers a non-seekable stream in memory), and each
/// entry is piped straight into a resumable upload. Re-running skips files already in Drive, so an interrupted
/// season picks up where it stopped. The ZIP is trashed/deleted only after every file was extracted.
/// </summary>
public sealed class ZipExtractor(IDriveClient drive, Func<string, Task>? forgetArchive = null)
{
    public async Task<ExtractResult> Run(string email, string zipId, string zipName, string parentId, ZipAfterExtract after,
        Action<ExtractProgress> report, CancellationToken ct)
    {
        report(new ExtractProgress(0f, "Preparing…", 0));
        var extracted = 0;
        var alreadyThere = 0;
        try
        {
            var folders = new FolderCache(drive, email);
            var root = await folders.Child(parentId, FilenameParser.BaseName(zipName), ct).ConfigureAwait(false);

            await drive.Download(email, zipId, async (raw, length) =>
            {
                var counter = new CountingStream(raw);
                var buffered = new BufferedStream(counter, 256 * 1024);
                using var reader = ZipReader.OpenReader(buffered, new ReaderOptions { LeaveStreamOpen = true });
                while (await Task.Run(reader.MoveToNextEntry, ct).ConfigureAwait(false))
                {
                    ct.ThrowIfCancellationRequested();
                    var entry = reader.Entry;
                    var path = (entry.Key ?? "").Replace('\\', '/').Trim('/');
                    if (entry.IsDirectory || path.Length == 0 || IsJunk(path)) continue;
                    if (entry.IsEncrypted) throw new ExtractFailedException("This ZIP is password-protected, which isn't supported.");

                    var slash = path.LastIndexOf('/');
                    var dirId = await folders.Path(root, slash < 0 ? "" : path[..slash], ct).ConfigureAwait(false);
                    var fileName = slash < 0 ? path : path[(slash + 1)..];
                    // A data-descriptor entry (general-purpose bit 3) carries size 0 in its local header: unknown.
                    var size = entry.Size > 0 ? entry.Size : -1;
                    var existing = (await folders.Files(dirId, ct).ConfigureAwait(false)).GetValueOrDefault(fileName);
                    if (existing != null && (size < 0 || existing.SizeBytes == size))
                    {
                        alreadyThere++;
                        continue; // extracted by an earlier run; moving on skips its bytes
                    }

                    float Fraction() => length > 0 ? (float)counter.Count / length : 0f;
                    report(new ExtractProgress(Fraction(), fileName, extracted));
                    var lastPercent = -1;
                    var done = extracted;
                    await using (var entryStream = reader.OpenEntryStream())
                    {
                        await drive.Upload(email, dirId, fileName, DriveFormat.MimeFor(fileName), size,
                            () => new NonClosingStream(entryStream),
                            (_, _) =>
                            {
                                var percent = (int)(Fraction() * 100);
                                if (percent == lastPercent) return;
                                lastPercent = percent;
                                report(new ExtractProgress(Fraction(), fileName, done));
                            }, ct).ConfigureAwait(false);
                    }
                    extracted++;
                }
            }, ct).ConfigureAwait(false);

            // The whole archive was read and every file is in Drive. Never remove an archive that produced nothing.
            string? zipNote = null;
            if (after != ZipAfterExtract.Keep && extracted + alreadyThere > 0)
            {
                try
                {
                    if (after == ZipAfterExtract.Delete)
                    {
                        await drive.DeletePermanently(email, zipId, ct).ConfigureAwait(false);
                        zipNote = "ZIP deleted";
                    }
                    else
                    {
                        await drive.Trash(email, zipId, ct).ConfigureAwait(false);
                        zipNote = "ZIP moved to trash";
                    }
                    if (forgetArchive != null) await forgetArchive(zipId).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception e)
                {
                    zipNote = $"ZIP kept: {e.Message}";
                }
            }
            return new ExtractResult(extracted + alreadyThere, root, zipNote);
        }
        catch (DriveStorageFullException e)
        {
            // Retrying can't help until space is freed, and every retry would download the ZIP again.
            var done = extracted + alreadyThere;
            throw new ExtractFailedException("Google Drive is full" +
                (done > 0 ? " after " + (done == 1 ? "1 file" : $"{done} files") : "") +
                ". Free up space (and empty Drive's trash), then extract again: it continues where it stopped.", e);
        }
        catch (Exception e) when (ZipError(e) is { } message)
        {
            throw new ExtractFailedException(message, e);
        }
    }

    /// <summary>A user message for errors that mean the archive itself can't be read (no retry); null otherwise.</summary>
    public static string? ZipError(Exception e)
    {
        switch (e)
        {
            case ExtractFailedException or OperationCanceledException:
                return null;
            case SharpCompress.Common.CryptographicException:
                return "This ZIP is password-protected, which isn't supported.";
            case NotSupportedException:
                return "This ZIP uses a compression format Veltoret can't read. Re-create it with standard ZIP compression.";
            case InvalidFormatException or ZlibException or IncompleteArchiveException or SharpCompressException:
                var msg = e.Message;
                var lower = msg.ToLowerInvariant();
                if (lower.Contains("encrypt") || lower.Contains("password")) return "This ZIP is password-protected, which isn't supported.";
                if (lower.Contains("compression method") || lower.Contains("compression type") || lower.Contains("not supported"))
                    return "This ZIP uses a compression format Veltoret can't read. Re-create it with standard ZIP compression.";
                return $"The ZIP looks damaged or incomplete ({msg}).";
            default:
                return null;
        }
    }

    /// <summary>__MACOSX/, AppleDouble "._" files, .DS_Store, Thumbs.db, desktop.ini.</summary>
    public static bool IsJunk(string path)
    {
        var name = path[(path.LastIndexOf('/') + 1)..];
        return path.StartsWith("__MACOSX/", StringComparison.Ordinal) || name.StartsWith("._", StringComparison.Ordinal) ||
               name is ".DS_Store" or "Thumbs.db" or "desktop.ini";
    }

    /// <summary>Drive folder lookups with caching: reuses existing folders so re-runs land in the same place.</summary>
    private sealed class FolderCache(IDriveClient drive, string email)
    {
        private readonly Dictionary<string, Dictionary<string, DriveFile>> _children = new();
        private readonly Dictionary<string, string> _resolved = new();

        public async Task<Dictionary<string, DriveFile>> Files(string folderId, CancellationToken ct)
        {
            if (_children.TryGetValue(folderId, out var known)) return known;
            var map = new Dictionary<string, DriveFile>(StringComparer.Ordinal);
            foreach (var f in await drive.ListChildren(email, folderId, "folder,name_natural", ct).ConfigureAwait(false))
                map[f.Name] = f; // duplicates: the last one wins (associateBy)
            _children[folderId] = map;
            return map;
        }

        public async Task<string> Child(string parentId, string name, CancellationToken ct)
        {
            var files = await Files(parentId, ct).ConfigureAwait(false);
            if (files.TryGetValue(name, out var existing) && existing.IsFolder) return existing.Id;
            var created = await drive.CreateFolder(email, parentId, name, ct).ConfigureAwait(false);
            files[name] = created;
            _children[created.Id] = new Dictionary<string, DriveFile>(StringComparer.Ordinal);
            return created.Id;
        }

        public async Task<string> Path(string root, string relative, CancellationToken ct)
        {
            if (relative.Length == 0) return root;
            if (_resolved.TryGetValue(relative, out var known)) return known;
            var current = root;
            // Ignore "." / ".." so a malformed archive can't climb out of its own folder.
            foreach (var segment in relative.Split('/').Where(s => !string.IsNullOrWhiteSpace(s) && s != "." && s != ".."))
                current = await Child(current, segment, ct).ConfigureAwait(false);
            _resolved[relative] = current;
            return current;
        }
    }
}

/// <summary>Counts the compressed bytes read (progress = consumed / ZIP length).</summary>
public sealed class CountingStream(Stream inner) : Stream
{
    private long _count;
    public long Count => Interlocked.Read(ref _count);

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    public override int Read(byte[] buffer, int offset, int count)
    {
        var n = inner.Read(buffer, offset, count);
        if (n > 0) Interlocked.Add(ref _count, n);
        return n;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        var n = await inner.ReadAsync(buffer, ct).ConfigureAwait(false);
        if (n > 0) Interlocked.Add(ref _count, n);
        return n;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
        ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();
}

/// <summary>Lets the uploader dispose an entry stream without closing the archive (Android: KeepOpen).</summary>
public sealed class NonClosingStream(Stream inner) : Stream
{
    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => inner.ReadAsync(buffer, ct);
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => inner.ReadAsync(buffer, offset, count, ct);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { }
    public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
