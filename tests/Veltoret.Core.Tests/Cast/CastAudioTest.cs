using Veltoret.Core.Cast;

namespace Veltoret.Core.Tests.Cast;

public class CastAudioTest
{
    // Minimal EBML writer: element = id bytes + 8-byte size + data.
    private static byte[] El(long id, params byte[][] children)
    {
        var data = children.SelectMany(c => c).ToArray();
        var output = new List<byte>();
        var idBytes = new List<byte>();
        for (var v = id; v > 0; v >>= 8) idBytes.Add((byte)(v & 0xFF));
        idBytes.Reverse();
        output.AddRange(idBytes);
        output.Add(0x01); // 8-byte size marker
        for (var i = 6; i >= 0; i--) output.Add((byte)(((long)data.Length >> (8 * i)) & 0xFF));
        output.AddRange(data);
        return output.ToArray();
    }

    private static byte[] UInt(long id, long v) => El(id, new[] { (byte)v });
    private static byte[] Track(long number, long type) => El(0xAE, UInt(0xD7, number), UInt(0x83, type));
    private static readonly byte[] Header = El(0x1A45DFA3, UInt(0x4286, 1));
    private static byte[] Segment(params byte[][] children) => Header.Concat(El(0x18538067, children)).ToArray();

    private static CastAudio.Reader Reader(byte[] bytes) => (position, length) =>
    {
        var from = (int)Math.Min(position, bytes.Length);
        var to = (int)Math.Min(position + length, bytes.Length);
        return bytes[from..to];
    };

    private static readonly byte[] Cluster = El(0x1F43B675, UInt(0xE7, 0));

    [Fact]
    public void FindsAudioTracksBeforeTheFirstCluster()
    {
        var file = Segment(El(0x1654AE6B, Track(1, 1), Track(2, 2), Track(3, 2), Track(4, 0x11)), Cluster);
        var tracks = CastAudio.AudioTracks(Reader(file));
        Assert.Equal(new long[] { 2, 3 }, tracks.Select(t => t.Number));
        foreach (var t in tracks) Assert.Equal(2, file[t.TypeOffset]);
    }

    [Fact]
    public void FollowsTheSeekHeadToTracksStoredAfterACluster()
    {
        // SeekHead says Tracks is at (segment-relative) offset = seekHead + cluster sizes.
        static byte[] SeekHead(long position) =>
            El(0x114D9B74, El(0x4DBB, El(0x53AB, new byte[] { 0x16, 0x54, 0xAE, 0x6B }), UInt(0x53AC, position)));
        var tracks = El(0x1654AE6B, Track(1, 1), Track(2, 2), Track(3, 2));
        var headSize = SeekHead(0).Length;
        var file = Segment(SeekHead(headSize + Cluster.Length), Cluster, tracks);
        Assert.Equal(new long[] { 2, 3 }, CastAudio.AudioTracks(Reader(file)).Select(t => t.Number));
    }

    [Fact]
    public void NothingForOtherFormatsOrASingleTrack()
    {
        Assert.Empty(CastAudio.AudioTracks(Reader(Enumerable.Repeat((byte)7, 4096).ToArray())));
        var one = CastAudio.AudioTracks(Reader(Segment(El(0x1654AE6B, Track(1, 1), Track(2, 2)))));
        Assert.Empty(CastAudio.HideAllBut(one, 2));
    }

    [Fact]
    public void HidesEveryOtherAudioTrackAcrossBufferBoundaries()
    {
        var file = Segment(El(0x1654AE6B, Track(1, 1), Track(2, 2), Track(3, 2), Track(4, 2)));
        var tracks = CastAudio.AudioTracks(Reader(file));
        var patches = CastAudio.HideAllBut(tracks, keep: 3);
        Assert.Equal(2, patches.Count);
        // Stream it in odd-sized chunks, as the server does.
        var streamed = new List<byte>();
        var p = 0;
        while (p < file.Length)
        {
            var n = Math.Min(7, file.Length - p);
            var chunk = file[p..(p + n)];
            CastAudio.Apply(patches, p, chunk, n);
            streamed.AddRange(chunk);
            p += n;
        }
        var result = CastAudio.AudioTracks(Reader(streamed.ToArray()));
        Assert.Equal(new long[] { 3 }, result.Select(t => t.Number));
        Assert.Equal(file.Length, streamed.Count);
    }

    [Fact]
    public void ReadsLanguageAndCodecWhenPresent()
    {
        static byte[] Str(long id, string s) => El(id, System.Text.Encoding.ASCII.GetBytes(s));
        var file = Segment(El(0x1654AE6B,
            El(0xAE, UInt(0xD7, 1), UInt(0x83, 2), Str(0x86, "A_DTS"), Str(0x22B59C, "eng")),
            El(0xAE, UInt(0xD7, 2), UInt(0x83, 2), Str(0x86, "A_AC3"), Str(0x22B59C, "fre"))));
        var tracks = CastAudio.AudioTracks(Reader(file));
        Assert.Equal("eng", tracks[0].Language);
        Assert.Equal("A_DTS", tracks[0].CodecId);
        Assert.Equal("fre", tracks[1].Language);
        Assert.Equal("French", LanguageNames.Name("fre"));
        Assert.Equal("fr", LanguageNames.ToTwoLetter("fre"));
        Assert.Equal("DTS", CastMediaFactory.CodecName("A_DTS"));
    }

    [Fact]
    public void StreamReaderReadsWindows()
    {
        var file = Segment(El(0x1654AE6B, Track(1, 1), Track(2, 2), Track(3, 2)));
        using var ms = new MemoryStream(file);
        Assert.Equal(new long[] { 2, 3 }, CastAudio.AudioTracks(CastAudio.StreamReader(ms)).Select(t => t.Number));
    }
}
