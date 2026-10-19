using SMBLibrary;
using SMBLibrary.Client;
using FileAttributes = SMBLibrary.FileAttributes;

namespace Veltoret.Core.Smb;

/// <summary>
/// An open file on a share for random-access reads (the player's data source; Android: SmbReader + SmbDataSource).
/// Seekable, read-only and thread-safe. Reads are positioned (SMB READ at an offset) in chunks of up to 1 MiB, kept
/// in a small cache with read-ahead of the next chunks so playback doesn't wait on the network. A failed read marks
/// the connection broken; the read is retried once on a fresh connection (with the file reopened).
/// </summary>
public sealed class SmbReadStream : Stream
{
    private const int MaxChunk = 1024 * 1024;
    private const int ReadAhead = 2;
    private const int CacheChunks = 6;

    private readonly SmbFileSource _source;
    private readonly SmbPath _path;
    private readonly object _sync = new();
    private readonly object _handleLock = new();
    private readonly Dictionary<long, Task<byte[]>> _chunks = new();
    private readonly LinkedList<long> _recent = new();
    private OpenFile? _file;
    private long _position;
    private long _length;
    private int _chunkSize = MaxChunk;
    private volatile bool _disposed;

    private sealed record OpenFile(SmbConnection Connection, ISMBFileStore Store, object Handle);

    internal SmbReadStream(SmbFileSource source, SmbPath path)
    {
        _source = source;
        _path = path;
    }

    /// <summary>Opens the file and reads its size (synchronous; called off the UI thread).</summary>
    internal void Open()
    {
        lock (_handleLock) _file = OpenFileOn(_source.Connection(_path.Host, fresh: false), retry: true);
    }

    private OpenFile OpenFileOn(SmbConnection conn, bool retry)
    {
        try
        {
            lock (conn.Gate) return OpenLocked(conn);
        }
        catch (Exception e) when (retry && SmbErrors.IsDropped(e))
        {
            conn.Broken = true;
            var fresh = _source.Connection(_path.Host, fresh: true);
            lock (fresh.Gate) return OpenLocked(fresh);
        }
    }

