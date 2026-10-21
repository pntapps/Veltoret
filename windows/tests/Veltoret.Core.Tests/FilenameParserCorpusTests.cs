using Veltoret.Core.Library;

namespace Veltoret.Core.Tests;

/// <summary>
/// Real-world naming styles, one per line, so a parser change shows exactly which names it breaks.
/// Release sites are made up ("ReleaseSite.at", "ReleaseSite.army"). Same lines as Android FilenameParserCorpusTest.kt;
/// add a line for every name that parses wrong.
/// </summary>
public class FilenameParserCorpusTests
{
    private sealed record M(string File, string Title, int? Year, string[]? Folders = null);

    private sealed record E(string File, string Show, int Season, int Episode, string[]? Folders = null, int? Year = null, int? EpisodeEnd = null);

    private static string[] F(params string[] f) => f;

    private static readonly M[] Movies =
    {
        // Scene and P2P styles
        new("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv", "The Matrix", 1999),
        new("Inception.2010.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GRP.mkv", "Inception", 2010),
        new("Oppenheimer (2023) [2160p] [4K] [WEB] [5.1] [ReleaseSite.at].mp4", "Oppenheimer", 2023),
        new("Dune.Part.Two.2024.1080p.WEB-DL.DDP5.1.Atmos.H.264-GROUP.mkv", "Dune Part Two", 2024),
        new("Interstellar_2014_1080p_BrRip_x264.mp4", "Interstellar", 2014),
        new("Mad Max Fury Road 2015 1080p BluRay x264 DTS-HD MA 7.1.mkv", "Mad Max Fury Road", 2015),
        new("Parasite.2019.KOREAN.1080p.BluRay.x264.mkv", "Parasite", 2019),
        new("The Batman (2022) 1080p WEBRip 10bit x265 HEVC.mkv", "The Batman", 2022),
        new("Movie+Name+2020+720p.mp4", "Movie Name", 2020),
        // Titles that contain numbers or years
        new("1917.2019.2160p.UHD.mkv", "1917", 2019),
        new("2001.A.Space.Odyssey.1968.mkv", "2001 A Space Odyssey", 1968),
        new("Blade.Runner.2049.1080p.WEB-DL.mkv", "Blade Runner 2049", null),
        new("2012 (2009) 1080p.mkv", "2012", 2009),
        new("Ocean's Eleven (2001).mkv", "Ocean's Eleven", 2001),
        // Indian release styles
        new("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.army.mkv", "R L Stines Pumpkinhead", 2025),
        new("Good Luck Have Fun Dont Die (2026) 1080p BluRay 10bit HEVC [Hindi DDP 5.1  English AAC 7.1] x265 (Group-Tag).mkv", "Good Luck Have Fun Dont Die", 2026),
        new("Jawan (2023) Hindi 1080p HQ HDRip x264 AAC ESub.mkv", "Jawan", 2023),
        new("Pushpa.2.The.Rule.2024.Hindi.Dubbed.720p.WEB-DL.mkv", "Pushpa 2 The Rule", 2024),
        new("Kalki 2898 AD (2024) Dual Audio [Hindi + Telugu] 1080p.mkv", "Kalki 2898 AD", 2024),
        new("Some Movie (Hindi Dubbed) 720p.mkv", "Some Movie", null),
        new("Some.Movie.Hindi.English.Esubs.mkv", "Some Movie", null),
        // Release-site prefixes and suffixes
        new("www.ReleaseSite.com - The Holdovers (2023) 1080p.mkv", "The Holdovers", 2023),
        new("www.ReleaseSite.lol.The.Holdovers.2023.720p.mkv", "The Holdovers", 2023),
        new("ReleaseSite.com - The Holdovers (2023).mkv", "The Holdovers", 2023),
        new("[ReleaseSite.at] The Holdovers 2023.mkv", "The Holdovers", 2023),
        new("The Holdovers - ReleaseSite.army.mkv", "The Holdovers", null),
        // Dotted titles that look like sites but aren't
        new("The.Fault.in.Our.Stars.2014.mkv", "The Fault in Our Stars", 2014),
        new("The.Office.US.mkv", "The Office US", null),
        // Accents and other scripts
        new("Amélie.2001.1080p.mkv", "Amélie", 2001),
        new("दंगल.2016.1080p.mkv", "दंगल", 2016),
        new("千と千尋の神隠し (2001).mkv", "千と千尋の神隠し", 2001),
        // Folders
        new("movie.mkv", "Inception", 2010, F("Inception (2010)")),
        new("Heat.mkv", "Heat", 1995, F("Heat (1995)")),
        new("Heat.mkv", "Heat", 1995, F("Heat (1995)", "1080p")),
        new("cd1.avi", "Heat", 1995, F("Hindi Movies", "Heat (1995)")),
    };

