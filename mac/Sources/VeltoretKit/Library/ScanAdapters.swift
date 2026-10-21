import Foundation

/// The real TMDB repository behind the scanner's `TmdbMatching` seam.
extension TmdbRepository: TmdbMatching {
    public func matchMovie(title: String, year: Int?, exactOnly: Bool) async throws -> Int? {
        try await findMovie(title: title, year: year, exactOnly: exactOnly)?.id
    }

    public func matchShow(title: String, year: Int?, exactOnly: Bool) async throws -> Int? {
        try await findShow(title: title, year: year, exactOnly: exactOnly)?.id
    }

    public func fetchMovie(_ id: Int) async throws { try await ensureMovie(id) }

    public func fetchShow(_ id: Int, seasons: Set<Int>) async throws { try await ensureShow(id, seasons: seasons) }

    public func fetchRecommendations(type: String, id: Int) async throws { try await ensureRecommendations(type: type, id: id) }

    public func isFatal(_ error: Error) -> Bool { error is TmdbKeyMissingError }
}
