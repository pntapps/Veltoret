import Foundation

public struct EpisodeTarget: Hashable, Sendable {
    public var file: MediaFileEntity
    public var state: WatchStateEntity?
    /// True when this continues a partly watched episode rather than starting a new one.
    public var resuming: Bool
    /// True when nothing of the show has been watched yet.
    public var fresh: Bool
    public init(file: MediaFileEntity, state: WatchStateEntity?, resuming: Bool, fresh: Bool) {
        self.file = file; self.state = state; self.resuming = resuming; self.fresh = fresh
    }
}

public enum PlayTargets {
    /// Picks what "Play" should start for a show: the most recent in-progress episode if it is newer
    /// than anything finished, otherwise the first unwatched episode after the last finished one.
    public static func nextEpisode(_ files: [MediaFileEntity], _ states: [WatchStateEntity]) -> EpisodeTarget? {
        struct Pair: Hashable { let s: Int; let e: Int }
        var seen = Set<Pair>()
        let playable = files
            .filter { $0.season != nil && $0.episode != nil }
            .enumerated()
            .sorted { a, b in
                let sa = a.element.season == 0 ? Int.max : a.element.season!
                let sb = b.element.season == 0 ? Int.max : b.element.season!
                if sa != sb { return sa < sb }
                if a.element.episode! != b.element.episode! { return a.element.episode! < b.element.episode! }
                return a.offset < b.offset
            }
            .map(\.element)
            .filter { seen.insert(Pair(s: $0.season!, e: $0.episode!)).inserted }
        if playable.isEmpty { return nil }
        var byKey: [String: WatchStateEntity] = [:]
        for s in states { byKey[s.key] = s }
        func stateOf(_ f: MediaFileEntity) -> WatchStateEntity? { byKey[WatchKeys.forFile(f)] }

        let lastWatched = maxBy(states.filter { $0.watched && $0.season != nil }) { $0.lastWatchedAt }
        let inProgress = maxBy(states.filter { !$0.watched && $0.positionMs > 30_000 && $0.season != nil }) { $0.lastWatchedAt }

        if let inProgress, lastWatched == nil || inProgress.lastWatchedAt > lastWatched!.lastWatchedAt {
            if let current = playable.first(where: { $0.season == inProgress.season && $0.episode == inProgress.episode }) {
                return EpisodeTarget(file: current, state: inProgress, resuming: true, fresh: false)
            }
        }
        if let lastWatched {
            let lastSeason = lastWatched.season!
            let lastEpisode = lastWatched.episode ?? 0
            let next = playable.first { f in
                let s = f.season!
                let after = lastSeason == 0
                    ? s == 0 && f.episode! > lastEpisode
                    : (s > lastSeason && s != 0) || (s == lastSeason && f.episode! > lastEpisode)
                return after && stateOf(f)?.watched != true
            }
            guard let next else { return nil }
            return EpisodeTarget(file: next, state: stateOf(next), resuming: false, fresh: false)
        }
        let first = playable.first(where: { $0.season != 0 }) ?? playable[0]
        return EpisodeTarget(file: first, state: stateOf(first), resuming: false, fresh: true)
    }

    /// Kotlin's maxByOrNull: the first element with the largest key, or nil.
    private static func maxBy<T>(_ items: [T], _ key: (T) -> Int64) -> T? {
        var best: T?
        var bestKey: Int64 = 0
        for item in items {
            let k = key(item)
            if best == nil || k > bestKey { best = item; bestKey = k }
        }
        return best
    }
}
