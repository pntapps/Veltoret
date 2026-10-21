using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;

namespace Veltoret.Core.Player;

public enum HdrFormat { Unknown, Sdr, Hdr10, Hlg, DolbyVision }

/// <summary>
/// Finds out whether a video is HDR before it plays (libVLC 3 doesn't expose the transfer function): reads the
/// colour information in the container header — Matroska/WebM Video → Colour → TransferCharacteristics and the Dolby
/// Vision block addition mapping, MP4/MOV <c>colr</c> (nclx) and <c>dvcC</c>/<c>dvvC</c> boxes — and falls back to the
/// file name ("HDR", "HDR10", "DV", "HLG") when the header doesn't say. Only the first megabytes are read.
/// </summary>
public static class HdrProbe
{
    /// <summary>ITU-T H.273 transfer characteristics: SMPTE ST 2084 (PQ) and ARIB STD-B67 (HLG).</summary>
    private const int TransferPq = 16, TransferHlg = 18;

    private const long MaxRead = 16L * 1024 * 1024;
    private const int MaxMoov = 64 * 1024 * 1024;

    public static string Label(HdrFormat f) => f switch
    {
        HdrFormat.DolbyVision => "Dolby Vision",
        HdrFormat.Hdr10 => "HDR10",
        HdrFormat.Hlg => "HLG",
        _ => "SDR",
    };

    public static bool IsHdr(HdrFormat f) => f is HdrFormat.Hdr10 or HdrFormat.Hlg or HdrFormat.DolbyVision;

    /// <summary>The container's answer if it has one, else the file name's (or Unknown).</summary>
    public static HdrFormat Detect(Stream stream, string? fileName)
    {
        HdrFormat found;
        try { found = FromContainer(stream); }
        catch (Exception e) when (e is IOException or EndOfStreamException or NotSupportedException or InvalidDataException or ArgumentException)
        {
            found = HdrFormat.Unknown;
        }
        return found != HdrFormat.Unknown ? found : FromFileName(fileName);
    }

    private static readonly Regex DvName = new(@"(^|[^a-z0-9])(dv|dovi|dolby[ ._-]?vision)([^a-z0-9]|$)", RegexOptions.CultureInvariant);
    private static readonly Regex HlgName = new(@"(^|[^a-z0-9])hlg([^a-z0-9]|$)", RegexOptions.CultureInvariant);

    /// <summary>Release names: "Title.2160p.DV.HDR.mkv", "Title.HDR10+.mkv", "Title.HLG.mkv".</summary>
    public static HdrFormat FromFileName(string? fileName)
    {
        if (string.IsNullOrEmpty(fileName)) return HdrFormat.Unknown;
        var n = Path.GetFileNameWithoutExtension(fileName).ToLowerInvariant();
        if (DvName.IsMatch(n)) return HdrFormat.DolbyVision;
        if (n.Contains("hdr")) return HdrFormat.Hdr10;
        if (HlgName.IsMatch(n)) return HdrFormat.Hlg;
        return HdrFormat.Unknown;
    }

    public static HdrFormat FromContainer(Stream s)
    {
        var head = new byte[12];
        s.Position = 0;
        var n = ReadFully(s, head);
        if (n >= 4 && BinaryPrimitives.ReadUInt32BigEndian(head) == 0x1A45DFA3) return Matroska(s);
        if (n >= 8 && Encoding.ASCII.GetString(head, 4, 4) is "ftyp" or "moov" or "mdat" or "wide" or "free") return Mp4(s);
        return HdrFormat.Unknown;
    }

    // ---------------------------------------------------------------------------------------------
    // Matroska / WebM (EBML)

    private const uint IdSegment = 0x18538067, IdTracks = 0x1654AE6B, IdTrackEntry = 0xAE, IdCluster = 0x1F43B675;
    private const uint IdTrackType = 0x83, IdVideo = 0xE0, IdColour = 0x55B0, IdTransfer = 0x55BA;
    private const uint IdBlockAdditionMapping = 0x41E4, IdBlockAddIdType = 0x41E7;
    private const uint DvcC = 0x64766343, DvvC = 0x64767643, DvwC = 0x64767743;

