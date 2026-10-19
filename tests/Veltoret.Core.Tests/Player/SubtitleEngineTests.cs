using System.Text;
using Veltoret.Core.Player;

namespace Veltoret.Core.Tests.Player;

/// <summary>Port of Android SubtitleEngineDeviceTest.</summary>
public class SubtitleEngineTests
{
    static SubtitleEngineTests() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    private const string Srt = "1\n00:00:01,000 --> 00:00:03,000\nCafé au lait, señor.\n\n2\n00:00:04,000 --> 00:00:06,500\n<i>Second line</i>";

    private static string Text(List<SubtitleCue> cues, long ms, long offsetMs = 0) =>
        string.Join(" ", SubtitleEngine.ActiveAt(cues, ms, offsetMs).Select(c => c.Text));

    [Fact]
    public void ParsesUtf8Srt()
    {
        var cues = SubtitleEngine.Parse(Encoding.UTF8.GetBytes(Srt), "movie.srt");
        Assert.Equal(2, cues.Count);
        Assert.Equal("Café au lait, señor.", Text(cues, 2_000));
        Assert.Equal("", Text(cues, 3_500));
        Assert.Equal("Second line", Text(cues, 5_000));
    }

    [Fact]
    public void LegacyWindowsEncodingIsTranscoded()
    {
        var bytes = Encoding.GetEncoding(1252).GetBytes(Srt);
        Assert.Equal("Café au lait, señor.", Text(SubtitleEngine.Parse(bytes, "movie.srt"), 2_000));
        var normalized = SubtitleEngine.NormalizeText(bytes);
        Assert.Contains("Café", new UTF8Encoding(false, true).GetString(normalized));
    }

    [Fact]
    public void LegacyCyrillicAndArabicAreDetected()
    {
        const string ruText = "Привет, как дела? Это проверка субтитров.";
        var ru = "1\n00:00:01,000 --> 00:00:03,000\n" + ruText + "\n";
        Assert.Equal(ruText, Text(SubtitleEngine.Parse(Encoding.GetEncoding(1251).GetBytes(ru), "a.srt"), 2_000));

        const string arText = "مرحبا بكم في هذا الفيلم الجميل";
        var ar = "1\n00:00:01,000 --> 00:00:03,000\n" + arText + "\n";
        Assert.Equal(arText, Text(SubtitleEngine.Parse(Encoding.GetEncoding(1256).GetBytes(ar), "a.srt"), 2_000));
    }

    [Fact]
    public void BomsAreKept()
    {
        var utf8Bom = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes("x")).ToArray();
        Assert.Same(utf8Bom, SubtitleEngine.NormalizeText(utf8Bom));
        var utf16 = Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes(Srt)).ToArray();
        Assert.Same(utf16, SubtitleEngine.NormalizeText(utf16));
        Assert.Equal("Second line", Text(SubtitleEngine.Parse(utf16, "a.srt"), 5_000));
    }

    [Fact]
    public void Utf8OutputHasBom()
    {
        var bytes = SubtitleEngine.ToUtf8WithBom(Encoding.GetEncoding(1252).GetBytes(Srt));
        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, bytes.Take(3));
        Assert.Contains("señor", Encoding.UTF8.GetString(bytes));
    }

    [Fact]
    public void OffsetShiftsCues()
    {
        var cues = SubtitleEngine.Parse(Encoding.UTF8.GetBytes(Srt), "movie.srt");
        // +2 s: the first line now shows between 3 s and 5 s.
        Assert.Equal("", Text(cues, 2_000, 2_000));
        Assert.Equal("Café au lait, señor.", Text(cues, 4_000, 2_000));
        // −1 s: the second line shows from 3 s.
        Assert.Equal("Second line", Text(cues, 3_200, -1_000));
    }

    [Fact]
    public void ParsesWebVttAndAss()
    {
        const string vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n";
        Assert.Equal("Hello", Text(SubtitleEngine.Parse(Encoding.UTF8.GetBytes(vtt), "a.vtt"), 1_500));

        const string shortVtt = "WEBVTT\n\nintro\n00:01.000 --> 00:02.500 align:start\nShort clock\n";
        Assert.Equal("Short clock", Text(SubtitleEngine.Parse(Encoding.UTF8.GetBytes(shortVtt), "a.vtt"), 2_000));

        const string ass = """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\i1}Anime line, with a comma
            """;
        Assert.Contains("Anime line, with a comma", Text(SubtitleEngine.Parse(Encoding.UTF8.GetBytes(ass), "ep.ass"), 1_500));
    }

    [Fact]
    public void ParsesTtml()
    {
        const string ttml = """
            <?xml version="1.0" encoding="utf-8"?>
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
              <p begin="00:00:01.000" end="00:00:02.000">One<br/>Two</p>
              <p begin="3s" dur="1s">Three</p>
            </div></body></tt>
            """;
        var cues = SubtitleEngine.Parse(Encoding.UTF8.GetBytes(ttml), "a.dfxp");
        Assert.Equal("One\nTwo", Text(cues, 1_500));
        Assert.Equal("Three", Text(cues, 3_500));
        Assert.Equal("", Text(cues, 4_500));
    }

    [Fact]
    public void OpenEndsCloseAtNextCueOrAfterFiveSeconds()
    {
        const string ttml = """<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s">A</p><p begin="4s">B</p></div></body></tt>""";
        var cues = SubtitleEngine.Parse(Encoding.UTF8.GetBytes(ttml), "a.ttml");
        Assert.Equal(4_000, cues[0].EndMs);
        Assert.Equal(9_000, cues[1].EndMs);
    }

    [Fact]
    public void EmptyFileHasNoCues() => Assert.Empty(SubtitleEngine.Parse(Encoding.UTF8.GetBytes("nothing here"), "a.srt"));

    [Fact]
    public void TooLargeIsRejected()
    {
        var e = Assert.Throws<SubtitleException>(() => SubtitleEngine.Parse(new byte[SubtitleEngine.MaxBytes + 1], "a.srt"));
        Assert.Equal("That file is too large to be a subtitle", e.Message);
    }

    [Fact]
    public async Task ReadLimitedStopsAtTheLimit()
    {
        using var big = new MemoryStream(new byte[SubtitleEngine.MaxBytes + 10]);
        await Assert.ThrowsAsync<SubtitleException>(() => SubtitleEngine.ReadLimited(big));
        using var small = new MemoryStream(new byte[100]);
        Assert.Equal(100, (await SubtitleEngine.ReadLimited(small)).Length);
    }

    [Fact]
    public void OverlappingCuesShowTogether()
    {
        const string srt = "1\n00:00:01,000 --> 00:00:05,000\nA\n\n2\n00:00:02,000 --> 00:00:03,000\nB\n";
        Assert.Equal("A B", Text(SubtitleEngine.Parse(Encoding.UTF8.GetBytes(srt), "a.srt"), 2_500));
    }
}
