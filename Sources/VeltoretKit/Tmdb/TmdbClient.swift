import Foundation

/// No TMDB key is set (Settings → TMDB). Network-problem handlers can treat it like any `TmdbError`.
public struct TmdbKeyMissingError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public init() {}
    public var description: String { "Add your TMDB API key in Settings to fetch posters and details" }
    public var errorDescription: String? { description }
}

/// A TMDB request that failed (HTTP status or unreadable response). `statusCode` is nil for non-HTTP failures.
public struct TmdbError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public let statusCode: Int?
    public init(_ message: String, statusCode: Int? = nil) { self.message = message; self.statusCode = statusCode }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// TMDB v3 over URLSession (Android TmdbApi + TmdbAuthInterceptor, Windows TmdbClient). Accepts a v3 API key (sent
/// as `api_key`) or a v4 "API Read Access Token" (a JWT starting with "eyJ", sent as a bearer token). Every request
/// is pinned to English (US).
public final class TmdbClient: @unchecked Sendable {
    public static let baseUrl = "https://api.themoviedb.org/3/"

    private let session: URLSession
    private let key: () -> String

    public init(session: URLSession = TmdbClient.makeSession(), keyProvider: @escaping () -> String) {
        self.session = session
        self.key = keyProvider
    }

    /// Sensible timeouts (Android: connect 20 s, read 30 s).
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// snake_case JSON → camelCase properties (Windows: TmdbClient.Json).
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public func searchMovie(_ query: String, year: Int? = nil) async throws -> TmdbPage<TmdbMovieSummary> {
        try await get("search/movie", [("query", query), ("year", Self.num(year)), ("include_adult", "false")])
    }

    public func searchTv(_ query: String, year: Int? = nil) async throws -> TmdbPage<TmdbTvSummary> {
        try await get("search/tv", [("query", query), ("first_air_date_year", Self.num(year)), ("include_adult", "false")])
    }

    public func movie(_ id: Int) async throws -> TmdbMovieDetail {
        try await get("movie/\(id)", [("append_to_response", "credits,release_dates")])
    }

    public func tv(_ id: Int) async throws -> TmdbTvDetail {
        try await get("tv/\(id)", [("append_to_response", "credits,content_ratings")])
    }

    public func movieRecommendations(_ id: Int, page: Int = 1) async throws -> TmdbPage<TmdbMovieSummary> {
        try await get("movie/\(id)/recommendations", [("page", Self.num(page))])
    }

    public func tvRecommendations(_ id: Int, page: Int = 1) async throws -> TmdbPage<TmdbTvSummary> {
        try await get("tv/\(id)/recommendations", [("page", Self.num(page))])
    }

    public func collection(_ id: Int) async throws -> TmdbCollection { try await get("collection/\(id)", []) }
    public func movieVideos(_ id: Int) async throws -> TmdbVideos { try await get("movie/\(id)/videos", []) }
    public func tvVideos(_ id: Int) async throws -> TmdbVideos { try await get("tv/\(id)/videos", []) }

    public func season(_ id: Int, _ season: Int) async throws -> TmdbSeasonDetail {
        try await get("tv/\(id)/season/\(season)", [])
    }

    public func configuration() async throws { let _: TmdbAnyJson = try await get("configuration", []) }

    private static func num(_ n: Int?) -> String? { n.map { String($0) } }

    static func isBearerToken(_ key: String) -> Bool { key.hasPrefix("eyJ") }

    /// RFC 3986 unreserved characters only (.NET Uri.EscapeDataString).
    private static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s
    }()

    private static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    /// The request URL with language, and the api_key for v3 keys (exposed for tests).
    public static func buildUrl(_ path: String, key: String, _ query: [(String, String?)] = []) -> String {
        var out = baseUrl + path
        var first = true
        func add(_ name: String, _ value: String) {
            out += (first ? "?" : "&") + escape(name) + "=" + escape(value)
            first = false
        }
        for (name, value) in query { if let value { add(name, value) } }
        if !query.contains(where: { $0.0 == "language" }) { add("language", "en-US") }
        if !isBearerToken(key) { add("api_key", key) }
        return out
    }

    private func get<T: Decodable>(_ path: String, _ query: [(String, String?)]) async throws -> T {
        let key = key().trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { throw TmdbKeyMissingError() }
        guard let url = URL(string: Self.buildUrl(path, key: key, query)) else { throw TmdbError("TMDB request failed") }
        var request = URLRequest(url: url)
        if Self.isBearerToken(key) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            let message: String
            switch code {
            case 401: message = "TMDB didn't accept the API key (HTTP \(code))"
            case 404: message = "TMDB has no such title (HTTP \(code))"
            case 429: message = "TMDB is busy, try again in a moment (HTTP \(code))"
            default: message = "TMDB request failed (HTTP \(code))"
            }
            throw TmdbError(message, statusCode: code)
        }
        if data.isEmpty { throw TmdbError("TMDB sent an empty response") }
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw TmdbError("TMDB sent a response Veltoret couldn't read")
        }
    }
}
