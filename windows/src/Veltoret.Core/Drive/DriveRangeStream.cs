namespace Veltoret.Core.Drive;

/// <summary>
/// A seekable, read-only view of a Drive file over HTTP Range requests (Android: DriveMedia + OkHttp data source).
/// The player streams Drive videos through it.
///
/// One connection reads ahead from the current position. A seek within the read-ahead buffer or a short way
/// forward is served from it / by reading on; anything else closes the connection and opens a new range at the
/// new position. Every (re)open is a new request with a fresh bearer token, so seeking still works long after the
/// first token expired. Sync <see cref="Read(byte[], int, int)"/> is supported for LibVLC's reader thread.
/// </summary>
public sealed class DriveRangeStream : Stream
{
    private const int BufferSize = 2 * 1024 * 1024;
    /// <summary>Forward seeks shorter than this read through instead of opening a new connection.</summary>
    private const long SkipAhead = 4 * 1024 * 1024;

    private readonly DriveRepository _drive;
    private readonly string _email;
    private readonly string _id;
    private readonly long _length;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly CancellationTokenSource _disposed = new();

    private HttpResponseMessage? _response;
    private Stream? _body;
    /// <summary>File offset of the next byte the connection will deliver.</summary>
    private long _connectionPos = -1;

    private readonly byte[] _buffer = new byte[BufferSize];
    /// <summary>File offset of _buffer[0]; valid bytes are _buffer[0.._bufferCount).</summary>
    private long _bufferStart;
    private int _bufferCount;

    private long _position;

    public DriveRangeStream(DriveRepository drive, string email, string id, long length)
    {
        _drive = drive;
        _email = email;
        _id = id;
        _length = length;
    }

    public override bool CanRead => !_disposed.IsCancellationRequested;
    public override bool CanSeek => true;
    public override bool CanWrite => false;
    public override long Length => _length;

    public override long Position
    {
        get => _position;
        set => Seek(value, SeekOrigin.Begin);
    }

    public override long Seek(long offset, SeekOrigin origin)
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
        return _position;
    }

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
        ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

    public override async ValueTask<int> ReadAsync(Memory<byte> destination, CancellationToken ct = default)
    {
        if (destination.Length == 0) return 0;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _disposed.Token);
        await _lock.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            if (_length >= 0 && _position >= _length) return 0;

            // Served from the read-ahead buffer?
            if (_position >= _bufferStart && _position < _bufferStart + _bufferCount)
                return CopyFromBuffer(destination);

            // Refill the buffer from the connection, (re)opening it when it isn't at a useful position.
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    var filled = await Fill(linked.Token).ConfigureAwait(false);
                    return filled ? CopyFromBuffer(destination) : 0;
                }
                catch (IOException) when (attempt < 2 && !linked.IsCancellationRequested)
                {
                    // A dropped connection mid-stream: reopen at the same place and carry on.
                    CloseConnection();
                    await Task.Delay(500 * (attempt + 1), linked.Token).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    private int CopyFromBuffer(Memory<byte> destination)
    {
        var start = (int)(_position - _bufferStart);
        var n = Math.Min(destination.Length, _bufferCount - start);
        _buffer.AsMemory(start, n).CopyTo(destination);
        _position += n;
        return n;
    }

    /// <summary>Puts the bytes at _position into the buffer. False at end of file.</summary>
    private async Task<bool> Fill(CancellationToken ct)
    {
        if (_body == null || _position < _connectionPos || _position - _connectionPos > SkipAhead)
        {
            CloseConnection();
            _response = await _drive.OpenRange(_email, _id, _position, ct).ConfigureAwait(false);
            if (_response == null) return false;
            var raw = await _response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            _body = new IdleTimeoutStream(raw, DriveRepository.ReadTimeout, CancellationToken.None);
            // A server that ignores Range answers 200 with the whole file.
            _connectionPos = _response.StatusCode == System.Net.HttpStatusCode.PartialContent ? _position : 0;
        }

        // Read through bytes before _position (a short forward seek, or a 200 answer).
        while (_connectionPos < _position)
        {
            var skip = (int)Math.Min(_buffer.Length, _position - _connectionPos);
            var n = await _body!.ReadAsync(_buffer.AsMemory(0, skip), ct).ConfigureAwait(false);
            if (n <= 0) throw new IOException("The connection to Google Drive closed early");
            _connectionPos += n;
        }

        // Read ahead: at least one chunk, more while the connection already has data waiting.
        _bufferStart = _position;
        _bufferCount = 0;
        var want = _length >= 0 ? (int)Math.Min(_buffer.Length, _length - _position) : _buffer.Length;
        while (_bufferCount < want)
        {
            var n = await _body!.ReadAsync(_buffer.AsMemory(_bufferCount, want - _bufferCount), ct).ConfigureAwait(false);
            if (n <= 0) break;
            _bufferCount += n;
            _connectionPos += n;
            if (_bufferCount >= 256 * 1024) break; // enough to answer; don't stall the player waiting for 2 MB
        }
        if (_bufferCount == 0)
        {
            if (_length >= 0 && _position < _length) throw new IOException("The connection to Google Drive closed early");
            return false;
        }
        return true;
    }

    private void CloseConnection()
    {
        try { _body?.Dispose(); } catch (Exception) { }
        try { _response?.Dispose(); } catch (Exception) { }
        _body = null;
        _response = null;
        _connectionPos = -1;
    }

    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && !_disposed.IsCancellationRequested)
        {
            _disposed.Cancel();
            CloseConnection();
        }
        base.Dispose(disposing);
    }
}
