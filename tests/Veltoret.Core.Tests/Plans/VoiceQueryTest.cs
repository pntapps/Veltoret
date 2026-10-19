using Veltoret.Core.Plans;
using static Veltoret.Core.Plans.VoiceQuery;

namespace Veltoret.Core.Tests.Plans;

/// <summary>Port of the Android VoiceQueryTest.</summary>
public class VoiceQueryTest
{
    private static readonly List<Candidate> Library = new()
    {
        new(1, false, "The Wrecking Crew", 2026),
        new(2, false, "Hokum", 2026),
        new(3, false, "Spider-Man: No Way Home", 2021),
        new(4, true, "Below", 2025),
        new(5, false, "Below Deck Movie", 2019),
        new(6, false, "Dune", 2021),
        new(7, false, "Dune", 1984),
        new(8, true, "House of the Dragon", 2022),
        new(9, false, "1917", 2019),
        new(10, false, "Don't Look Up", 2021),
    };

    private static int? Pick(string said) => Best(Parse(said), Library)?.Id;

    [Fact]
    public void ParsesSeasonsEpisodesAndFillerWords()
    {
        Assert.Equal(new Parsed("Below", 1, 2), Parse("Below season 1 episode 2"));
        Assert.Equal(new Parsed("House of the Dragon", 2, 5), Parse("play House of the Dragon S02E05 on Veltoret"));
        Assert.Equal(new Parsed("Below", 1, 3), Parse("Below episode 3"));
        Assert.Equal(new Parsed("Dune", Year: 2021), Parse("watch Dune 2021"));
        // A title that is only a year stays a title.
        Assert.Equal(new Parsed("1917"), Parse("1917"));
    }

    [Fact]
    public void MatchesSpokenTitles()
    {
        Assert.Equal(1, Pick("the wrecking crew"));
        Assert.Equal(1, Pick("wrecking crew"));
        Assert.Equal(2, Pick("hokum"));
        Assert.Equal(3, Pick("spider man no way home"));
        Assert.Equal(10, Pick("dont look up"));
        Assert.Equal(9, Pick("1917"));
    }

    [Fact]
    public void ExactTitlesBeatLongerOnes()
    {
        Assert.Equal(4, Pick("Below"));
        Assert.Equal(5, Pick("below deck movie"));
    }

    [Fact]
    public void EpisodesOnlyMatchShowsAndYearsPickTheRightVersion()
    {
        Assert.Equal(4, Pick("Below season 1 episode 2"));
        Assert.Equal(6, Pick("Dune 2021"));
        Assert.Equal(7, Pick("Dune 1984"));
    }

    [Fact]
    public void NothingCloseMeansNoMatch()
    {
        Assert.Null(Pick("the godfather"));
        Assert.Null(Pick(""));
    }
}
