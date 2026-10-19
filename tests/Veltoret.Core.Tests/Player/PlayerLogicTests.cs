using Veltoret.Core.Data;
using Veltoret.Core.Player;

namespace Veltoret.Core.Tests.Player;

public class SidecarTests
{
    private static List<SidecarMatch<string>> M(string video, params string[] names) => Sidecars.Match(video, names, n => n);

    [Fact]
    public void LanguageFromTheName()
    {
        var m = Assert.Single(M("Movie.mkv", "Movie.en.srt"));
        Assert.Equal("en", m.Language);
    }

    [Fact]
    public void PlainNameHasNoLanguage() => Assert.Null(Assert.Single(M("Movie.mkv", "Movie.srt")).Language);

    [Fact]
    public void ForcedTagIsNotALanguage() => Assert.Null(Assert.Single(M("Movie.mkv", "Movie.forced.en.srt")).Language);

    [Fact]
    public void CaseInsensitiveAndOthersIgnored()
    {
        var m = M("The.Show.S01E02.mkv", "the.show.s01e02_ENG.ass", "The.Show.S01E03.srt", "The.Show.S01E02.nfo");
        var only = Assert.Single(m);
        Assert.Equal("eng", only.Language);
    }

    [Fact]
    public void ThreeLetterAndDigits()
    {
        Assert.Equal("hin", Assert.Single(M("A.mp4", "A - hin.srt")).Language);
        Assert.Null(Assert.Single(M("A.mp4", "A.e1.srt")).Language);
    }
}

public class EpisodeNavTests
{
    private static MediaFileEntity Ep(int s, int e, string account = "a@x", int? end = null) => new()
    {
        DriveId = $"{account}-{s}-{e}", AccountEmail = account, ShowId = 7, Season = s, Episode = e, EpisodeEnd = end,
        Kind = MediaKind.EPISODE,
    };

    [Fact]
    public void NextAndPrevious()
    {
        var files = new[] { Ep(1, 1), Ep(1, 2), Ep(1, 3), Ep(2, 1), Ep(0, 1) };
        Assert.Equal(Ep(1, 3).DriveId, EpisodeNav.Next(files[1], files, true)!.DriveId);
        Assert.Equal(Ep(2, 1).DriveId, EpisodeNav.Next(files[2], files, true)!.DriveId);
        Assert.Null(EpisodeNav.Next(files[3], files, true));
        Assert.Equal(Ep(1, 2).DriveId, EpisodeNav.Previous(files[2], files, true)!.DriveId);
        Assert.Null(EpisodeNav.Previous(files[0], files, true));
        Assert.Equal(Ep(1, 3).DriveId, EpisodeNav.Previous(files[3], files, true)!.DriveId);
    }

    [Fact]
    public void MultiEpisodeFilesSkipTheirRange()
    {
        var double12 = Ep(1, 1, end: 2);
        var files = new[] { double12, Ep(1, 2), Ep(1, 3) };
        Assert.Equal(Ep(1, 3).DriveId, EpisodeNav.Next(double12, files, true)!.DriveId);
        Assert.Equal(Ep(1, 2).DriveId, EpisodeNav.Previous(files[2], files, true)!.DriveId);
        Assert.Equal(double12.DriveId, EpisodeNav.Previous(files[2], new[] { double12, files[2] }, true)!.DriveId);
    }

    [Fact]
    public void SameAccountFirstAndOfflineDeviceOnly()
    {
        var files = new[] { Ep(1, 1), Ep(1, 2, "device"), Ep(1, 2), Ep(1, 3, "b@x") };
        Assert.Equal("a@x", EpisodeNav.Next(files[0], files, true)!.AccountEmail);
        Assert.Equal("device", EpisodeNav.Next(files[0], files, false)!.AccountEmail);
        Assert.Null(EpisodeNav.Next(files[1], files, false));
    }

