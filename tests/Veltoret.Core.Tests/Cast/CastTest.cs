using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Veltoret.Core.Cast;

namespace Veltoret.Core.Tests.Cast;

public class CastTest
{
    [Fact]
    public void RangesAgainstAKnownSize()
    {
        Assert.Equal((0L, 999L), CastServer.ParseRange("bytes=0-", 1000));
        Assert.Equal((500L, 999L), CastServer.ParseRange("bytes=500-", 1000));
        Assert.Equal((100L, 199L), CastServer.ParseRange("bytes=100-199", 1000));
        // An end past the file is clipped; the last N bytes work too.
        Assert.Equal((900L, 999L), CastServer.ParseRange("bytes=900-5000", 1000));
        Assert.Equal((800L, 999L), CastServer.ParseRange("bytes=-200", 1000));
    }

    [Fact]
    public void UnsatisfiableRanges()
    {
        Assert.Null(CastServer.ParseRange("bytes=1000-", 1000));
        Assert.Null(CastServer.ParseRange("bytes=300-200", 1000));
        Assert.Null(CastServer.ParseRange("items=0-1", 1000));
        Assert.Null(CastServer.ParseRange("bytes=abc-", 1000));
    }

    [Fact]
    public void OpenRangeOnUnknownSize()
    {
        Assert.Equal((500L, CastServer.OpenEnd), CastServer.ParseRange("bytes=500-", null));
        Assert.Equal((10L, 20L), CastServer.ParseRange("bytes=10-20", null));
    }

