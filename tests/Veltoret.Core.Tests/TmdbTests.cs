using System.Net;
using System.Text;
using System.Text.Json;
using Veltoret.Core.Tmdb;

namespace Veltoret.Core.Tests;

/// <summary>Answers TMDB requests from a function of the request URL.</summary>
public sealed class FakeTmdbHandler(Func<Uri, string?> respond) : HttpMessageHandler
{
    public List<HttpRequestMessage> Requests { get; } = new();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        lock (Requests) Requests.Add(request);
        var body = respond(request.RequestUri!);
        return Task.FromResult(body == null
            ? new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{}") }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
    }
}

public class TmdbTests
{
    [Fact]
    public void V3KeyGoesInQueryWithLanguage()
    {
        var url = TmdbClient.BuildUrl("search/movie", "abc123", ("query", "The Matrix"), ("year", null));
        Assert.Equal("https://api.themoviedb.org/3/search/movie?query=The%20Matrix&language=en-US&api_key=abc123", url);
    }

    [Fact]
    public void BearerTokenStaysOutOfUrl()
    {
        var url = TmdbClient.BuildUrl("configuration", "eyJhbGciOi.x.y");
        Assert.Equal("https://api.themoviedb.org/3/configuration?language=en-US", url);
    }

    [Fact]
    public async Task BearerTokenIsSentAsHeader()
    {
        var handler = new FakeTmdbHandler(_ => "{}");
        var client = new TmdbClient(new HttpClient(handler), () => "eyJtoken");
        await client.Configuration();
        Assert.Equal("Bearer", handler.Requests[0].Headers.Authorization!.Scheme);
        Assert.Equal("eyJtoken", handler.Requests[0].Headers.Authorization!.Parameter);
    }

    [Fact]
    public async Task MissingKeyThrows()
    {
        var client = new TmdbClient(new HttpClient(new FakeTmdbHandler(_ => "{}")), () => "  ");
        await Assert.ThrowsAsync<TmdbKeyMissingException>(() => client.Configuration());
    }

    [Fact]
    public void SnakeCaseModelsParse()
    {
        const string json = """
            {"id":603,"title":"The Matrix","original_title":"The Matrix","release_date":"1999-03-30","runtime":136,
             "vote_average":8.2,"genres":[{"id":28,"name":"Action"}],"belongs_to_collection":{"id":2344,"name":"The Matrix Collection"},
             "credits":{"cast":[{"id":6384,"name":"Keanu Reeves","character":"Neo","profile_path":"/k.jpg","order":0}],
                        "crew":[{"id":9339,"name":"Lilly Wachowski","job":"Director"}]},
             "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"R"}]}]}}
            """;
        var d = JsonSerializer.Deserialize<TmdbMovieDetail>(json, TmdbClient.Json)!;
        Assert.Equal("1999-03-30", d.ReleaseDate);
        Assert.Equal(136, d.Runtime);
        Assert.Equal(2344, d.Collection!.Id);
        Assert.Equal("Neo", d.Credits!.Cast[0].Character);
        Assert.Equal("/k.jpg", d.Credits.Cast[0].ProfilePath);
        Assert.Equal("US", d.ReleaseDates!.Results[0].Country);
        Assert.Equal("R", d.ReleaseDates.Results[0].ReleaseDates[1].Certification);

        var tv = JsonSerializer.Deserialize<TmdbTvDetail>(
            """{"id":1,"name":"X","next_episode_to_air":{"season_number":2,"episode_number":5,"air_date":"2026-01-01"},"episode_run_time":[45],"number_of_seasons":3}""",
            TmdbClient.Json)!;
        Assert.Equal(5, tv.NextEpisode!.EpisodeNumber);
        Assert.Equal(45, tv.EpisodeRunTime[0]);
        Assert.Equal(3, tv.NumberOfSeasons);
    }

    private static TmdbMovieSummary S(int id, string title, string? date, int votes = 1000) =>
        new() { Id = id, Title = title, ReleaseDate = date, VoteCount = votes };

    private static TmdbMovieSummary? Pick(IReadOnlyList<TmdbMovieSummary> r, string title, int? year, bool exactOnly = false) =>
        TmdbRepository.PickBest(r, title, year, exactOnly, x => x.Title, x => x.OriginalTitle, x => x.ReleaseDate, x => x.VoteCount);

    [Fact]
    public void PickBestPrefersExactTitleAndYear()
    {
        var r = new[] { S(1, "The Matrix Reloaded", "2003-05-15"), S(2, "The Matrix", "1999-03-30"), S(3, "The Matrix", "2021-01-01", 5) };
        Assert.Equal(2, Pick(r, "The Matrix", 1999)!.Id);
    }

    [Fact]
    public void PickBestRejectsShortYearlessObscureMatches()
    {
        Assert.Null(Pick(new[] { S(1, "Vids", null, votes: 3) }, "vids", null));
        Assert.Null(Pick(new[] { S(1, "Ambient Vids", "2010-01-01") }, "vids", null)); // partial, lengths far apart, no year
        Assert.Equal(1, Pick(new[] { S(1, "Ambient Vids", "2010-01-01") }, "vids", 2010)!.Id); // year agrees
    }

    [Fact]
    public void ExactOnlyNeedsExactTitleAndCloseYear()
    {
        var r = new[] { S(1, "Some Movie", "2015-01-01") };
        Assert.Null(Pick(r, "Some Movie", 2020, exactOnly: true));
        Assert.Equal(1, Pick(r, "Some Movie", 2016, exactOnly: true)!.Id);
        Assert.Null(Pick(new[] { S(1, "Some Movie Two", "2015-01-01") }, "Some Movie", 2015, exactOnly: true));
    }

    [Fact]
    public void YearOfReadsTheFirstFourCharacters()
    {
        Assert.Equal(1999, TmdbRepository.YearOf("1999-03-30"));
        Assert.Null(TmdbRepository.YearOf(""));
        Assert.Null(TmdbRepository.YearOf(null));
    }
}
