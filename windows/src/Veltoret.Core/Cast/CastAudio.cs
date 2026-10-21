using System.Numerics;

namespace Veltoret.Core.Cast;

/// <summary>
/// Picks the audio language on a Chromecast (Android CastAudio, exact). The Default Media Receiver can't switch
/// audio tracks (it plays the file's default one), so the streamed copy marks every other audio track's TrackType
/// as 0x20 ("control"). Only those bytes change, so the size and offsets stay (seeking works) and the file itself
/// is never touched. MKV only.
/// </summary>
public static class CastAudio
{
    /// <summary>An MKV audio track: its TrackNumber and where its TrackType value sits in the file.</summary>
    public sealed record Track(long Number, long TypeOffset, int TypeLength)
    {
        /// <summary>Extra labels from the TrackEntry when present (not part of the Android port's matching).</summary>
        public string? Language { get; init; }
        public string? CodecId { get; init; }
        public string? Name { get; init; }
    }

    /// <summary>Reads up to <paramref name="length"/> bytes at <paramref name="position"/> (fewer at the end of the file).</summary>
    public delegate byte[] Reader(long position, int length);

    private const byte HiddenType = 0x20;
    private const long IdEbml = 0x1A45DFA3;
    private const long IdSegment = 0x18538067;
    private const long IdSeekHead = 0x114D9B74;
    private const long IdSeek = 0x4DBB;
    private const long IdSeekId = 0x53AB;
    private const long IdSeekPosition = 0x53AC;
    private const long IdCluster = 0x1F43B675;
    private const long IdTracks = 0x1654AE6B;
    private const long IdTrackEntry = 0xAE;
    private const long IdTrackNumber = 0xD7;
    private const long IdTrackType = 0x83;
    private const long TypeAudio = 2;
    private const long IdLanguage = 0x22B59C;
    private const long IdLanguageBcp47 = 0x22B59D;
    private const long IdCodecId = 0x86;
    private const long IdName = 0x536E;

    /// <summary>The file's audio tracks, or empty when it isn't MKV or its Tracks can't be found.</summary>
    public static List<Track> AudioTracks(Reader reader)
    {
        try { return Parse(new Cursor(reader)); }
        catch (Exception) { return new List<Track>(); }
    }

    /// <summary>A reader over a seekable stream (Storage.OpenRead).</summary>
    public static Reader StreamReader(Stream stream) => (position, length) =>
    {
        stream.Seek(position, SeekOrigin.Begin);
        var buffer = new byte[length];
        var read = 0;
        while (read < length)
        {
            var n = stream.Read(buffer, read, length - read);
            if (n <= 0) break;
            read += n;
        }
        return read == length ? buffer : buffer[..read];
    };

    /// <summary>Byte changes that leave only track <paramref name="keep"/> audible; none when it isn't one of <paramref name="tracks"/>.</summary>
    public static Dictionary<long, byte> HideAllBut(IReadOnlyList<Track> tracks, long keep)
    {
        var patches = new Dictionary<long, byte>();
        if (tracks.Count < 2 || tracks.All(t => t.Number != keep)) return patches;
        foreach (var t in tracks)
        {
            if (t.Number == keep) continue;
            // A big-endian unsigned int: zeros, then the new type in the last byte.
            for (var i = 0; i < t.TypeLength; i++) patches[t.TypeOffset + i] = i == t.TypeLength - 1 ? HiddenType : (byte)0;
        }
        return patches;
    }

    /// <summary>Applies <paramref name="patches"/> to <paramref name="buffer"/>, which holds <paramref name="count"/> bytes from <paramref name="position"/>.</summary>
    public static void Apply(IReadOnlyDictionary<long, byte> patches, long position, byte[] buffer, int count)
    {
        if (patches.Count == 0) return;
        foreach (var (offset, value) in patches)
            if (offset >= position && offset < position + count) buffer[offset - position] = value;
    }

    private static List<Track> Parse(Cursor c)
    {
        var empty = new List<Track>();
        var ebml = c.Element(0);
        if (ebml == null || ebml.Id != IdEbml || ebml.Size == null) return empty;
        var segment = c.Element(ebml.End);
        if (segment == null || segment.Id != IdSegment) return empty;
        var segmentEnd = segment.Size is { } s ? segment.Data + s : long.MaxValue;
        long? tracksAt = null;
        var p = segment.Data;
        // Tracks normally come before the first Cluster; some files store them after it (SeekHead says where).
        for (var i = 0; i < 64; i++)
        {
            if (p >= segmentEnd) return empty;
            var e = c.Element(p);
            if (e == null) return empty;
            switch (e.Id)
            {
                case IdTracks:
                    return Tracks(c, e);
                case IdSeekHead:
                    if (tracksAt == null && SeekTarget(c, e, IdTracks) is { } t) tracksAt = segment.Data + t;
                    break;
                case IdCluster:
                    if (tracksAt is not { } target || target <= p) return empty;
                    p = target;
                    continue;
            }
            if (e.Size == null) return empty;
            p = e.End;
        }
        return empty;
    }

