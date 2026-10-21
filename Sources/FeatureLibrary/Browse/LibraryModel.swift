import Foundation
import VeltoretKit
import VeltoretUI

enum WatchFilter: CaseIterable, Sendable {
    case all, unwatched, inProgress, watched, fourK
    var label: String {
        switch self {
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .inProgress: return "In progress"
        case .watched: return "Watched"
        case .fourK: return "4K"
        }
    }
}

enum LibrarySort: CaseIterable, Sendable {
    case recent, title, year, rating
    var label: String {
        switch self {
        case .recent: return "Recently added"
        case .title: return "Title"
        case .year: return "Release year"
        case .rating: return "Rating"
        }
    }
}

enum WatchStatus: Sendable { case unwatched, inProgress, watched }

struct LibraryEntry: Sendable {
    var item: PosterItem
    var status: WatchStatus
    var uhd: Bool
    var sources: Set<String>
    var genres: [String]
    var addedAt: Int64
    var sortTitle: String
    var year: Int
    var rating: Double
}

struct SourceOption: Hashable, Sendable {
    var account: String
    var label: String
}

/// What the Movies / TV Shows grid loads (Windows LibraryViewModel.Load, spec §4.2).
struct LibraryData: Sendable {
    var online = true
    var unmatched = 0
    var all: [LibraryEntry] = []
    var genres: [String] = []
    var sources: [SourceOption] = []
}

enum LibraryModel {
    static let watchedTables = ["movies", "shows", "media_files", "watch_state"]

    static func load(shows: Bool) throws -> LibraryData {
        let lib = AppServices.library!
        let online = AppServices.connectivity?.isOnline ?? true
        let states = try AppServices.watch.all()
        let unmatched = try lib.unmatched()
        let stateByKey = PosterItems.statesByKey(states)
        var entries: [LibraryEntry] = []

        func sourcesByTitle(_ list: [TitleSource]) -> [Int: Set<String>] {
            var map: [Int: Set<String>] = [:]
            for s in list { map[s.titleId, default: []].insert(s.accountEmail) }
            return map
        }

        if !shows {
            let movies = try lib.movies()
            let src = sourcesByTitle(try lib.movieSources())
            entries = movies.map { r in
                let st = stateByKey[WatchKeys.movie(r.movie.tmdbId)]
                let status: WatchStatus = st?.watched == true ? .watched
                    : (st.map { $0.positionMs > 30_000 } ?? false) ? .inProgress : .unwatched
                let item = PosterItem(
                    id: r.movie.tmdbId, title: r.movie.title,
                    subtitle: Formats.nilIfEmpty(Formats.joinTight(r.movie.year.map(String.init), Formats.runtime(r.movie.runtimeMin))),
                    posterUrl: TmdbImages.poster(r.movie.posterPath),
                    progress: status == .inProgress ? Double(st!.progress) : nil,
                    watched: status == .watched, rating: r.movie.rating)
                return LibraryEntry(item: item, status: status, uhd: r.maxHeight >= 1600, sources: src[r.movie.tmdbId] ?? [],
                                    genres: r.movie.genreList, addedAt: r.addedAt, sortTitle: sortKey(r.movie.title),
                                    year: r.movie.year ?? 0, rating: r.movie.rating)
            }
        } else {
            let list = try lib.shows()
            let src = sourcesByTitle(try lib.showSources())
            let files = try lib.episodeFiles()
            let uhdShows = Set(files.filter { $0.height >= 1600 }.compactMap(\.showId))
            struct Ep: Hashable { let s: Int; let e: Int }
            var watchedByShow: [Int: Set<Ep>] = [:]
            for s in states where s.watched {
                if let sid = s.showId, let se = s.season, let ep = s.episode { watchedByShow[sid, default: []].insert(Ep(s: se, e: ep)) }
            }
            entries = list.map { r in
                let w = watchedByShow[r.show.tmdbId]?.count ?? 0
                let n = r.availableEpisodes
                let status: WatchStatus = w == 0 ? .unwatched : w >= n ? .watched : .inProgress
                let item = PosterItem(
                    id: r.show.tmdbId, isShow: true, title: r.show.name,
                    subtitle: status == .inProgress ? "\(w) of \(n) watched" : Formats.episodes(n),
                    posterUrl: TmdbImages.poster(r.show.posterPath),
                    progress: status == .inProgress && n > 0 ? Double(w) / Double(n) : nil,
                    rating: r.show.rating)
                return LibraryEntry(item: item, status: status, uhd: uhdShows.contains(r.show.tmdbId),
                                    sources: src[r.show.tmdbId] ?? [], genres: r.show.genreList, addedAt: r.addedAt,
                                    sortTitle: sortKey(r.show.name), year: r.show.year ?? 0, rating: r.show.rating)
            }
        }

        // Sources: only when online; accounts that hold something; This Mac, Google, then network servers; hidden if ≤ 1.
        var options: [SourceOption] = []
        if online {
            let held = Set(entries.flatMap(\.sources))
            let ordered = held.sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            options = ordered.map { SourceOption(account: $0, label: labelFor($0)) }
            if options.count <= 1 { options = [] }
        }

        // Genres by how many titles have them (DESC), first seen first on ties.
        var counts: [String: Int] = [:]
        var order: [String] = []
        for g in entries.flatMap(\.genres) {
            if counts[g] == nil { order.append(g) }
            counts[g, default: 0] += 1
        }
        let genres = stableSorted(order) { counts[$0]! > counts[$1]! }

        let kind: MediaKind = shows ? .EPISODE : .MOVIE
        return LibraryData(online: online, unmatched: unmatched.filter { $0.kind == kind }.count, all: entries,
                           genres: genres, sources: options)
    }

    private static func rank(_ account: String) -> Int { Accounts.isLocal(account) ? 0 : Accounts.isDrive(account) ? 1 : 2 }

    static func labelFor(_ account: String) -> String {
        if Accounts.isLocal(account) { return Accounts.deviceDisplayName }
        if Accounts.isSmb(account) {
            if let name = try? AppServices.storage.rootName(account) { return name }
            return account.replacingOccurrences(of: "smb://", with: "")
        }
        return account
    }

    static func sortKey(_ title: String) -> String {
        let t = title.hasPrefix("The ") ? String(title.dropFirst(4)) : title
        return t.lowercased()
    }

    static func apply(_ all: [LibraryEntry], filter: WatchFilter, genre: String?, sort: LibrarySort, source: String?) -> [PosterItem] {
        var q = all
        if let source { q = q.filter { $0.sources.contains(source) } }
        if let genre { q = q.filter { $0.genres.contains(genre) } }
        switch filter {
        case .fourK: q = q.filter(\.uhd)
        case .unwatched: q = q.filter { $0.status == .unwatched }
        case .inProgress: q = q.filter { $0.status == .inProgress }
        case .watched: q = q.filter { $0.status == .watched }
        case .all: break
        }
        switch sort {
        case .title: q = stableSorted(q) { $0.sortTitle < $1.sortTitle }
        case .year: q = stableSorted(q) { $0.year > $1.year }
        case .rating: q = stableSorted(q) { $0.rating > $1.rating }
        case .recent: q = stableSorted(q) { $0.addedAt > $1.addedAt }
        }
        return q.map(\.item)
    }
}
