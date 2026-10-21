using Veltoret.Core.Tmdb;

namespace Veltoret.Core.Tests;

/// <summary>Port of Android TrailerPickTest.kt.</summary>
public class TrailerPickTests
{
    private static TmdbVideo Video(string key, string type = "Trailer", bool official = true, string? date = "2020-01-01", string site = "YouTube") =>
        new() { Key = key, Site = site, Type = type, Official = official, PublishedAt = date };

    [Fact]
    public void TrailerBeatsTeaserAndClips()
    {
        var videos = new[] { Video("clip", type: "Clip"), Video("teaser", type: "Teaser"), Video("trailer"), Video("bts", type: "Behind the Scenes") };
        Assert.Equal("trailer", TmdbRepository.PickTrailer(videos, newest: false));
    }

    [Fact]
    public void TeaserWhenThereIsNoTrailer() =>
        Assert.Equal("teaser", TmdbRepository.PickTrailer(new[] { Video("clip", type: "Clip"), Video("teaser", type: "Teaser") }, newest: false));

    [Fact]
    public void OfficialBeatsFanUploads() =>
        Assert.Equal("official", TmdbRepository.PickTrailer(new[] { Video("fan", official: false, date: "2019-01-01"), Video("official") }, newest: false));

    [Fact]
    public void MoviesTakeTheOriginalTrailerShowsTheLatest()
    {
        var videos = new[] { Video("rerelease", date: "2021-05-01"), Video("original", date: "1999-02-01"), Video("undated", date: null) };
        Assert.Equal("original", TmdbRepository.PickTrailer(videos, newest: false));
        Assert.Equal("rerelease", TmdbRepository.PickTrailer(videos, newest: true));
    }

    [Fact]
    public void OnlyYouTube() =>
        Assert.Null(TmdbRepository.PickTrailer(new[] { Video("vimeo", site: "Vimeo"), Video("", site: "YouTube") }, newest: false));
}