    [Fact]
    public void EpisodeListPutsSpecialsLast()
    {
        var list = EpisodeNav.EpisodeList(new[] { Ep(0, 1), Ep(2, 1), Ep(1, 2), Ep(1, 1), Ep(1, 1, "b@x") });
        Assert.Equal(new[] { (1, 1), (1, 2), (2, 1), (0, 1) }, list.Select(f => (f.Season!.Value, f.Episode!.Value)));
    }
}

public class PlayerPrefsTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"veltoret-prefs-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void TrackMemoryRoundTrips()
    {
        var prefs = new PlayerPrefsStore(_path);
        Assert.Null(prefs.TrackMemory("f1"));
        prefs.UpdateTrackMemory("f1", m => m with { AudioIndex = 1, AudioLanguage = "hi", SubtitleOffsetMs = -300 });
        prefs.UpdateTrackMemory("f1", m => m with
        {
            SubtitleMode = TrackMemory.SubExternal, ExternalSource = "side:x", ExternalName = "Eng\u001Flish",
        });
        var reloaded = new PlayerPrefsStore(_path).TrackMemory("f1")!;
        Assert.Equal(1, reloaded.AudioIndex);
        Assert.Equal("hi", reloaded.AudioLanguage);
        Assert.Equal(TrackMemory.SubExternal, reloaded.SubtitleMode);
        Assert.Null(reloaded.SubtitleIndex);
        Assert.Equal("side:x", reloaded.ExternalSource);
        Assert.Equal("Eng lish", reloaded.ExternalName);
        Assert.Equal(-300, reloaded.SubtitleOffsetMs);
    }

    [Fact]
    public void AndroidFormatDecodes()
    {
        var m = TrackMemory.Decode("2\u001Fen\u001Fembedded\u001F0\u001Ffr\u001F\u001F\u001F0");
        Assert.Equal(2, m.AudioIndex);
        Assert.Equal("embedded", m.SubtitleMode);
        Assert.Equal(0, m.SubtitleIndex);
        Assert.Equal("fr", m.SubtitleLanguage);
        Assert.Null(m.ExternalSource);
        Assert.Equal(0, m.SubtitleOffsetMs);
    }

    [Fact]
    public void ShowLanguages()
    {
        var prefs = new PlayerPrefsStore(_path);
        prefs.SetAudioLanguage(5, "");
        Assert.Null(prefs.AudioLanguage(5));
        prefs.SetAudioLanguage(5, "ja");
        prefs.SetSubtitleLanguage(5, null);
        Assert.Equal("ja", prefs.AudioLanguage(5));
        Assert.Equal("off", prefs.SubtitleLanguage(5));
        prefs.SetSubtitleLanguage(null, "en");
        Assert.Null(prefs.SubtitleLanguage(null));
        Assert.Equal("Fit", prefs.ResizeMode);
        prefs.ResizeMode = "Fill";
        Assert.Equal("Fill", new PlayerPrefsStore(_path).ResizeMode);
    }
}

public class PlayerFormatTests
{
    [Fact]
    public void Clock()
    {
        Assert.Equal("4:05", PlayerFormat.Clock(245_000));
        Assert.Equal("1:02:09", PlayerFormat.Clock(3_729_000));
        Assert.Equal("0:00", PlayerFormat.Clock(-5));
    }

    [Fact]
    public void Labels()
    {
        Assert.Equal("Normal", PlayerFormat.SpeedOption(1f));
        Assert.Equal("2×", PlayerFormat.SpeedOption(2f));
        Assert.Equal("0.25×", PlayerFormat.SpeedOption(0.25f));
        Assert.Equal("1.5×", PlayerFormat.SpeedChip(1.5f));
        Assert.Equal("Speed", PlayerFormat.SpeedChip(1f));
        Assert.Equal("In sync", PlayerFormat.SyncLabel(0));
        Assert.Equal("0.5 s later", PlayerFormat.SyncLabel(500));
        Assert.Equal("1.2 s earlier", PlayerFormat.SyncLabel(-1200));
        Assert.Equal("S1 · E2", PlayerFormat.EpisodeCode(1, 2));
        Assert.Equal("Special 3", PlayerFormat.EpisodeCode(0, 3));
        Assert.Equal("", PlayerFormat.EpisodeCode(null, 3));
        Assert.Equal("2h 46m", PlayerFormat.Runtime(166));
        Assert.Equal("48m", PlayerFormat.Runtime(48));
        Assert.Equal("2h", PlayerFormat.Runtime(120));
        Assert.Null(PlayerFormat.Runtime(0));
        Assert.Equal("1.4 GB", PlayerFormat.Bytes(1_503_238_554));
        Assert.Equal("700 MB", PlayerFormat.Bytes(734_003_200));
        Assert.Equal("—", PlayerFormat.Bytes(0));
        Assert.Equal("Volume 150% · Boost", PlayerFormat.Volume(150));
        Assert.Equal("Zoom 1.5×", PlayerFormat.Zoom(1.5));
    }

