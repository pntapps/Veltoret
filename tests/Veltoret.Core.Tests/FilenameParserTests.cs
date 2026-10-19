using Veltoret.Core.Library;

namespace Veltoret.Core.Tests;

/// <summary>Port of Android FilenameParserTest.kt.</summary>
public class FilenameParserTests
{
    private static FilenameParser.MovieGuess Movie(string name, params string[] folders) => FilenameParser.ParseMovie(name, folders);
    private static FilenameParser.EpisodeGuess? Ep(string name, params string[] folders) => FilenameParser.ParseEpisode(name, folders);

    [Fact]
    public void SceneMovie()
    {
        var m = Movie("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv");
        Assert.Equal("The Matrix", m.Title);
        Assert.Equal(1999, m.Year);
    }

    [Fact]
    public void MovieWithParenthesesYear()
    {
        var m = Movie("Dune Part Two (2024) [2160p] [HDR].mkv");
        Assert.Equal("Dune Part Two", m.Title);
        Assert.Equal(2024, m.Year);
    }

    [Fact]
    public void TitleThatIsAYear()
    {
        Assert.Equal(new FilenameParser.MovieGuess("1917", 2019), Movie("1917.2019.2160p.UHD.mkv"));
        Assert.Equal(new FilenameParser.MovieGuess("2001 A Space Odyssey", 1968), Movie("2001.A.Space.Odyssey.1968.mkv"));
    }

    [Fact]
    public void FutureNumberIsNotAYear()
    {
        var m = Movie("Blade.Runner.2049.1080p.WEB-DL.mkv");
        Assert.Equal("Blade Runner 2049", m.Title);
        Assert.Null(m.Year);
    }

    [Fact]
    public void GenericFileUsesFolder()
    {
        var m = Movie("movie.mkv", "Inception (2010)");
        Assert.Equal("Inception", m.Title);
        Assert.Equal(2010, m.Year);
    }

    [Fact]
    public void FolderSuppliesMissingYear() => Assert.Equal(1995, Movie("Heat.mkv", "Heat (1995)").Year);

    [Fact]
    public void KeepsAbbreviationDots() => Assert.Equal("Mr Robot", Ep("Mr.Robot.S01E02.720p.mkv")!.ShowTitle);

    [Fact]
    public void StandardEpisode()
    {
        var e = Ep("Breaking.Bad.S02E05.Breakage.1080p.mkv")!;
        Assert.Equal("Breaking Bad", e.ShowTitle);
        Assert.Equal(2, e.Season);
        Assert.Equal(5, e.Episode);
    }

    [Fact]
    public void ShowFolderWins()
    {
        var e = Ep("S01E01.mkv", "The Office (US) (2005)", "Season 1")!;
        Assert.Equal("The Office US", e.ShowTitle);
        Assert.Equal(2005, e.ShowYear);
        Assert.Equal(1, e.Season);
    }

    [Fact]
    public void MultiEpisode()
    {
        var e = Ep("Show.S03E01E02.mkv")!;
        Assert.Equal(1, e.Episode);
        Assert.Equal(2, e.EpisodeEnd);
    }

    [Fact]
    public void XNotation()
    {
        var e = Ep("Friends 3x07 The One.mkv")!;
        Assert.Equal(3, e.Season);
        Assert.Equal(7, e.Episode);
    }

    [Fact]
    public void AnimeStyleUsesSeasonFolder()
    {
        var e = Ep("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", "Season 2")!;
        Assert.Equal("Frieren", e.ShowTitle);
        Assert.Equal(2, e.Season);
        Assert.Equal(5, e.Episode);
    }

    [Fact]
    public void SpecialsFolder()
    {
        var e = Ep("Episode 3.mkv", "Doctor Who", "Specials")!;
        Assert.Equal(0, e.Season);
        Assert.Equal(3, e.Episode);
    }

    [Fact]
    public void NoEpisodeNumber() => Assert.Null(Ep("Behind the scenes.mkv"));

    [Fact]
    public void SeasonTagInShowFolderIsDropped()
    {
        var e = Ep("Below.S01E03.480p.x264.mkv", "Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.at", "480p x264")!;
        Assert.Equal("Below", e.ShowTitle);
        Assert.Equal(1, e.Season);
        Assert.Equal(3, e.Episode);
        Assert.Equal("Overcompensating", Ep("E05.mkv", "Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")!.ShowTitle);
    }

    [Fact]
    public void SeasonFromShowFolderTag()
    {
        var e = Ep("Episode 4.mkv", "Show Name S02 720p")!;
        Assert.Equal("Show Name", e.ShowTitle);
        Assert.Equal(2, e.Season);
    }

    [Fact]
    public void SeasonRangesAndCompleteInShowFolder()
    {
        Assert.Equal("The Wire", Ep("The.Wire.S03E01.mkv", "The Wire S01-S05 Complete 1080p")!.ShowTitle);
        Assert.Equal("Dark", Ep("Dark.S01E01.mkv", "Dark Season 1-3 (2017)")!.ShowTitle);
        Assert.Equal("Fargo", Ep("Fargo.S02E01.mkv", "Fargo Complete Series")!.ShowTitle);
    }

    [Fact]
    public void SeasonTagInFileNameOnly() => Assert.Equal("Below", Ep("Below.S01.E02.480p.mkv")!.ShowTitle);

    [Fact]
    public void LanguagesAreNotPartOfTitle()
    {
        Assert.Equal("Some Movie", Movie("Some.Movie.Hindi.English.Esubs.mkv").Title);
        var m = Movie("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.at.mkv");
        Assert.Equal("R L Stines Pumpkinhead", m.Title);
        Assert.Equal(2025, m.Year);
    }

    [Fact]
    public void ApostrophesIgnoredWhenComparing()
    {
        Assert.Equal(
            FilenameParser.NormalizeForCompare("Good Luck, Have Fun, Don't Die"),
            FilenameParser.NormalizeForCompare("Good Luck Have Fun Dont Die"));
        Assert.Equal(
            FilenameParser.NormalizeForCompare("R.L. Stine’s Pumpkinhead"),
            FilenameParser.NormalizeForCompare("R L Stines Pumpkinhead"));
    }

    [Fact]
    public void QualityTags()
    {
        var tags = FilenameParser.QualityTags("Movie.2160p.UHD.BluRay.HEVC.TrueHD.Atmos.7.1.mkv", 0);
        Assert.Equal(new[] { "4K", "HEVC", "Atmos", "7.1" }, tags);
    }
}
