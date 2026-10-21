using Veltoret.Core.Player;

namespace Veltoret.Core.Tests.Player;

/// <summary>Port of Android MediaFormatsDeviceTest plus the Windows-specific codec and language mapping.</summary>
public class MediaFormatsTests
{
    [Fact]
    public void ReleaseGroupLabelsAreHidden()
    {
        Assert.Null(MediaFormats.CleanLabel("ReleaseSite.ai.in"));
        Assert.Null(MediaFormats.CleanLabel("www.example.com"));
        Assert.Null(MediaFormats.CleanLabel("Encoded by x@y"));
        Assert.Equal("SDH", MediaFormats.CleanLabel("SDH"));
        Assert.Equal("Director's Commentary", MediaFormats.CleanLabel("Director's Commentary"));
        Assert.Equal("Dub.Intl", MediaFormats.CleanLabel("Dub.Intl")); // ".in" inside a word is not a domain
        Assert.Null(MediaFormats.CleanLabel("ReleaseSite.at"));
        Assert.Null(MediaFormats.CleanLabel("ExampleRips.town"));
        Assert.Equal("DTS-HD.MA 5.1", MediaFormats.CleanLabel("DTS-HD.MA 5.1"));
        Assert.Equal("H.264", MediaFormats.CleanLabel("H.264"));
        Assert.Null(MediaFormats.CleanLabel("   "));
        Assert.Null(MediaFormats.CleanLabel(null));
        Assert.Equal("SDH", MediaFormats.CleanLabel("  SDH "));
    }

    [Fact]
    public void DuplicateLanguagesAreNumbered()
    {
        var names = new Dictionary<string, string> { ["hi"] = "Hindi", ["en"] = "English" };
        var titles = MediaFormats.TrackTitles(
            new (string?, string?)[] { ("hi", "ReleaseSite.ai.in"), ("hi", null), ("en", null), (null, "Commentary"), (null, null) },
            "Subtitle", l => l == null ? null : names.GetValueOrDefault(l));
        Assert.Equal(new[] { "Hindi 1", "Hindi 2", "English", "Commentary", "Subtitle 5" }, titles);
    }

    [Theory]
    [InlineData("en", "English")]
    [InlineData("eng", "English")]
    [InlineData("hin", "Hindi")]
    [InlineData("fre", "French")]
    [InlineData("fra", "French")]
    [InlineData("ger", "German")]
    [InlineData("deu", "German")]
    [InlineData("en-US", "English")]
    [InlineData("xx", "XX")]
    public void LanguageNames(string code, string expected) => Assert.Equal(expected, MediaFormats.LanguageName(code));

    [Fact]
    public void UndeterminedLanguageHasNoName()
    {
        Assert.Null(MediaFormats.LanguageName("und"));
        Assert.Null(MediaFormats.LanguageName(""));
        Assert.Null(MediaFormats.LanguageName(null));
    }

    [Theory]
    [InlineData("eng", "en")]
    [InlineData("EN", "en")]
    [InlineData("en-US", "en")]
    [InlineData("fre", "fr")]
    [InlineData("hin", "hi")]
    [InlineData("chi", "zh")]
    public void LanguagesNormalise(string code, string expected) => Assert.Equal(expected, MediaFormats.NormalizeLanguage(code));

    [Fact]
    public void UndNormalisesToNull() => Assert.Null(MediaFormats.NormalizeLanguage("und"));

    [Fact]
    public void FourCcs()
    {
        Assert.Equal("h264", MediaFormats.FourCC('h' | '2' << 8 | '6' << 16 | (uint)'4' << 24));
        Assert.Equal("H.264", MediaFormats.VideoCodec("h264"));
        Assert.Equal("HEVC", MediaFormats.VideoCodec("hevc"));
        Assert.Equal("Dolby Digital", MediaFormats.AudioCodec("a52 "));
        Assert.Equal("Dolby Digital+", MediaFormats.AudioCodec("eac3"));
        Assert.Equal("DTS", MediaFormats.AudioCodec("dts "));
        Assert.Equal("Dolby TrueHD", MediaFormats.AudioCodec("mlp "));
        Assert.Equal("AAC", MediaFormats.AudioCodec("mp4a"));
        Assert.Equal("MP3", MediaFormats.AudioCodec("mpga"));
        Assert.Equal("PCM", MediaFormats.AudioCodec("s16l"));
        Assert.Equal("XYZW", MediaFormats.AudioCodec("xyzw"));
        Assert.Equal("ASS", MediaFormats.SubtitleFormat("ssa "));
        Assert.Equal("SRT", MediaFormats.SubtitleFormat("subt"));
        Assert.Equal("PGS", MediaFormats.SubtitleFormat("pgs "));
        Assert.Null(MediaFormats.SubtitleFormat("abcd"));
    }

    [Fact]
    public void InfoValues()
    {
        Assert.Null(MediaFormats.Channels(0));
        Assert.Equal("Mono", MediaFormats.Channels(1));
        Assert.Equal("Stereo", MediaFormats.Channels(2));
        Assert.Equal("5.1", MediaFormats.Channels(6));
        Assert.Equal("7.1", MediaFormats.Channels(8));
        Assert.Equal("3 ch", MediaFormats.Channels(3));
        Assert.Equal("3840×2160 · 4K", MediaFormats.Resolution(3840, 2160));
        Assert.Equal("1920×800 · 1080p", MediaFormats.Resolution(1920, 800));
        Assert.Equal("1280×720 · 720p", MediaFormats.Resolution(1280, 720));
        Assert.Equal("640×480 · SD", MediaFormats.Resolution(640, 480));
        Assert.Equal("24.0 fps", MediaFormats.FrameRate(23.976));
        Assert.Equal("30.0 fps", MediaFormats.FrameRate(29.97));
        Assert.Equal("120 fps", MediaFormats.FrameRate(120));
        Assert.Equal("5.00 fps", MediaFormats.FrameRate(5));
        Assert.Equal("12.3 Mbps", MediaFormats.Bitrate(12_300_000));
        Assert.Equal("640 kbps", MediaFormats.Bitrate(640_500));
        Assert.Equal("48.0 kHz", MediaFormats.SampleRate(48000));
        Assert.Equal("44.1 kHz", MediaFormats.SampleRate(44100));
    }
}