    private static HdrFormat Matroska(Stream s)
    {
        s.Position = 0;
        var end = s.CanSeek ? s.Length : long.MaxValue;
        while (s.Position < end && s.Position < MaxRead)
        {
            var (id, size) = ReadElementHeader(s);
            if (id == IdSegment)
            {
                var segEnd = size < 0 ? end : Math.Min(end, s.Position + size);
                while (s.Position < segEnd && s.Position < MaxRead)
                {
                    var (cid, csize) = ReadElementHeader(s);
                    if (cid == IdCluster) return HdrFormat.Unknown; // tracks come before the first cluster
                    if (csize < 0) return HdrFormat.Unknown;
                    if (cid == IdTracks)
                    {
                        if (csize > MaxRead) return HdrFormat.Unknown;
                        var tracks = new byte[csize];
                        if (ReadFully(s, tracks) < csize) throw new EndOfStreamException();
                        return MatroskaTracks(tracks);
                    }
                    s.Seek(csize, SeekOrigin.Current);
                }
                return HdrFormat.Unknown;
            }
            if (size < 0) return HdrFormat.Unknown;
            s.Seek(size, SeekOrigin.Current);
        }
        return HdrFormat.Unknown;
    }

    private static HdrFormat MatroskaTracks(byte[] tracks)
    {
        var best = HdrFormat.Unknown;
        foreach (var (id, start, length) in Children(tracks, 0, tracks.Length))
        {
            if (id != IdTrackEntry) continue;
            long type = 0;
            int? transfer = null;
            var dv = false;
            foreach (var (cid, cs, cl) in Children(tracks, start, length))
            {
                if (cid == IdTrackType) type = ReadUInt(tracks, cs, cl);
                else if (cid == IdBlockAdditionMapping)
                {
                    foreach (var (mid, ms, ml) in Children(tracks, cs, cl))
                        if (mid == IdBlockAddIdType && ReadUInt(tracks, ms, ml) is DvcC or DvvC or DvwC) dv = true;
                }
                else if (cid == IdVideo)
                {
                    foreach (var (vid, vs, vl) in Children(tracks, cs, cl))
                    {
                        if (vid != IdColour) continue;
                        foreach (var (kid, ks, kl) in Children(tracks, vs, vl))
                            if (kid == IdTransfer) transfer = (int)ReadUInt(tracks, ks, kl);
                    }
                }
            }
            if (type != 1) continue; // video tracks only
            var f = dv ? HdrFormat.DolbyVision
                : transfer == TransferPq ? HdrFormat.Hdr10
                : transfer == TransferHlg ? HdrFormat.Hlg
                : transfer != null ? HdrFormat.Sdr
                : HdrFormat.Unknown;
            if (Rank(f) > Rank(best)) best = f;
        }
        return best;
    }

    private static int Rank(HdrFormat f) => f switch
    {
        HdrFormat.DolbyVision => 4, HdrFormat.Hdr10 => 3, HdrFormat.Hlg => 2, HdrFormat.Sdr => 1, _ => 0,
    };

    /// <summary>The child elements in <paramref name="buf"/>[start, start+length): (id, data start, data length).</summary>
    private static IEnumerable<(uint Id, int Start, int Length)> Children(byte[] buf, int start, int length)
    {
        var p = start;
        var end = start + length;
        while (p < end)
        {
            if (!TryVint(buf, ref p, end, keepMarker: true, out var id)) yield break;
            if (!TryVint(buf, ref p, end, keepMarker: false, out var size) || size < 0 || p + size > end) yield break;
            yield return ((uint)id, p, (int)size);
            p += (int)size;
        }
    }

    private static bool TryVint(byte[] buf, ref int p, int end, bool keepMarker, out long value)
    {
        value = 0;
        if (p >= end) return false;
        var first = buf[p];
        var len = 1;
        while (len <= 8 && (first & (0x80 >> (len - 1))) == 0) len++;
        if (len > 8 || p + len > end) return false;
        long v = keepMarker ? first : first & (0xFF >> len);
        var allOnes = v == (0xFF >> len);
        for (var i = 1; i < len; i++)
        {
            v = (v << 8) | buf[p + i];
            if (buf[p + i] != 0xFF) allOnes = false;
        }
        p += len;
        value = !keepMarker && allOnes ? -1 : v;
        return true;
    }

    private static (uint Id, long Size) ReadElementHeader(Stream s)
    {
        var id = ReadStreamVint(s, keepMarker: true);
        var size = ReadStreamVint(s, keepMarker: false);
        return ((uint)id, size);
    }

    private static long ReadStreamVint(Stream s, bool keepMarker)
    {
        var first = s.ReadByte();
        if (first < 0) throw new EndOfStreamException();
        var len = 1;
        while (len <= 8 && (first & (0x80 >> (len - 1))) == 0) len++;
        if (len > 8) throw new InvalidDataException("Bad EBML number");
        long v = keepMarker ? first : first & (0xFF >> len);
        var allOnes = v == (0xFF >> len);
        for (var i = 1; i < len; i++)
        {
            var b = s.ReadByte();
            if (b < 0) throw new EndOfStreamException();
            v = (v << 8) | (uint)b;
            if (b != 0xFF) allOnes = false;
        }
        return !keepMarker && allOnes ? -1 : v;
    }

