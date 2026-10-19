namespace Veltoret.Core.Data;

// Rows of the SQLite library database. Same tables and columns as the Android app's Room schema (version 4),
// so the logic ported from there reads the same. Enums are stored as their names (TEXT), as Room does.

public enum LibraryType { MOVIES, SHOWS }

public enum MediaKind { MOVIE, EPISODE }

public enum MatchState
{
    /// <summary>Parsed but not yet looked up on TMDB.</summary>
    PENDING,
    MATCHED,
    /// <summary>TMDB returned nothing usable; needs a manual fix.</summary>
    UNMATCHED,
    /// <summary>Chosen by the user via "Fix match"; never overwritten by a rescan.</summary>
    MANUAL,
    /// <summary>Not a movie or episode (home videos, tutorials…): kept out of the library and the "needs a match" list.</summary>
    IGNORED,
}

public sealed record AccountEntity
{
    public string Email { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string? PhotoUrl { get; init; }
    public long AddedAt { get; init; }
}

public sealed record LibraryFolderEntity
{
    public long Id { get; init; }
    public string AccountEmail { get; init; } = "";
    /// <summary>Drive folder id, a local folder path, or smb://host/share/path.</summary>
    public string DriveFolderId { get; init; } = "";
    public string Name { get; init; } = "";
    public LibraryType Type { get; init; }
    public long LastScannedAt { get; init; }
}

public sealed record MediaFileEntity
{
    /// <summary>Drive file id, a local file path, or smb://host/share/path. Primary key across all sources.</summary>
    public string DriveId { get; init; } = "";
    public string AccountEmail { get; init; } = "";
    public long LibraryFolderId { get; init; }
    public string Name { get; init; } = "";
    public string ParentId { get; init; } = "";
    /// <summary>Folder names between the library root and the file, joined with "/".</summary>
    public string RelativePath { get; init; } = "";
    public long SizeBytes { get; init; }
    public string? ModifiedTime { get; init; }
    public string MimeType { get; init; } = "";
    public long DurationMs { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public MediaKind Kind { get; init; }
    public string ParsedTitle { get; init; } = "";
    public int? ParsedYear { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    public int? EpisodeEnd { get; init; }
    public int? MovieId { get; init; }
    public int? ShowId { get; init; }
    public MatchState MatchState { get; init; }
    public long AddedAt { get; init; }
}

public sealed record SubtitleFileEntity
{
    public string DriveId { get; init; } = "";
    public string AccountEmail { get; init; } = "";
    public long LibraryFolderId { get; init; }
    public string ParentId { get; init; } = "";
    public string Name { get; init; } = "";
}

public sealed record MovieEntity
{
    public int TmdbId { get; init; }
    public string Title { get; init; } = "";
    public string? OriginalTitle { get; init; }
    public string Overview { get; init; } = "";
    public string? Tagline { get; init; }
    public string? ReleaseDate { get; init; }
    public int? Year { get; init; }
    public int? RuntimeMin { get; init; }
    public double Rating { get; init; }
    public string? Certification { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    /// <summary>Comma-separated genre names.</summary>
    public string Genres { get; init; } = "";
    public int? CollectionId { get; init; }
    public string? CollectionName { get; init; }
    public string? Director { get; init; }
    public long UpdatedAt { get; init; }

    public IReadOnlyList<string> GenreList => Genres.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
}

public sealed record ShowEntity
{
    public int TmdbId { get; init; }
    public string Name { get; init; } = "";
    public string Overview { get; init; } = "";
    public string? Tagline { get; init; }
    public string? FirstAirDate { get; init; }
    public int? Year { get; init; }
    public string? LastAirDate { get; init; }
    public string? Status { get; init; }
    public double Rating { get; init; }
    public string? Certification { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public string Genres { get; init; } = "";
    public string? Network { get; init; }
    public int SeasonCount { get; init; }
    public int EpisodeCount { get; init; }
    public int? EpisodeRuntimeMin { get; init; }
    public string? Creator { get; init; }
    public long UpdatedAt { get; init; }
    /// <summary>The next episode TMDB says will air (season, number, name, "yyyy-MM-dd"); null when none is announced.</summary>
    public int? NextEpisodeSeason { get; init; }
    public int? NextEpisodeNumber { get; init; }
    public string? NextEpisodeName { get; init; }
    public string? NextEpisodeAirDate { get; init; }

    public IReadOnlyList<string> GenreList => Genres.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
}

public sealed record SeasonEntity
{
    public int ShowId { get; init; }
    public int SeasonNumber { get; init; }
    public string Name { get; init; } = "";
    public string Overview { get; init; } = "";
    public string? PosterPath { get; init; }
    public int EpisodeCount { get; init; }
    public string? AirDate { get; init; }
    public long FetchedAt { get; init; }
}

public sealed record EpisodeEntity
{
    public int ShowId { get; init; }
    public int SeasonNumber { get; init; }
    public int EpisodeNumber { get; init; }
    public string Name { get; init; } = "";
    public string Overview { get; init; } = "";
    public string? StillPath { get; init; }
    public string? AirDate { get; init; }
    public int? RuntimeMin { get; init; }
    public double Rating { get; init; }
}

public sealed record CreditEntity
{
    /// <summary>"movie" or "tv".</summary>
    public string MediaType { get; init; } = "";
    public int MediaId { get; init; }
    public int PersonId { get; init; }
    public string Name { get; init; } = "";
    public string? Character { get; init; }
    public string? ProfilePath { get; init; }
    public int Ord { get; init; }
}

/// <summary>
/// TMDB's "recommendations" for a movie or show, in TMDB's order. Only the ones in the library are shown
/// ("More like this"), so the ids of titles the user doesn't have are kept too, in case they're added later.
/// </summary>
public sealed record RecommendationEntity
{
    public string MediaType { get; init; } = "";
    public int MediaId { get; init; }
    /// <summary>Comma-separated TMDB ids of the same type, best match first.</summary>
    public string RecommendedIds { get; init; } = "";
    public long FetchedAt { get; init; }

    public IReadOnlyList<int> Ids => RecommendedIds.Split(',', StringSplitOptions.RemoveEmptyEntries)
        .Select(s => int.TryParse(s, out var n) ? n : 0).Where(n => n != 0).ToList();
}

/// <summary>"Watch later": a movie ("movie") or show ("tv") the user saved. Shows also get new-episode alerts.</summary>
public sealed record WatchlistEntity
{
    public string MediaType { get; init; } = "";
    public int MediaId { get; init; }
    public long AddedAt { get; init; }
}

/// <summary>
/// "Remind me": a notification at <see cref="At"/> (epoch ms) for a movie, a show, or one episode (Season and
/// Episode set). Title is kept so the reminder still reads well if the title leaves the library.
/// </summary>
public sealed record ReminderEntity
{
    public long Id { get; init; }
    public string MediaType { get; init; } = "";
    public int MediaId { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    public string Title { get; init; } = "";
    public long At { get; init; }
    public long CreatedAt { get; init; }
}

/// <summary>
/// Watch progress, keyed by *what* was watched rather than which file, so several versions of the
/// same movie (1080p / 4K, or copies in two accounts) share one progress record. See WatchKeys.
/// </summary>
public sealed record WatchStateEntity
{
    public string Key { get; init; } = "";
    public long PositionMs { get; init; }
    public long DurationMs { get; init; }
    public bool Watched { get; init; }
    public long LastWatchedAt { get; init; }
    public string? LastFileId { get; init; }
    public int? MovieId { get; init; }
    public int? ShowId { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }

    public float Progress => DurationMs > 0 ? Math.Clamp((float)PositionMs / DurationMs, 0f, 1f) : 0f;
}

public sealed record ShowSeason(int ShowId, int Season);

/// <summary>A .zip found inside a library folder. Videos inside archives can't be streamed until extracted.</summary>
public sealed record ArchiveFileEntity
{
    public string DriveId { get; init; } = "";
    public string AccountEmail { get; init; } = "";
    public long LibraryFolderId { get; init; }
    public string ParentId { get; init; } = "";
    public string Name { get; init; } = "";
    public long SizeBytes { get; init; }
    public string RelativePath { get; init; } = "";
}

public sealed record MovieRow(MovieEntity Movie, long AddedAt, int MaxHeight, int FileCount, int DeviceFiles);

public sealed record ShowRow(ShowEntity Show, long AddedAt, int AvailableEpisodes, int DeviceEpisodes);

/// <summary>A search result and why it matched when it wasn't the title ("Tom Hanks", "Directed by …").</summary>
public sealed record SearchHit
{
    public int Id { get; init; }
    public string? Reason { get; init; }
}

/// <summary>One source (account email, "device" or "smb://host") that holds a copy of a movie or an episode of a show.</summary>
public sealed record TitleSource
{
    public int TitleId { get; init; }
    public string AccountEmail { get; init; } = "";
}

/// <summary>Videos found in one library folder (Settings shows it next to the folder).</summary>
public sealed record FolderVideoCount
{
    public long FolderId { get; init; }
    public int Videos { get; init; }
}