    private static List<Track> Tracks(Cursor c, Element tracks)
    {
        var output = new List<Track>();
        if (tracks.Size is not { } size) return output;
        Children(c, tracks.Data, tracks.Data + size, entry =>
        {
            if (entry.Id != IdTrackEntry || entry.Size == null) return;
            long? number = null;
            long? type = null;
            long typeAt = 0;
            var typeLength = 0;
            string? language = null, codec = null, name = null;
            Children(c, entry.Data, entry.End, field =>
            {
                if (field.Size is not { } len) return;
                var length = (int)len;
                switch (field.Id)
                {
                    case IdTrackNumber: number = c.UInt(field.Data, length); break;
                    case IdTrackType: type = c.UInt(field.Data, length); typeAt = field.Data; typeLength = length; break;
                    case IdLanguage when length is > 0 and <= 64: language ??= c.Text(field.Data, length); break;
                    case IdLanguageBcp47 when length is > 0 and <= 64: language = c.Text(field.Data, length); break;
                    case IdCodecId when length is > 0 and <= 64: codec = c.Text(field.Data, length); break;
                    case IdName when length is > 0 and <= 256: name = c.Text(field.Data, length); break;
                }
            });
            if (type == TypeAudio && number is { } n && typeLength is >= 1 and <= 8)
                output.Add(new Track(n, typeAt, typeLength) { Language = language, CodecId = codec, Name = name });
        });
        return output;
    }

    /// <summary>The segment-relative position the SeekHead gives for element <paramref name="wanted"/>.</summary>
    private static long? SeekTarget(Cursor c, Element head, long wanted)
    {
        if (head.Size is not { } size) return null;
        long? found = null;
        Children(c, head.Data, head.Data + size, seek =>
        {
            if (seek.Id != IdSeek || seek.Size == null || found != null) return;
            long? id = null;
            long? position = null;
            Children(c, seek.Data, seek.End, f =>
            {
                if (f.Size is not { } len) return;
                switch (f.Id)
                {
                    case IdSeekId: id = c.UInt(f.Data, (int)len); break;
                    case IdSeekPosition: position = c.UInt(f.Data, (int)len); break;
                }
            });
            if (id == wanted) found = position;
        });
        return found;
    }

    private static void Children(Cursor c, long start, long end, Action<Element> block)
    {
        var p = start;
        while (p < end)
        {
            var e = c.Element(p);
            if (e == null) return;
            block(e);
            if (e.Size == null) return;
            p = e.End;
        }
    }

    /// <summary>An EBML element: <see cref="Data"/> is where its content starts; <see cref="Size"/> is null when unknown.</summary>
    private sealed record Element(long Id, long Data, long? Size)
    {
        public long End => Data + (Size ?? 0);
    }

    /// <summary>Reads the file in 64 KiB windows (at most 16 reads), so walking the header costs only a few reads.</summary>
    private sealed class Cursor(Reader reader)
    {
        private const int Window = 64 * 1024;
        private long _windowStart = -1;
        private byte[] _window = Array.Empty<byte>();
        private int _reads;

        public int Byte(long position)
        {
            if (_windowStart < 0 || position < _windowStart || position >= _windowStart + _window.Length)
            {
                if (++_reads > 16) throw new InvalidOperationException("Too many reads");
                _window = reader(position, Window);
                _windowStart = position;
                if (_window.Length == 0) throw new InvalidOperationException("End of file");
            }
            return _window[position - _windowStart];
        }

        public long UInt(long position, int length)
        {
            long v = 0;
            for (var i = 0; i < length; i++) v = (v << 8) | (long)Byte(position + i);
            return v;
        }

        public string Text(long position, int length)
        {
            var bytes = new byte[length];
            for (var i = 0; i < length; i++) bytes[i] = (byte)Byte(position + i);
            return System.Text.Encoding.UTF8.GetString(bytes).TrimEnd('\0');
        }

        public Element? Element(long position)
        {
            var first = Byte(position);
            var idLength = BitOperations.LeadingZeroCount((uint)first) - 23;
            if (idLength is < 1 or > 4) return null;
            var id = UInt(position, idLength);
            var sizeAt = position + idLength;
            var sizeFirst = Byte(sizeAt);
            var sizeLength = BitOperations.LeadingZeroCount((uint)sizeFirst) - 23;
            if (sizeLength is < 1 or > 8) return null;
            long size = sizeFirst & (0xFF >> sizeLength);
            var allOnes = size == 0xFF >> sizeLength;
            for (var i = 1; i < sizeLength; i++)
            {
                var b = Byte(sizeAt + i);
                size = (size << 8) | (long)b;
                if (b != 0xFF) allOnes = false;
            }
            return new Element(id, sizeAt + sizeLength, allOnes ? null : size);
        }
    }
}
