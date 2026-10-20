using System.IO;
using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Veltoret.App.Player;

/// <summary>
/// Feeds libVLC from a seekable stream (Drive and SMB range-reading streams from <c>Storage.OpenRead</c>). Like
/// LibVLCSharp's StreamMediaInput, plus large reads, a few retries on read failures, and the last failure kept so
/// the error card can say what went wrong (403, offline, auth…) — libVLC itself only reports "error".
/// </summary>
internal sealed class SourceMediaInput : MediaInput
{
    private const int ChunkSize = 256 * 1024;
    private readonly Stream _stream;
    private readonly byte[] _buffer = new byte[ChunkSize];

    private volatile bool _aborted;

    /// <summary>The player is stopping: reads end at once (no retries), so libVLC can let go quickly.</summary>
    public void Abort() => _aborted = true;

    /// <summary>The last exception a read, seek or open threw.</summary>
    public Exception? LastError { get; private set; }

    public SourceMediaInput(Stream stream)
    {
        _stream = stream.CanSeek ? new BufferedStream(stream, ChunkSize) : stream;
        CanSeek = stream.CanSeek;
    }

    public override bool Open(out ulong size)
    {
        try
        {
            try { size = (ulong)_stream.Length; }
            catch (NotSupportedException) { size = ulong.MaxValue; }
            if (_stream.CanSeek) _stream.Seek(0, SeekOrigin.Begin);
            return true;
        }
        catch (Exception e)
        {
            LastError = e;
            size = 0;
            return false;
        }
    }

    public override int Read(IntPtr buf, uint len)
    {
        var want = (int)Math.Min(len, (uint)_buffer.Length);
        for (var attempt = 0; ; attempt++)
        {
            if (_aborted) return -1;
            long position = 0;
            try
            {
                if (_stream.CanSeek) position = _stream.Position;
                var n = _stream.Read(_buffer, 0, want);
                if (n > 0) Marshal.Copy(_buffer, 0, buf, n);
                return n;
            }
            catch (Exception e) when (attempt < 3 && !_aborted && e is IOException or TimeoutException or System.Net.Http.HttpRequestException)
            {
                LastError = e;
                Thread.Sleep(400 * (attempt + 1));
                try
                {
                    if (_stream.CanSeek) _stream.Seek(position, SeekOrigin.Begin);
                }
                catch (Exception) { }
            }
            catch (Exception e)
            {
                LastError = e;
                return -1;
            }
        }
    }

    public override bool Seek(ulong offset)
    {
        if (_aborted) return false;
        try
        {
            _stream.Seek((long)offset, SeekOrigin.Begin);
            return true;
        }
        catch (Exception e)
        {
            LastError = e;
            return false;
        }
    }

    public override void Close()
    {
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try { _stream.Dispose(); }
            catch (Exception) { }
        }
        base.Dispose(disposing);
    }
}