    private static long ReadUInt(byte[] buf, int start, int length)
    {
        long v = 0;
        for (var i = 0; i < Math.Min(length, 8); i++) v = (v << 8) | buf[start + i];
        return v;
    }

    // ---------------------------------------------------------------------------------------------
    // MP4 / MOV (ISO BMFF)

    private static readonly HashSet<string> Containers = new() { "moov", "trak", "mdia", "minf", "stbl" };
    private static readonly HashSet<string> DvEntries = new() { "dvh1", "dvhe", "dva1", "dvav", "dav1" };
    private static readonly HashSet<string> VisualEntries = new() { "hvc1", "hev1", "avc1", "avc3", "av01", "vp09", "dvh1", "dvhe", "dva1", "dvav", "dav1", "mp4v" };

    private static HdrFormat Mp4(Stream s)
    {
        s.Position = 0;
        var end = s.Length;
        var header = new byte[16];
        while (s.Position + 8 <= end)
        {
            var at = s.Position;
            if (ReadFully(s, header.AsSpan(0, 8)) < 8) break;
            long size = BinaryPrimitives.ReadUInt32BigEndian(header);
            var type = Encoding.ASCII.GetString(header, 4, 4);
            var headerLength = 8;
            if (size == 1)
            {
                if (ReadFully(s, header.AsSpan(8, 8)) < 8) break;
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8));
                headerLength = 16;
            }
            else if (size == 0) size = end - at;
            if (size < headerLength) break;
            if (type == "moov")
            {
                var bodyLength = size - headerLength;
                if (bodyLength > MaxMoov) return HdrFormat.Unknown;
                var moov = new byte[bodyLength];
                if (ReadFully(s, moov) < bodyLength) throw new EndOfStreamException();
                return Mp4Boxes(moov, 0, moov.Length);
            }
            // moov may come after mdat (no "fast start"): skip over the media data.
            s.Position = at + size;
        }
        return HdrFormat.Unknown;
    }

    private static HdrFormat Mp4Boxes(byte[] buf, int start, int length)
    {
        var best = HdrFormat.Unknown;
        foreach (var (type, bs, bl) in Boxes(buf, start, length))
        {
            HdrFormat f;
            if (Containers.Contains(type)) f = Mp4Boxes(buf, bs, bl);
            else if (type == "stsd" && bl > 8) f = Mp4Boxes(buf, bs + 8, bl - 8); // version/flags, entry count
            else if (VisualEntries.Contains(type) && bl >= 78) f = VisualEntry(type, buf, bs + 78, bl - 78);
            else continue;
            if (Rank(f) > Rank(best)) best = f;
        }
        return best;
    }

    private static HdrFormat VisualEntry(string type, byte[] buf, int start, int length)
    {
        if (DvEntries.Contains(type)) return HdrFormat.DolbyVision;
        var result = HdrFormat.Unknown;
        foreach (var (child, cs, cl) in Boxes(buf, start, length))
        {
            if (child is "dvcC" or "dvvC" or "dvwC") return HdrFormat.DolbyVision;
            if (child == "colr" && cl >= 10 && Encoding.ASCII.GetString(buf, cs, 4) == "nclx")
            {
                int transfer = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(cs + 6));
                result = transfer == TransferPq ? HdrFormat.Hdr10 : transfer == TransferHlg ? HdrFormat.Hlg : HdrFormat.Sdr;
            }
        }
        return result;
    }

    private static IEnumerable<(string Type, int Start, int Length)> Boxes(byte[] buf, int start, int length)
    {
        var p = start;
        var end = start + length;
        while (p + 8 <= end)
        {
            long size = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(p));
            var type = Encoding.ASCII.GetString(buf, p + 4, 4);
            var header = 8;
            if (size == 1 && p + 16 <= end)
            {
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(buf.AsSpan(p + 8));
                header = 16;
            }
            else if (size == 0) size = end - p;
            if (size < header || p + size > end) yield break;
            yield return (type, p + header, (int)size - header);
            p += (int)size;
        }
    }

    private static int ReadFully(Stream s, Span<byte> buf)
    {
        var total = 0;
        while (total < buf.Length)
        {
            var n = s.Read(buf[total..]);
            if (n <= 0) break;
            total += n;
        }
        return total;
    }
}