    private static readonly E[] Episodes =
    {
        // Standard numbering
        new("Breaking.Bad.S02E05.Breakage.1080p.mkv", "Breaking Bad", 2, 5),
        new("breaking.bad.s02e05.720p.mkv", "breaking bad", 2, 5),
        new("Show.Name.S01.E02.1080p.mkv", "Show Name", 1, 2),
        new("Show Name S01 E02.mkv", "Show Name", 1, 2),
        new("Show-Name-S01-E02.mkv", "Show-Name", 1, 2),
        new("Show_Name_S01_E02.mkv", "Show Name", 1, 2),
        new("Show.Name.S01EP02.mkv", "Show Name", 1, 2),
        new("Show Name - S01E01-E03 - Pilot.mkv", "Show Name", 1, 1, EpisodeEnd: 3),
        new("Show.S03E01E02.mkv", "Show", 3, 1, EpisodeEnd: 2),
        new("Show.Name.S01E01-03.mkv", "Show Name", 1, 1, EpisodeEnd: 3),
        new("Show.Name.S01E01-1080p.mkv", "Show Name", 1, 1),
        new("Friends 3x07 The One.mkv", "Friends", 3, 7),
        new("Show Name Season 2 Episode 5.mkv", "Show Name", 2, 5),
        new("Show.Name.Season.2.Ep.5.mkv", "Show Name", 2, 5),
        new("Doctor.Who.2005.S01E01.Rose.mkv", "Doctor Who", 1, 1, Year: 2005),
        // Daily and date-based
        new("The.Daily.Show.2024.03.15.Guest.Name.720p.mkv", "The Daily Show", 2024, 315),
        // Anime
        new("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", 1, 5),
        new("[SubGroup] One Piece - 1085 [1080p][ABCD1234].mkv", "One Piece", 1, 1085),
        new("[SubGroup] Show Name 12 (1080p).mkv", "Show Name", 1, 12),
        new("Show Name - 07v2.mkv", "Show Name", 1, 7),
        new("Show Name Ep 07.mkv", "Show Name", 1, 7),
        new("Show Name Episode 7.mkv", "Show Name", 1, 7),
        new("進撃の巨人 第05話.mkv", "進撃の巨人", 1, 5),
        // Compact numbering in scene names only
        new("Show.Name.105.HDTV.mkv", "Show Name", 1, 5),
        // Indian release styles and pack folders
        new("Below.S01E06.The.Unfathering.Deep.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in.mkv", "Below", 1, 6,
            F("Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in", "480p x264")),
        new("E05.mkv", "Overcompensating", 1, 5, F("Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")),
        new("Episode 4.mkv", "Show Name", 2, 4, F("Show Name S02 720p")),
        // Folder layouts
        new("S01E01.mkv", "The Office US", 1, 1, F("The Office (US) (2005)", "Season 1"), Year: 2005),
        new("Episode 3.mkv", "Doctor Who", 0, 3, F("Doctor Who", "Specials")),
        new("05.mkv", "Dark", 2, 5, F("Dark", "Season.2")),
        new("05.mkv", "Dark", 2, 5, F("Dark", "S02")),
        new("05.mkv", "Dark", 2, 5, F("Dark", "Staffel 2")),
        new("05.mkv", "Dark", 3, 5, F("Dark", "Season Three")),
        new("Dark.S01E01.mkv", "Dark", 1, 1, F("English Shows", "Dark")),
        new("Dark.S01E01.mkv", "Dark", 1, 1, F("English Shows")),
        new("Dark.S01E01.mkv", "Dark", 1, 1, F("Dark", "Season 1", "Disc 1")),
        new("Dark.S01E01.mkv", "Dark", 1, 1, F("Dark", "Season 1", "Dark.S01E01.Secrets")),
        new("Office.S01E01.mkv", "The Office", 1, 1, F("The Office (2005)"), Year: 2005),
        new("05.mkv", "Show", 2, 5, F("Season 2", "Show")),
        new("01 - Pilot.mkv", "Show", 1, 1, F("Show")),
    };