    [Fact]
    public void LoadingHints()
    {
        Assert.Null(PlayerFormat.LoadingHint(0, "Google Drive"));
        Assert.Equal("Loading from MyNAS…", PlayerFormat.LoadingHint(1, "MyNAS"));
        Assert.Equal("Loading…", PlayerFormat.LoadingHint(1, null));
        Assert.Equal("Slow connection, still loading…", PlayerFormat.LoadingHint(2, "Google Drive"));
        Assert.Equal("Still loading…", PlayerFormat.LoadingHint(2, null));
    }

    [Fact]
    public void SeekMath()
    {
        Assert.Equal(0, PlayerMath.SeekBy(3_000, 100_000, -10_000));
        Assert.Equal(99_500, PlayerMath.SeekBy(95_000, 100_000, 10_000));
        Assert.Equal(20_000, PlayerMath.SeekBy(10_000, 0, 10_000));
        Assert.Equal(99_000, PlayerMath.SkipForward(50_000, 100_000, 85));
        Assert.Equal(0, PlayerMath.ResumeAt(false, 9_000, false));
        Assert.Equal(60_000, PlayerMath.ResumeAt(false, 60_000, false));
        Assert.Equal(0, PlayerMath.ResumeAt(false, 60_000, true));
        Assert.Equal(0, PlayerMath.ResumeAt(true, 60_000, false));
        Assert.Equal(20, PlayerMath.AccumulateSeek(10, true, 800, 10));
        Assert.Equal(10, PlayerMath.AccumulateSeek(10, true, 1_300, 10));
        Assert.Equal(10, PlayerMath.AccumulateSeek(10, false, 100, 10));
        Assert.Equal(1.25f, PlayerMath.StepSpeed(1f, 1));
        Assert.Equal(0.25f, PlayerMath.StepSpeed(0.25f, -1));
        Assert.Equal(3f, PlayerMath.StepSpeed(3f, 1));
    }

    [Fact]
    public void PromptWindows()
    {
        Assert.True(PlayerMath.SkipIntroVisible(true, false, false, false, 5_000));
        Assert.False(PlayerMath.SkipIntroVisible(true, false, true, false, 6_000));
        Assert.False(PlayerMath.SkipIntroVisible(true, false, false, false, 180_001));
        Assert.True(PlayerMath.UpNextVisible(true, 100_000, 75_000, false, false, false));
        Assert.False(PlayerMath.UpNextVisible(true, 100_000, 60_000, false, false, false));
        Assert.False(PlayerMath.UpNextVisible(true, 100_000, 100_000, false, false, false));
        Assert.False(PlayerMath.UpNextVisible(true, 100_000, 80_000, false, false, true));
    }

    [Fact]
    public void CropGeometry()
    {
        Assert.Null(PlayerMath.CropGeometry(1920, 1080, 1600, 900, fill: true, 1, 0, 0));
        Assert.Equal("1440x1080+240+0", PlayerMath.CropGeometry(1920, 1080, 1200, 900, fill: true, 1, 0, 0));
        Assert.Equal("960x540+480+270", PlayerMath.CropGeometry(1920, 1080, 0, 0, fill: false, 2, 0, 0));
        Assert.Equal("960x540+960+540", PlayerMath.CropGeometry(1920, 1080, 0, 0, fill: false, 2, 1, 1));
    }
}
