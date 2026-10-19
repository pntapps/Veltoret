using Veltoret.Core.Library;

namespace Veltoret.Core.Tests;

/// <summary>Port of Android RelatedTitlesTest.kt.</summary>
public class RelatedTitlesTests
{
    private static readonly Dictionary<int, string> Library = new()
    {
        [1] = "Self", [2] = "Two", [3] = "Three", [4] = "Four", [5] = "Five",
    };

    [Fact]
    public void KeepsTmdbOrderAndOnlyLibraryTitles() =>
        Assert.Equal(new[] { "Four", "Two", "Five" }, RelatedTitles.InLibrary(new[] { 99, 4, 2, 77, 5 }, Library, selfId: 1));

    [Fact]
    public void SkipsSelfAndRepeats() =>
        Assert.Equal(new[] { "Three", "Two" }, RelatedTitles.InLibrary(new[] { 1, 3, 3, 2, 1 }, Library, selfId: 1));

    [Fact]
    public void CapsAtLimit() =>
        Assert.Equal(new[] { "Two", "Three" }, RelatedTitles.InLibrary(new[] { 2, 3, 4, 5 }, Library, selfId: 1, limit: 2));

    [Fact]
    public void NothingRecommendedOrNotFetchedIsEmpty()
    {
        Assert.Empty(RelatedTitles.InLibrary(RelatedTitles.ParseIds(null), Library, selfId: 1));
        Assert.Empty(RelatedTitles.InLibrary(RelatedTitles.ParseIds(""), Library, selfId: 1));
    }

    [Fact]
    public void ParsesStoredIds() => Assert.Equal(new[] { 12, 345, 6 }, RelatedTitles.ParseIds("12,345, 6,,x"));
}
