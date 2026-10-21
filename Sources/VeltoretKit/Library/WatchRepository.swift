import Foundation

/// Watch progress keys: by *what* was watched, so every copy of a movie or episode shares one record.
public enum WatchKeys {
    public static func movie(_ id: Int) -> String { "movie:\(id)" }
    public static func episode(_ showId: Int, _ season: Int, _ episode: Int) -> String { "ep:\(showId):\(season):\(episode)" }
    public static func file(_ driveId: String) -> String { "file:\(driveId)" }

    public static func forFile(_ file: MediaFileEntity) -> String {
        if let m = file.movieId { return movie(m) }
        if let s = file.showId, let se = file.season, let e = file.episode { return episode(s, se, e) }
        return self.file(file.driveId)
    }
}

/// Playback progress and watched flags (port of Windows WatchRepository). Synchronous: SQLite only.
public final class WatchRepository: @unchecked Sendable {
    private let dao: WatchDao

    public init(_ dao: WatchDao) { self.dao = dao }

    /// The watched rule: ≥ 92% or less than 2 minutes left.
    public static func isFinished(positionMs: Int64, durationMs: Int64) -> Bool {
        Double(positionMs) >= Double(durationMs) * 0.92 || durationMs - positionMs < 120_000
    }

    public func all() throws -> [WatchStateEntity] { try dao.all() }
    public func forShow(_ showId: Int) throws -> [WatchStateEntity] { try dao.forShow(showId) }
    public func get(_ key: String) throws -> WatchStateEntity? { try dao.get(key) }

    /// Records playback progress; anything past 92% (or the last 2 minutes) counts as watched.
    public func savePosition(_ file: MediaFileEntity?, fallbackFileId: String, positionMs: Int64, durationMs: Int64) throws {
        if durationMs <= 0 { return }
        let key = file.map { WatchKeys.forFile($0) } ?? WatchKeys.file(fallbackFileId)
        let finished = Self.isFinished(positionMs: positionMs, durationMs: durationMs)
        let previous = try dao.get(key)
        try dao.upsert(WatchStateEntity(
            key: key,
            positionMs: finished ? 0 : positionMs,
            durationMs: durationMs,
            watched: finished || (previous?.watched == true && positionMs < 60_000),
            lastWatchedAt: nowMillis(),
            lastFileId: file?.driveId ?? fallbackFileId,
            movieId: file?.movieId,
            showId: file?.showId,
            season: file?.season,
            episode: file?.episode))
        // A multi-episode file (S01E01E02) also completes the episodes it spans.
        if finished, let file, let showId = file.showId, let season = file.season, let episode = file.episode,
           let end = file.episodeEnd, end > episode {
            for ep in (episode + 1)...end { try setEpisodeWatched(showId: showId, season: season, episode: ep, watched: true) }
        }
    }

    public func setMovieWatched(_ movieId: Int, watched: Bool) throws {
        let key = WatchKeys.movie(movieId)
        let prev = try dao.get(key)
        try dao.upsert(WatchStateEntity(
            key: key, positionMs: 0, durationMs: prev?.durationMs ?? 0, watched: watched,
            lastWatchedAt: watched ? nowMillis() : prev?.lastWatchedAt ?? 0,
            lastFileId: prev?.lastFileId, movieId: movieId))
    }

    public func setEpisodeWatched(showId: Int, season: Int, episode: Int, watched: Bool) throws {
        try setEpisodesWatched(showId: showId, [(season, episode)], watched: watched)
    }

    public func setEpisodesWatched(showId: Int, _ episodes: [(season: Int, episode: Int)], watched: Bool) throws {
        let now = nowMillis()
        var states: [WatchStateEntity] = []
        for (i, (season, episode)) in episodes.enumerated() {
            let key = WatchKeys.episode(showId, season, episode)
            let prev = try dao.get(key)
            states.append(WatchStateEntity(
                key: key, positionMs: 0, durationMs: prev?.durationMs ?? 0, watched: watched,
                // Keep a stable order so "Next Up" continues after the last episode in the batch.
                lastWatchedAt: watched ? now + Int64(i) : prev?.lastWatchedAt ?? 0,
                lastFileId: prev?.lastFileId, showId: showId, season: season, episode: episode))
        }
        try dao.upsertAll(states)
    }

    public func setFileWatched(_ file: MediaFileEntity, watched: Bool) throws {
        if let m = file.movieId {
            try setMovieWatched(m, watched: watched)
        } else if let s = file.showId, let se = file.season, let e = file.episode {
            try setEpisodeWatched(showId: s, season: se, episode: e, watched: watched)
        } else {
            try dao.upsert(WatchStateEntity(
                key: WatchKeys.file(file.driveId), positionMs: 0, durationMs: file.durationMs, watched: watched,
                lastWatchedAt: nowMillis(), lastFileId: file.driveId))
        }
    }
}
