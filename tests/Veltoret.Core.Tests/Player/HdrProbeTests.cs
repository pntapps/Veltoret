using System.Buffers.Binary;
using System.Text;
using Veltoret.Core.Player;
using Xunit;

namespace Veltoret.Core.Tests.Player;

public class HdrProbeTests
{
    // ---- Matroska builders (EBML: id bytes, 8-byte size, data) ----

    private static byte[] El(uint id, params byte[][] children) => El(id, children.SelectMany(c => c).ToArray());

    private static byte[] El(uint id, byte[] data)
    {
        var idBytes = BitConverter.GetBytes(id).Reverse().SkipWhile(b => b == 0).ToArray();
        var size = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(size, (ulong)(uint)data.Length | 0x0100000000000000UL);
        return idBytes.Concat(size).Concat(data).ToArray();
    }

    private static byte[] UInt(uint id, uint value) => El(id, BitConverter.GetBytes(value).Reverse().ToArray());

    private static byte[] UnknownSize(uint id, byte[] data)
    {
        var idBytes = BitConverter.GetBytes(id).Reverse().SkipWhile(b => b == 0).ToArray();
        return idBytes.Concat(new byte[] { 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }).Concat(data).ToArray();
    }

    private static byte[] Mkv(byte[] trackEntry, bool unknownSegment = false)
    {
        var ebml = El(0x1A45DFA3, El(0x4282, Encoding.ASCII.GetBytes("matroska")));
        var info = El(0x1549A966, UInt(0x2AD7B1, 1_000_000));
        var tracks = El(0x1654AE6B, El(0xAE, trackEntry), El(0xAE, UInt(0x83, 2))); // + an audio track
        var cluster = El(0x1F43B675, new byte[64]);
        var body = info.Concat(tracks).Concat(cluster).ToArray();
        return ebml.Concat(unknownSegment ? UnknownSize(0x18538067, body) : El(0x18538067, body)).ToArray();
    }

    private static byte[] VideoTrack(uint? transfer, bool dolbyVision = false)
    {
        var parts = new List<byte[]> { UInt(0x83, 1) };
        var video = transfer is { } t ? El(0xE0, UInt(0xB0, 3840), El(0x55B0, UInt(0x55B1, 9), UInt(0x55BA, t))) : El(0xE0, UInt(0xB0, 1920));
        parts.Add(video);
        if (dolbyVision) parts.Add(El(0x41E4, UInt(0x41E7, 0x64766343)));
        return parts.SelectMany(p => p).ToArray();
    }

    private static HdrFormat Probe(byte[] file, string? name = null) => HdrProbe.Detect(new MemoryStream(file), name);

    [Fact]
    public void MatroskaColour()
    {
        Assert.Equal(HdrFormat.Hdr10, Probe(Mkv(VideoTrack(16))));
        Assert.Equal(HdrFormat.Hlg, Probe(Mkv(VideoTrack(18))));
        Assert.Equal(HdrFormat.Sdr, Probe(Mkv(VideoTrack(1))));
        Assert.Equal(HdrFormat.DolbyVision, Probe(Mkv(VideoTrack(16, dolbyVision: true))));
        Assert.Equal(HdrFormat.Hdr10, Probe(Mkv(VideoTrack(16), unknownSegment: true)));
    }

    [Fact]
    public void HeaderWinsOverName_NameIsTheFallback()
    {
        // No colour element: the name decides.
        Assert.Equal(HdrFormat.Hdr10, Probe(Mkv(VideoTrack(null)), "Movie.2021.2160p.HDR.HEVC.mkv"));
        Assert.Equal(HdrFormat.Unknown, Probe(Mkv(VideoTrack(null)), "Movie.2021.1080p.x264.mkv"));
        // The header says SDR: believe it over a misleading name.
        Assert.Equal(HdrFormat.Sdr, Probe(Mkv(VideoTrack(1)), "Movie.HDR.mkv"));
        // Not a container we read.
        Assert.Equal(HdrFormat.DolbyVision, Probe(new byte[100], "Movie.2160p.DV.HDR.ts"));
    }

    [Fact]
    public void FileNames()
    {
        Assert.Equal(HdrFormat.DolbyVision, HdrProbe.FromFileName("Show.S01E01.2160p.DoVi.mkv"));
        Assert.Equal(HdrFormat.DolbyVision, HdrProbe.FromFileName("Movie 2023 Dolby Vision 2160p.mkv"));
        Assert.Equal(HdrFormat.Hdr10, HdrProbe.FromFileName("Movie.2023.2160p.HDR10+.mkv"));
        Assert.Equal(HdrFormat.Hlg, HdrProbe.FromFileName("Nature.2160p.HLG.mkv"));
        Assert.Equal(HdrFormat.Unknown, HdrProbe.FromFileName("Movie.2019.DVDRip.mkv"));
        Assert.Equal(HdrFormat.Unknown, HdrProbe.FromFileName(null));
    }

    // ---- MP4 builders ----

    private static byte[] Box(string type, params byte[][] children)
    {
        var body = children.SelectMany(c => c).ToArray();
        var head = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(head, (uint)(body.Length + 8));
        Encoding.ASCII.GetBytes(type).CopyTo(head, 4);
        return head.Concat(body).ToArray();
    }

    private static byte[] Colr(ushort transfer)
    {
        var b = new byte[11];
        Encoding.ASCII.GetBytes("nclx").CopyTo(b, 0);
        BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(4), 9);
        BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(6), transfer);
        BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(8), 9);
        return Box("colr", b);
    }

    private static byte[] Mp4(string entry, byte[]? extra, bool moovLast)
    {
        var sampleEntry = Box(entry, new byte[78], extra ?? Array.Empty<byte>());
        var stsd = Box("stsd", new byte[] { 0, 0, 0, 0, 0, 0, 0, 1 }, sampleEntry);
        var moov = Box("moov", Box("trak", Box("mdia", Box("minf", Box("stbl", stsd)))));
        var ftyp = Box("ftyp", Encoding.ASCII.GetBytes("isom"), new byte[4]);
        var mdat = Box("mdat", new byte[256]);
        return moovLast ? ftyp.Concat(mdat).Concat(moov).ToArray() : ftyp.Concat(moov).Concat(mdat).ToArray();
    }

    [Fact]
    public void Mp4Colour()
    {
        Assert.Equal(HdrFormat.Hdr10, Probe(Mp4("hvc1", Colr(16), moovLast: false)));
        Assert.Equal(HdrFormat.Hdr10, Probe(Mp4("hvc1", Colr(16), moovLast: true)));
        Assert.Equal(HdrFormat.Hlg, Probe(Mp4("hev1", Colr(18), moovLast: false)));
        Assert.Equal(HdrFormat.Sdr, Probe(Mp4("avc1", Colr(1), moovLast: false)));
        Assert.Equal(HdrFormat.DolbyVision, Probe(Mp4("dvh1", null, moovLast: false)));
        Assert.Equal(HdrFormat.DolbyVision, Probe(Mp4("hvc1", Box("dvcC", new byte[24]), moovLast: false)));
        Assert.Equal(HdrFormat.Unknown, Probe(Mp4("hvc1", null, moovLast: false)));
    }

    [Fact]
    public void Labels()
    {
        Assert.Equal("HDR10", HdrProbe.Label(HdrFormat.Hdr10));
        Assert.Equal("SDR", HdrProbe.Label(HdrFormat.Unknown));
        Assert.True(HdrProbe.IsHdr(HdrFormat.Hlg));
        Assert.False(HdrProbe.IsHdr(HdrFormat.Sdr));
    }
}
