using System.Text.Json.Serialization;

namespace Veltoret.Core.Tmdb;

// TMDB v3 responses (Android TmdbModels.kt). Property names map to snake_case JSON via the client's naming
// policy; the few that don't follow it carry [JsonPropertyName].

public sealed record TmdbPage<T>
{
    public int Page { get; init; } = 1;
    public List<T> Results { get; init; } = new();
    public int TotalResults { get; init; }
    public int TotalPages { get; init; } = 1;
}

public sealed record TmdbVideos
{
    public List<TmdbVideo> Results { get; init; } = new();
}

/// <summary>A trailer, teaser or clip TMDB links to; <see cref="Key"/> is the YouTube video id when <see cref="Site"/> is "YouTube".</summary>
public sealed record TmdbVideo
{
    public string Key { get; init; } = "";
    public string Site { get; init; } = "";
    public string Type { get; init; } = "";
    public string Name { get; init; } = "";
    public bool Official { get; init; }
    public string? PublishedAt { get; init; }
}

public sealed record TmdbMovieSummary
{
    public int Id { get; init; }
    public string Title { get; init; } = "";
    public string? OriginalTitle { get; init; }
    public string? ReleaseDate { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public string? Overview { get; init; }
    public double VoteAverage { get; init; }
    public int VoteCount { get; init; }
}

public sealed record TmdbTvSummary
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string? OriginalName { get; init; }
    public string? FirstAirDate { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public string? Overview { get; init; }
    public double VoteAverage { get; init; }
    public int VoteCount { get; init; }
}

public sealed record TmdbGenre
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
}

public sealed record TmdbCast
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string? Character { get; init; }
    public string? ProfilePath { get; init; }
    public int Order { get; init; }
}

public sealed record TmdbCrew
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string? Job { get; init; }
}

public sealed record TmdbCredits
{
    public List<TmdbCast> Cast { get; init; } = new();
    public List<TmdbCrew> Crew { get; init; } = new();
}

public sealed record TmdbCollectionRef
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
}

public sealed record TmdbReleaseDates
{
    public List<TmdbCountryReleases> Results { get; init; } = new();
}

public sealed record TmdbCountryReleases
{
    [JsonPropertyName("iso_3166_1")] public string Country { get; init; } = "";
    public List<TmdbReleaseDate> ReleaseDates { get; init; } = new();
}

public sealed record TmdbReleaseDate
{
    public string Certification { get; init; } = "";
}

public sealed record TmdbContentRatings
{
    public List<TmdbContentRating> Results { get; init; } = new();
}

public sealed record TmdbContentRating
{
    [JsonPropertyName("iso_3166_1")] public string Country { get; init; } = "";
    public string Rating { get; init; } = "";
}

public sealed record TmdbMovieDetail
{
    public int Id { get; init; }
    public string Title { get; init; } = "";
    public string? OriginalTitle { get; init; }
    public string? Overview { get; init; }
    public string? Tagline { get; init; }
    public string? ReleaseDate { get; init; }
    public int? Runtime { get; init; }
    public double VoteAverage { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public List<TmdbGenre> Genres { get; init; } = new();
    [JsonPropertyName("belongs_to_collection")] public TmdbCollectionRef? Collection { get; init; }
    public TmdbCredits? Credits { get; init; }
    public TmdbReleaseDates? ReleaseDates { get; init; }
}

public sealed record TmdbNetwork
{
    public string Name { get; init; } = "";
}

public sealed record TmdbCreator
{
    public string Name { get; init; } = "";
}

public sealed record TmdbSeasonSummary
{
    public int SeasonNumber { get; init; }
    public string Name { get; init; } = "";
    public string? Overview { get; init; }
    public string? PosterPath { get; init; }
    public int EpisodeCount { get; init; }
    public string? AirDate { get; init; }
}

public sealed record TmdbTvDetail
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string? Overview { get; init; }
    public string? Tagline { get; init; }
    public string? FirstAirDate { get; init; }
    public string? LastAirDate { get; init; }
    public string? Status { get; init; }
    public double VoteAverage { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public List<TmdbGenre> Genres { get; init; } = new();
    public List<TmdbNetwork> Networks { get; init; } = new();
    public List<TmdbCreator> CreatedBy { get; init; } = new();
    public int NumberOfSeasons { get; init; }
    public int NumberOfEpisodes { get; init; }
    public List<int> EpisodeRunTime { get; init; } = new();
    public List<TmdbSeasonSummary> Seasons { get; init; } = new();
    public TmdbCredits? Credits { get; init; }
    public TmdbContentRatings? ContentRatings { get; init; }
    [JsonPropertyName("next_episode_to_air")] public TmdbNextEpisode? NextEpisode { get; init; }
}

public sealed record TmdbNextEpisode
{
    public int SeasonNumber { get; init; }
    public int EpisodeNumber { get; init; }
    public string Name { get; init; } = "";
    public string? AirDate { get; init; }
}

/// <summary>A movie collection ("The Matrix Collection") and every movie in it.</summary>
public sealed record TmdbCollection
{
    public int Id { get; init; }
    public string Name { get; init; } = "";
    public string? Overview { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public List<TmdbMovieSummary> Parts { get; init; } = new();
}

public sealed record TmdbEpisode
{
    public int EpisodeNumber { get; init; }
    public int SeasonNumber { get; init; }
    public string Name { get; init; } = "";
    public string? Overview { get; init; }
    public string? StillPath { get; init; }
    public string? AirDate { get; init; }
    public int? Runtime { get; init; }
    public double VoteAverage { get; init; }
}

public sealed record TmdbSeasonDetail
{
    public int SeasonNumber { get; init; }
    public string Name { get; init; } = "";
    public string? Overview { get; init; }
    public string? PosterPath { get; init; }
    public string? AirDate { get; init; }
    public List<TmdbEpisode> Episodes { get; init; } = new();
}