    [Fact]
    public void MoviesParse()
    {
        var failures = Movies
            .Select(m => (m, g: FilenameParser.ParseMovie(m.File, m.Folders ?? Array.Empty<string>())))
            .Where(x => x.g.Title != x.m.Title || x.g.Year != x.m.Year)
            .Select(x => $"{x.m.File} -> \"{x.g.Title}\" {x.g.Year} (want \"{x.m.Title}\" {x.m.Year})")
            .ToList();
        Assert.True(failures.Count == 0, "\n" + string.Join("\n", failures));
    }

    [Fact]
    public void EpisodesParse()
    {
        var failures = new List<string>();
        foreach (var e in Episodes)
        {
            var g = FilenameParser.ParseEpisode(e.File, e.Folders ?? Array.Empty<string>());
            var got = g == null ? "null" : $"[{g.ShowTitle}, {g.Season}, {g.Episode}, {g.ShowYear}, {g.EpisodeEnd}]";
            var want = $"[{e.Show}, {e.Season}, {e.Episode}, {e.Year}, {e.EpisodeEnd}]";
            if (got != want) failures.Add($"{e.File} [{string.Join(", ", e.Folders ?? Array.Empty<string>())}] -> {got} (want {want})");
        }
        Assert.True(failures.Count == 0, "\n" + string.Join("\n", failures));
    }

    [Theory]
    [InlineData("Behind the scenes.mkv")]
    [InlineData("Show Name 1080p.mkv")]
    [InlineData("Show Name 2019.mkv")]
    public void NotEpisodes(string name) => Assert.Null(FilenameParser.ParseEpisode(name));

    [Fact]
    public void MovieFallbacksTrimLeftovers()
    {
        var c = FilenameParser.MovieCandidates("Some.Movie.Hindi.720p.mkv");
        Assert.Equal("Some Movie Hindi", c[0].Title);
        Assert.Contains(c, x => x.Title == "Some Movie" && x.ExactOnly);
    }

    [Fact]
    public void MovieFallbacksSplitSubtitle()
    {
        var c = FilenameParser.MovieCandidates("Mission Impossible - Dead Reckoning 2023.mkv");
        Assert.Contains(c, x => x.Title == "Mission Impossible" && x.Year == 2023 && x.ExactOnly);
    }

    [Fact]
    public void TrimmedFallbacksNeverShrinkToOneYearlessWord()
    {
        var c = FilenameParser.MovieCandidates("drone footage beach.mkv");
        Assert.DoesNotContain(c, x => x.Title == "drone");
    }

    [Fact]
    public void ShowFallbacksIncludeFileTitle()
    {
        var c = FilenameParser.ShowCandidates("Dark.S01E01.mkv", new[] { "English Shows", "My Stuff" });
        Assert.Equal("My Stuff", c[0].Title);
        Assert.Contains(c, x => x.Title == "Dark" && !x.ExactOnly);
    }

    [Fact]
    public void OtherScriptsSurviveNormalizing()
    {
        Assert.Equal("दंगल", FilenameParser.NormalizeForCompare("दंगल!"));
        Assert.Equal("amelie", FilenameParser.NormalizeForCompare("Amélie"));
    }
}