    [Fact]
    public void OnlyHomeNetworkClients()
    {
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("192.168.0.125")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("10.0.0.7")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("127.0.0.1")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("fd12:3456::1")));
        Assert.False(CastServer.IsHomeNetwork(IPAddress.Parse("8.8.8.8")));
        Assert.False(CastServer.IsHomeNetwork(IPAddress.Parse("2001:4860:4860::8888")));
        // Extra: IPv4-mapped IPv6, 172.16/12 edges, link-local.
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("::ffff:192.168.1.2")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("172.31.0.1")));
        Assert.False(CastServer.IsHomeNetwork(IPAddress.Parse("172.32.0.1")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("169.254.10.1")));
        Assert.True(CastServer.IsHomeNetwork(IPAddress.Parse("fe80::1")));
    }

    [Fact]
    public void WebVttFromCues()
    {
        var vtt = CastSubtitles.ToVtt(new[]
        {
            new CastSubtitles.Line(1_000_000, 2_500_000, "Hello"),
            new CastSubtitles.Line(3_723_045_000, 3_725_000_000, "Two\n\nlines --> here"),
        });
        Assert.Equal("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n01:02:03.045 --> 01:02:05.000\nTwo\nlines -> here\n\n", vtt);
    }

    [Fact]
    public void WebVttAppliesTheSyncOffset()
    {
        var lines = new[] { new CastSubtitles.Line(1_000_000, 2_000_000, "Early"), new CastSubtitles.Line(5_000_000, 6_000_000, "Later") };
        var vtt = CastSubtitles.ToVtt(lines, offsetUs: -1_500_000);
        Assert.Equal("WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nEarly\n\n00:00:03.500 --> 00:00:04.500\nLater\n\n", vtt);
        // Cues that end before the start of the video are dropped.
        Assert.Equal("WEBVTT\n\n", CastSubtitles.ToVtt(new[] { new CastSubtitles.Line(0, 1_000_000, "Gone") }, offsetUs: -2_000_000));
    }

    [Fact]
    public void ParsesSrtAndAss()
    {
        var srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i>\r\nthere\r\n\r\n2\r\n00:01:00,250 --> 00:01:01,000\r\nBye\r\n";
        var cues = CastSubtitles.Parse(srt, "Movie.en.srt");
        Assert.Equal(2, cues.Count);
        Assert.Equal(new CastSubtitles.Line(1_000_000, 2_500_000, "Hello\nthere"), cues[0]);
        Assert.Equal(60_250_000, cues[1].StartUs);

        var ass = "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" +
                  "Dialogue: 0,0:00:01.50,0:00:03.04,Default,,0,0,0,,{\\i1}One, two\\NThree\n";
        var a = CastSubtitles.Parse(ass, "x.ass");
        Assert.Single(a);
        Assert.Equal(1_500_000, a[0].StartUs);
        Assert.Equal(3_040_000, a[0].EndUs);
        Assert.Equal("One, two\nThree", a[0].Text);
        Assert.Equal("en", CastSubtitles.LanguageFromName("Movie.en.srt"));
        Assert.Equal("eng", CastSubtitles.LanguageFromName("Movie.eng.forced.srt"));
        Assert.Null(CastSubtitles.LanguageFromName("Movie.srt"));
    }

    [Fact]
    public void MimeTypesAndWarnings()
    {
        Assert.Equal("video/mp4", CastFormats.MimeFor("a.MP4"));
        Assert.Equal("video/mp2t", CastFormats.MimeFor("a.m2ts"));
        Assert.Equal("video/x-msvideo", CastFormats.MimeFor("a.avi"));
        Assert.Equal("video/webm", CastFormats.MimeFor("a.webm"));
        Assert.Equal("video/x-matroska", CastFormats.MimeFor("Heat (1995)"));
        Assert.Contains("Dolby TrueHD", CastFormats.AudioWarning(null, "Movie.2160p.TrueHD.Atmos.mkv"));
        Assert.Contains("DTS", CastFormats.AudioWarning(null, "Movie.DTS-HD.MA.mkv"));
        Assert.Null(CastFormats.AudioWarning("AC3", "Movie.DTS.mkv"));
        Assert.Equal("This video's audio is DTS, which most Chromecasts can't play, so there may be no sound. Another version of it may work.",
            CastFormats.AudioWarning("DTS", null));
    }

    [Fact]
    public void JavaHashMatchesJava()
    {
        // "abc".hashCode() == 96354; "hello".hashCode() == 99162322; negative hashes wrap to unsigned.
        Assert.Equal(96354u, CastFormats.JavaHash("abc"));
        Assert.Equal(99162322u, CastFormats.JavaHash("hello"));
        // Famous: "polygenelubricants".hashCode() == Integer.MIN_VALUE.
        Assert.Equal(2147483648u, CastFormats.JavaHash("polygenelubricants"));
        Assert.Equal(233u, CastFormats.JavaHash("é"));
    }

    [Fact]
    public void CastMessageRoundTrips()
    {
        var m = new CastMessage("sender-0", "receiver-0", CastMessage.NsHeartbeat, "{\"type\":\"PING\"}");
        var frame = m.Frame();
        Assert.Equal(frame.Length - 4, (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3]);
        // Field order and tags: 08 00 12 .. 1A .. 22 .. 28 00 32 ..
        Assert.Equal(0x08, frame[4]);
        Assert.Equal(0x00, frame[5]);
        Assert.Equal(0x12, frame[6]);
        var back = CastMessage.Decode(frame.AsSpan(4));
        Assert.Equal(m.SourceId, back.SourceId);
        Assert.Equal(m.DestinationId, back.DestinationId);
        Assert.Equal(m.Namespace, back.Namespace);
        Assert.Equal(m.PayloadUtf8, back.PayloadUtf8);
    }

    [Fact]
    public void LoadRequestMatchesTheCastSdk()
    {
        var media = new CastMedia
        {
            FileId = "f", Title = "Heat", Subtitle = "S01E02 · Name", IsEpisode = true,
            PosterUrl = "https://image.tmdb.org/t/p/w500/p.jpg", BackdropUrl = "https://image.tmdb.org/t/p/w780/b.jpg",
        };
        var json = CastLoadRequest.Build(7, "sess", "http://192.168.1.5:5000/t/v1a2", "video/x-matroska", media, 754_000,
            new[] { new CastLoadRequest.SubtitleTrack("English", "http://192.168.1.5:5000/t/s0-1", "en"), new CastLoadRequest.SubtitleTrack("Other", "http://x/s1", null) },
            activeSubtitleIndex: 1);
        using var doc = JsonDocument.Parse(json.ToJsonString());
        var r = doc.RootElement;
        Assert.Equal("LOAD", r.GetProperty("type").GetString());
        Assert.Equal(7, r.GetProperty("requestId").GetInt32());
        Assert.Equal("sess", r.GetProperty("sessionId").GetString());
        Assert.True(r.GetProperty("autoplay").GetBoolean());
        Assert.Equal(754.0, r.GetProperty("currentTime").GetDouble());
        Assert.Equal(2, r.GetProperty("activeTrackIds")[0].GetInt32());
        var m = r.GetProperty("media");
        Assert.Equal("BUFFERED", m.GetProperty("streamType").GetString());
        Assert.Equal(2, m.GetProperty("metadata").GetProperty("metadataType").GetInt32());
        Assert.Equal(2, m.GetProperty("metadata").GetProperty("images").GetArrayLength());
        var t0 = m.GetProperty("tracks")[0];
        Assert.Equal(1, t0.GetProperty("trackId").GetInt32());
        Assert.Equal("TEXT", t0.GetProperty("type").GetString());
        Assert.Equal("SUBTITLES", t0.GetProperty("subtype").GetString());
        Assert.Equal("text/vtt", t0.GetProperty("trackContentType").GetString());
        Assert.Equal("en", t0.GetProperty("language").GetString());
        Assert.False(m.GetProperty("tracks")[1].TryGetProperty("language", out _));
        Assert.Equal("#00000099", m.GetProperty("textTrackStyle").GetProperty("backgroundColor").GetString());
        Assert.Equal("DROP_SHADOW", m.GetProperty("textTrackStyle").GetProperty("edgeType").GetString());
    }

    // ---- The server over a real loopback socket --------------------------------------------------

    private static async Task<(string Head, byte[] Body)> Get(string url, string? range = null, string method = "GET")
    {
        var uri = new Uri(url);
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(uri.Host, uri.Port);
        var s = tcp.GetStream();
        var req = $"{method} {uri.AbsolutePath} HTTP/1.1\r\nHost: {uri.Authority}\r\n" + (range != null ? $"Range: {range}\r\n" : "") + "Connection: close\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(req));
        using var ms = new MemoryStream();
        await s.CopyToAsync(ms);
        var all = ms.ToArray();
        var text = Encoding.Latin1.GetString(all);
        var split = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        return (text[..split], all[(split + 4)..]);
    }

    [Fact]
    public async Task ServesRangesTextAndRefusesBadTokens()
    {
        var data = Enumerable.Range(0, 1000).Select(i => (byte)i).ToArray();
        using var server = new CastServer((_, _, _) => Task.FromResult<Stream>(new MemoryStream(data)));
        server.Start(IPAddress.Loopback);
        var patches = new Dictionary<long, byte> { [105] = 0xEE };
        var url = server.Media("v1a0", "device", "x", "video/x-matroska", 1000, patches);
        Assert.Matches("^http://127\\.0\\.0\\.1:[0-9]+/[0-9a-f]{32}/v1a0$", url);

        var (head, body) = await Get(url, "bytes=100-199");
        Assert.StartsWith("HTTP/1.1 206 Partial Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range, Content-Type\r\n" +
                          "Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\nConnection: close\r\n" +
                          "Content-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Length: 100\r\nContent-Range: bytes 100-199/1000", head);
        Assert.Equal(100, body.Length);
        Assert.Equal(100, body[0]);
        Assert.Equal(0xEE, body[5]);

        (head, body) = await Get(url);
        Assert.StartsWith("HTTP/1.1 200 OK", head);
        Assert.DoesNotContain("\r\nContent-Range:", head);
        Assert.Equal(1000, body.Length);

        (head, _) = await Get(url, "bytes=1000-");
        Assert.StartsWith("HTTP/1.1 416 Range Not Satisfiable", head);
        Assert.Contains("Content-Range: bytes */1000", head);

        (head, body) = await Get(url, method: "HEAD");
        Assert.Contains("Content-Length: 1000", head);
        Assert.Empty(body);

        var vtt = server.Text("s0-1", "WEBVTT\n\n");
        (head, body) = await Get(vtt);
        Assert.Contains("Content-Type: text/vtt; charset=utf-8", head);
        Assert.Equal("WEBVTT\n\n", Encoding.UTF8.GetString(body));

        (head, body) = await Get(url.Replace(server.Token, new string('0', 32)));
        Assert.StartsWith("HTTP/1.1 404 Not Found", head);
        Assert.EndsWith("Content-Type: text/plain\r\nContent-Length: 9", head);
        Assert.Equal("Not found", Encoding.UTF8.GetString(body));

        (head, body) = await Get(url, method: "OPTIONS");
        Assert.StartsWith("HTTP/1.1 204 No Content", head);
        Assert.Empty(body);
    }
}
