import Foundation

/// Downloads library artwork into the image cache after a scan, so posters and backdrops show up offline even for
/// titles the user never scrolled to. Uses exactly the URLs the screens request (the cache is keyed by URL) and
/// skips anything already cached. Any screen that changes an image size must update this list.
public final class ArtworkPrefetch: @unchecked Sendable {
    private let catalog: CatalogDao
    private let prefetch: ([String]) async -> Void

    /// `prefetch` downloads the URLs into the image cache (wire it to `ImageCache.prefetch`).
    public init(catalog: CatalogDao, prefetch: @escaping ([String]) async -> Void) {
        self.catalog = catalog
        self.prefetch = prefetch
    }

    /// Same URLs as `TmdbImages` builds (poster w342/w500, backdrop w1280/w780, still w300).
    static let imageBase = "https://image.tmdb.org/t/p/"
    static func image(_ path: String?, _ size: String) -> String? { path.map { imageBase + size + $0 } }

    public func urls() throws -> [String] {
        let movies = try catalog.movies()
        let shows = try catalog.shows()
        var urls: [String?] = []
        for m in movies {
            urls.append(Self.image(m.movie.posterPath, "w342"))      // grids, rows, search
            urls.append(Self.image(m.movie.posterPath, "w500"))      // detail page
            urls.append(Self.image(m.movie.backdropPath, "w1280"))   // detail page, featured
            urls.append(Self.image(m.movie.backdropPath, "w780"))    // Continue Watching
        }
        for s in shows {
            urls.append(Self.image(s.show.posterPath, "w342"))
            urls.append(Self.image(s.show.posterPath, "w500"))
            urls.append(Self.image(s.show.backdropPath, "w1280"))
            urls.append(Self.image(s.show.backdropPath, "w780"))
        }
        // Episode stills for shows that can play offline.
        let offlineShows = Set(shows.filter { $0.deviceEpisodes > 0 }.map { $0.show.tmdbId })
        if !offlineShows.isEmpty {
            for ep in try catalog.allEpisodes() where offlineShows.contains(ep.showId) {
                urls.append(Self.image(ep.stillPath, "w300"))
            }
        }
        var seen = Set<String>()
        return urls.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    public func run() async throws {
        await prefetch(try urls())
    }
}
