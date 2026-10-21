import Foundation
import VeltoretKit
import VeltoretUI

/// A title in the featured hero.
struct FeaturedItem: Hashable, Identifiable, Sendable {
    var id: Int
    var isShow: Bool
    var title: String
    var backdropUrl: String?
    /// Meta parts joined with "  ·  ".
    var meta: String
    var overview: String
    var rating: Double

    var key: String { (isShow ? "s" : "m") + String(id) }
    var route: Route { isShow ? .showDetail(showId: id) : .movieDetail(movieId: id) }
}

/// One Home shelf: poster or wide cards.
struct HomeRow: Hashable, Identifiable, Sendable {
    var title: String
    var wide: Bool
    var posters: [PosterItem] = []
    var plays: [PlayItem] = []
    var action: String? = nil
    var actionRoute: Route? = nil

    var id: String { title }
    var isEmpty: Bool { wide ? plays.isEmpty : posters.isEmpty }
}

/// Everything Home shows, computed in one pass (Windows HomeViewModel / Android row logic, spec §3.3).
struct HomeState: Sendable {
    var hasFolders = false
    var isEmpty = false
    var online = true
    var unmatchedCount = 0
    var archiveCount = 0
    var featured: [FeaturedItem] = []
    var rows: [HomeRow] = []
}

enum HomeModel {
    static let watchedTables = ["movies", "shows", "media_files", "watch_state", "watchlist", "episodes",
                                "library_folders", "archive_files"]

    /// Loads and computes Home (call off the main thread).
    static func load() throws -> HomeState {
        let lib = AppServices.library!
        let online = AppServices.connectivity?.isOnline ?? true
        let movies = try lib.movies()
        let shows = try lib.shows()
        let states = try AppServices.watch.all()
        let files = try lib.episodeFiles()
        let episodes = try lib.allEpisodes()
        let unmatched = try lib.unmatched()
        let archives = try lib.archives()
        let folders = try lib.folders()
        let watchlist: [WatchlistEntity]
        if let plans = AppServices.plans, let list = try? plans.watchlist() { watchlist = list }
        else { watchlist = try AppServices.plansDao.watchlist() }
        return compute(movies: movies, shows: shows, states: states, episodeFiles: files, episodes: episodes,
                       watchlist: watchlist, unmatched: unmatched.count, archives: archives.count,
                       hasFolders: !folders.isEmpty, online: online)
    }

    private struct EpKey: Hashable { let show: Int; let season: Int; let episode: Int }