    private OpenFile OpenLocked(SmbConnection conn)
    {
        var shareName = _path.Share ?? throw new SmbException($"Pick a shared folder on {_path.Host} first");
        if (_path.Segments.Count == 0) throw new SmbException($"\"{shareName}\" isn't a file");
        var store = conn.Tree(shareName);
        var status = store.CreateFile(out var handle, out _, _path.SharePath,
            AccessMask.GENERIC_READ | AccessMask.SYNCHRONIZE, FileAttributes.Normal,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN,
            CreateOptions.FILE_NON_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
        SmbFileSource.Check(status, "Open file");
        try
        {
            SmbFileSource.Check(store.GetFileInformation(out var info, handle, FileInformationClass.FileStandardInformation), "Read size");
            _length = ((FileStandardInformation)info).EndOfFile;
            // The chunk size is fixed once (chunk indexes depend on it), from the first connection's limit.
            if (_file == null) _chunkSize = (int)Math.Min(MaxChunk, Math.Max(64 * 1024, conn.Client.MaxReadSize));
        }
        catch
        {
            try { store.CloseFile(handle); } catch { }
            throw;
        }
        return new OpenFile(conn, store, handle);
    }

    /// <summary>The open file, reopened on a fresh connection when the old one broke.</summary>
    private OpenFile CurrentFile(bool reopen)
    {
        lock (_handleLock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var f = _file;
            if (!reopen && f != null && f.Connection.Alive) return f;
            if (f != null) f.Connection.Broken = true;
            _file = OpenFileOn(_source.Connection(_path.Host, fresh: false), retry: false);
            return _file;
        }
    }

    private byte[] FetchChunk(long index)
    {
        var offset = index * _chunkSize;
        var want = (int)Math.Min(_chunkSize, _length - offset);
        if (want <= 0) return Array.Empty<byte>();
        for (var attempt = 0; ; attempt++)
        {
            OpenFile? f = null;
            try
            {
                f = CurrentFile(reopen: attempt > 0);
                return ReadRange(f, offset, want);
            }
            catch (ObjectDisposedException) when (_disposed)
            {
                throw;
            }
            catch (Exception e) when (SmbErrors.IsDropped(e))
            {
                if (f != null) f.Connection.Broken = true;
                if (attempt >= 1 || _disposed) throw new IOException(SmbErrors.Describe(e), e);
            }
            catch (SmbException)
            {
                throw;
            }
            catch (Exception e)
            {
                throw new IOException(SmbErrors.Describe(e), e);
            }
        }
    }

    private static byte[] ReadRange(OpenFile f, long offset, int want)
    {
        var buffer = new byte[want];
        var filled = 0;
        while (filled < want)
        {
            NTStatus status;
            byte[] data;
            lock (f.Connection.Gate)
            {
                if (!f.Connection.Client.IsConnected) throw new SmbTransportException("Disconnected");
                status = f.Store.ReadFile(out data, f.Handle, offset + filled, want - filled);
            }
            if (status == NTStatus.STATUS_END_OF_FILE) break;
            SmbFileSource.Check(status, "Read");
            if (data == null || data.Length == 0) break;
            Buffer.BlockCopy(data, 0, buffer, filled, Math.Min(data.Length, want - filled));
            filled += data.Length;
        }
        return filled == want ? buffer : buffer[..filled];
    }

    private Task<byte[]> Chunk(long index)
    {
        lock (_sync)
        {
            if (_chunks.TryGetValue(index, out var task) && !task.IsFaulted && !task.IsCanceled)
            {
                _recent.Remove(index);
                _recent.AddFirst(index);
                return task;
            }
            task = Task.Run(() => FetchChunk(index));
            _chunks[index] = task;
            _recent.Remove(index);
            _recent.AddFirst(index);
            while (_recent.Count > CacheChunks)
            {
                var old = _recent.Last!.Value;
                _recent.RemoveLast();
                _chunks.Remove(old);
            }
            // Failed read-aheads are dropped so the real read tries again.
            task.ContinueWith(t =>
            {
                _ = t.Exception;
                lock (_sync) if (_chunks.TryGetValue(index, out var cur) && cur == t) { _chunks.Remove(index); _recent.Remove(index); }
            }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            return task;
        }
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        ValidateBufferArguments(buffer, offset, count);
        return Read(buffer.AsSpan(offset, count));
    }

    public override int Read(Span<byte> destination)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (destination.Length == 0) return 0;
        long pos;
        lock (_sync) pos = _position;
        if (pos >= _length) return 0;
        var index = pos / _chunkSize;
        byte[] chunk;
        try
        {
            chunk = Chunk(index).GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is not IOException and not ObjectDisposedException)
        {
            throw new IOException(SmbErrors.Describe(e), e);
        }
        var inChunk = (int)(pos - index * _chunkSize);
        var n = Math.Min(destination.Length, chunk.Length - inChunk);
        if (n <= 0) return 0;
        chunk.AsSpan(inChunk, n).CopyTo(destination);
        lock (_sync)
        {
            // Another reader may have moved the position meanwhile; this read still answers from `pos`.
            if (_position == pos) _position = pos + n;
        }
        var chunks = (_length + _chunkSize - 1) / _chunkSize;
        for (var k = 1; k <= ReadAhead && index + k < chunks; k++) _ = Chunk(index + k);
        return n;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        Task.Run(() => Read(buffer, offset, count), cancellationToken);

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        new(Task.Run(() => Read(buffer.Span), cancellationToken));

    /// <summary>Reads up to <paramref name="count"/> bytes at <paramref name="position"/> without moving the stream's position.</summary>
    public int ReadAt(long position, byte[] buffer, int offset, int count)
    {
        if (position >= _length || count == 0) return 0;
        var index = position / _chunkSize;
        var chunk = Chunk(index).GetAwaiter().GetResult();
        var inChunk = (int)(position - index * _chunkSize);
        var n = Math.Min(count, chunk.Length - inChunk);
        if (n <= 0) return 0;
        Buffer.BlockCopy(chunk, inChunk, buffer, offset, n);
        return n;
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        lock (_sync)
        {
            var target = origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => _position + offset,
                SeekOrigin.End => _length + offset,
                _ => throw new ArgumentOutOfRangeException(nameof(origin)),
            };
            if (target < 0) throw new IOException("Seek before the start of the file");
            _position = target;
            return target;
        }
    }

    public override bool CanRead => !_disposed;
    public override bool CanSeek => !_disposed;
    public override bool CanWrite => false;
    public override long Length => _length;

    public override long Position
    {
        get { lock (_sync) return _position; }
        set => Seek(value, SeekOrigin.Begin);
    }

    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (_disposed) return;
        _disposed = true;
        OpenFile? f;
        lock (_handleLock) { f = _file; _file = null; }
        lock (_sync) { _chunks.Clear(); _recent.Clear(); }
        if (f != null && f.Connection.Alive)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try { lock (f.Connection.Gate) f.Store.CloseFile(f.Handle); } catch { }
            });
        }
        base.Dispose(disposing);
    }
}
