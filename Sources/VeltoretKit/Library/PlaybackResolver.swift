import Foundation

/// Resolves what a "Play" button should start. Offline, only This Mac copies can play.
public final class PlaybackResolver: @unchecked Sendable {
    private let files: MediaFileDao
    private let watch: WatchDao
    private let isOnline: () -> Bool

    public init(files: MediaFileDao, watch: WatchDao, isOnline: @escaping () -> Bool) {
        self.files = files
        self.watch = watch
        self.isOnline = isOnline
    }

    /// Best version of a movie: a device copy first, then highest resolution and largest file.
    public func movieFile(_ movieId: Int) throws -> MediaFileEntity? {
        playable(try files.forMovie(movieId)).first
    }

    public func showTarget(_ showId: Int) throws -> EpisodeTarget? {
        PlayTargets.nextEpisode(playable(try files.forShow(showId)), try watch.forShow(showId))
    }

    /// What "Play" on a show starts: the next episode, or episode 1 again once everything is watched.
    public func showPlayTarget(_ showId: Int) throws -> EpisodeTarget? {
        if let t = try showTarget(showId) { return t }
        return PlayTargets.nextEpisode(playable(try files.forShow(showId)), [])
    }

    /// Best copy of one episode (device first, then highest resolution).
    public func episodeFile(showId: Int, season: Int, episode: Int) throws -> MediaFileEntity? {
        playable(try files.forShow(showId))
            .filter { $0.season == season && $0.episode == episode }
            .enumerated()
            .sorted { a, b in
                let la = Accounts.isLocal(a.element.accountEmail), lb = Accounts.isLocal(b.element.accountEmail)
                if la != lb { return la }
                if a.element.height != b.element.height { return a.element.height > b.element.height }
                return a.offset < b.offset
            }
            .first?.element
    }

    private func playable(_ list: [MediaFileEntity]) -> [MediaFileEntity] {
        isOnline() ? list : list.filter { Accounts.isLocal($0.accountEmail) }
    }
}