    static func compute(movies: [MovieRow], shows: [ShowRow], states: [WatchStateEntity], episodeFiles: [MediaFileEntity],
                        episodes: [EpisodeEntity], watchlist: [WatchlistEntity], unmatched: Int, archives: Int,
                        hasFolders: Bool, online: Bool, now: Date = Date()) -> HomeState {
        let stateByKey = PosterItems.statesByKey(states)
        var movieById: [Int: MovieRow] = [:]
        for m in movies { movieById[m.movie.tmdbId] = m }
        var showById: [Int: ShowRow] = [:]
        for s in shows { showById[s.show.tmdbId] = s }
        var episodeByKey: [EpKey: EpisodeEntity] = [:]
        for e in episodes { episodeByKey[EpKey(show: e.showId, season: e.seasonNumber, episode: e.episodeNumber)] = e }
        func movieState(_ id: Int) -> WatchStateEntity? { stateByKey[WatchKeys.movie(id)] }
        func moviePoster(_ r: MovieRow) -> PosterItem { PosterItems.movie(r.movie, movieState(r.movie.tmdbId)) }
        func showPoster(_ r: ShowRow) -> PosterItem { PosterItems.show(r.show, r.availableEpisodes) }

        // ---- Featured ----
        enum Entry { case movie(MovieRow), show(ShowRow) }
        var merged: [(added: Int64, entry: Entry)] = movies.map { ($0.addedAt, .movie($0)) } + shows.map { ($0.addedAt, .show($0)) }
        merged = stableSorted(merged) { $0.added > $1.added }
        var featuredAll: [FeaturedItem] = []
        for x in merged {
            switch x.entry {
            case .show(let s):
                guard s.show.backdropPath != nil else { continue }
                featuredAll.append(FeaturedItem(
                    id: s.show.tmdbId, isShow: true, title: s.show.name, backdropUrl: TmdbImages.backdrop(s.show.backdropPath),
                    meta: Formats.join(s.show.year.map(String.init), s.show.certification, firstGenre(s.show.genres),
                                       s.show.seasonCount > 0 ? Formats.seasons(s.show.seasonCount) : nil),
                    overview: s.show.overview, rating: s.show.rating))
            case .movie(let m):
                guard m.movie.backdropPath != nil, movieState(m.movie.tmdbId)?.watched != true else { continue }
                featuredAll.append(FeaturedItem(
                    id: m.movie.tmdbId, isShow: false, title: m.movie.title, backdropUrl: TmdbImages.backdrop(m.movie.backdropPath),
                    meta: Formats.join(m.movie.year.map(String.init), m.movie.certification, firstGenre(m.movie.genres),
                                       Formats.runtime(m.movie.runtimeMin)),
                    overview: m.movie.overview, rating: m.movie.rating))
            }
        }
        let good = featuredAll.filter { $0.rating >= 5.5 }
        let featured = Array((good.isEmpty ? featuredAll : good).prefix(6))

        // ---- Continue Watching ----
        var fileKeys = Set<EpKey>()
        var filesByShow: [Int: [MediaFileEntity]] = [:]
        var showOrder: [Int] = []
        for f in episodeFiles {
            guard let sid = f.showId else { continue }
            if let se = f.season, let ep = f.episode { fileKeys.insert(EpKey(show: sid, season: se, episode: ep)) }
            if filesByShow[sid] == nil { showOrder.append(sid) }
            filesByShow[sid, default: []].append(f)
        }
        func stillOrBackdrop(_ show: ShowEntity, _ season: Int, _ episode: Int) -> String? {
            if let e = episodeByKey[EpKey(show: show.tmdbId, season: season, episode: episode)], e.stillPath != nil {
                return TmdbImages.still(e.stillPath, "w780")
            }
            return TmdbImages.backdrop(show.backdropPath, "w780")
        }
        func episodeSubtitle(_ showId: Int, _ season: Int, _ episode: Int) -> String {
            Formats.join(Formats.episodeCode(season, episode), episodeByKey[EpKey(show: showId, season: season, episode: episode)]?.name)
        }

        var continueItems: [PlayItem] = []
        let resumable = stableSorted(states.filter { !$0.watched && $0.positionMs > 30_000 && $0.lastFileId != nil }) {
            $0.lastWatchedAt > $1.lastWatchedAt
        }
        for s in resumable {
            if let mid = s.movieId {
                guard let row = movieById[mid] else { continue }
                continueItems.append(PlayItem(
                    fileId: s.lastFileId!, title: row.movie.title,
                    subtitle: Formats.remaining(positionMs: s.positionMs, durationMs: s.durationMs),
                    imageUrl: TmdbImages.backdrop(row.movie.backdropPath, "w780"), progress: Double(s.progress), movieId: mid))
            } else if let sid = s.showId, let se = s.season, let ep = s.episode {
                guard fileKeys.contains(EpKey(show: sid, season: se, episode: ep)), let show = showById[sid] else { continue }
                continueItems.append(PlayItem(
                    fileId: s.lastFileId!, title: show.show.name, subtitle: episodeSubtitle(sid, se, ep),
                    imageUrl: stillOrBackdrop(show.show, se, ep), progress: Double(s.progress),
                    caption: Formats.remaining(positionMs: s.positionMs, durationMs: s.durationMs),
                    showId: sid, season: se, episode: ep))
            }
            if continueItems.count >= 20 { break }
        }

        // ---- Next Up ----
        let inContinue = Set(continueItems.compactMap(\.showId))
        var statesByShow: [Int: [WatchStateEntity]] = [:]
        for s in states { if let sid = s.showId { statesByShow[sid, default: []].append(s) } }
        var nextUp: [(last: Int64, item: PlayItem)] = []
        for sid in showOrder {
            guard let files = filesByShow[sid], !inContinue.contains(sid) else { continue }
            let showStates = statesByShow[sid] ?? []
            guard showStates.contains(where: \.watched) else { continue }
            guard let target = PlayTargets.nextEpisode(files, showStates), let show = showById[sid],
                  let se = target.file.season, let ep = target.file.episode else { continue }
            nextUp.append((showStates.map(\.lastWatchedAt).max() ?? 0, PlayItem(
                fileId: target.file.driveId, title: show.show.name, subtitle: episodeSubtitle(sid, se, ep),
                imageUrl: stillOrBackdrop(show.show, se, ep), caption: "Next", showId: sid, season: se, episode: ep)))
        }
        let nextUpItems = stableSorted(nextUp) { $0.last > $1.last }.prefix(20).map(\.item)

        // ---- Watchlist ----
        var watchlistItems: [PosterItem] = []
        for w in watchlist {
            if w.mediaType == "movie" {
                if let m = movieById[w.mediaId], movieState(w.mediaId)?.watched != true { watchlistItems.append(moviePoster(m)) }
            } else if let s = showById[w.mediaId] {
                watchlistItems.append(showPoster(s))
            }
        }

        // ---- Coming Up ----
        var followed = Set(watchlist.filter { $0.mediaType == "tv" }.map(\.mediaId))
        for s in states { if let id = s.showId { followed.insert(id) } }
        let today = Calendar.current.startOfDay(for: now)
        let upcoming: [(row: ShowRow, date: Date)] = shows.compactMap { s in
            guard followed.contains(s.show.tmdbId), let d = Formats.parseDate(s.show.nextEpisodeAirDate), d >= today else { return nil }
            return (s, d)
        }
        let comingUp = stableSorted(upcoming) { $0.date < $1.date }.map { x -> PosterItem in
            var item = PosterItems.show(x.row.show, x.row.availableEpisodes, badge: Formats.airLabel(x.date, now: now))
            // The next episode's code, or nothing (not "n episodes").
            item.subtitle = Formats.nilIfEmpty(Formats.episodeCode(x.row.show.nextEpisodeSeason, x.row.show.nextEpisodeNumber))
            return item
        }

        // ---- Recently added / updated ----
        let recentMovies = stableSorted(movies) { $0.addedAt > $1.addedAt }.prefix(20).map(moviePoster)
        let recentShows = stableSorted(shows) { $0.addedAt > $1.addedAt }.prefix(20).map(showPoster)

        // ---- Highly Rated ----
        let ratedAll: [(rating: Double, item: PosterItem)] =
            movies.filter { $0.movie.rating >= 7.0 }.map { ($0.movie.rating, moviePoster($0)) } +
            shows.filter { $0.show.rating >= 7.0 }.map { ($0.show.rating, showPoster($0)) }
        var rated = stableSorted(ratedAll) { $0.rating > $1.rating }.prefix(20).map(\.item)
        if rated.count < 4 { rated = [] }

        // ---- Collections ----
        var groups: [Int: [MovieRow]] = [:]
        var groupOrder: [Int] = []
        for m in movies {
            guard let cid = m.movie.collectionId else { continue }
            if groups[cid] == nil { groupOrder.append(cid) }
            groups[cid, default: []].append(m)
        }
        let collectionsAll: [(added: Int64, item: PosterItem)] = groupOrder.compactMap { cid in
            let g = groups[cid]!
            guard g.count >= 2 else { return nil }
            var latest = g[0]
            for m in g.dropFirst() where (m.movie.releaseDate ?? "") > (latest.movie.releaseDate ?? "") { latest = m }
            let first = g[0]
            return (g.map(\.addedAt).max() ?? 0, PosterItem(
                id: cid, isCollection: true, title: first.movie.collectionName ?? first.movie.title,
                subtitle: Formats.plural(g.count, "movie", "movies"), posterUrl: TmdbImages.poster(latest.movie.posterPath)))
        }
        let collections = stableSorted(collectionsAll) { $0.added > $1.added }.map(\.item)

        // ---- Genre rows ----
        var byGenre: [String: [(rating: Double, item: PosterItem)]] = [:]
        var genreOrder: [String] = []
        func addGenres(_ genres: String, _ rating: Double, _ item: PosterItem) {
            for g in genres.split(separator: ",") {
                let name = g.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                if byGenre[name] == nil { genreOrder.append(name) }
                byGenre[name, default: []].append((rating, item))
            }
        }
        for m in movies { addGenres(m.movie.genres, m.movie.rating, moviePoster(m)) }
        for s in shows { addGenres(s.show.genres, s.show.rating, showPoster(s)) }
        let genreRows = stableSorted(genreOrder.filter { byGenre[$0]!.count >= 4 }) { byGenre[$0]!.count > byGenre[$1]!.count }
            .prefix(5)
            .map { name in
                HomeRow(title: name, wide: false,
                        posters: stableSorted(byGenre[name]!) { $0.rating > $1.rating }.prefix(20).map(\.item))
            }

        var rows: [HomeRow] = []
        func add(_ row: HomeRow) { if !row.isEmpty { rows.append(row) } }
        add(HomeRow(title: "Continue Watching", wide: true, plays: continueItems))
        add(HomeRow(title: "Next Up", wide: true, plays: Array(nextUpItems)))
        add(HomeRow(title: "Watchlist", wide: false, posters: watchlistItems))
        add(HomeRow(title: "Coming Up", wide: false, posters: comingUp))
        add(HomeRow(title: "Recently Added Movies", wide: false, posters: Array(recentMovies), action: "See all", actionRoute: .movies()))
        add(HomeRow(title: "Recently Updated Shows", wide: false, posters: Array(recentShows), action: "See all", actionRoute: .shows()))
        add(HomeRow(title: "Highly Rated", wide: false, posters: Array(rated)))
        add(HomeRow(title: "Collections", wide: false, posters: collections))
        rows.append(contentsOf: genreRows)

        return HomeState(hasFolders: hasFolders, isEmpty: recentMovies.isEmpty && recentShows.isEmpty, online: online,
                         unmatchedCount: unmatched, archiveCount: archives, featured: featured, rows: rows)
    }

    private static func firstGenre(_ genres: String) -> String? {
        let first = genres.split(separator: ",", omittingEmptySubsequences: false).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return Formats.nilIfEmpty(first)
    }
}

/// A stable sort (C# OrderBy / Kotlin sortedBy keep equal elements in order; Swift's `sorted` doesn't promise it).
func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
        if areInIncreasingOrder(a.element, b.element) { return true }
        if areInIncreasingOrder(b.element, a.element) { return false }
        return a.offset < b.offset
    }.map(\.element)
}
