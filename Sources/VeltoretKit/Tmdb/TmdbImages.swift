import Foundation

/// TMDB image URLs. Keep sizes in step with ArtworkPrefetch so artwork is cached for offline use.
public enum TmdbImages {
    private static let base = "https://image.tmdb.org/t/p/"
    public static func poster(_ path: String?, _ size: String = "w342") -> String? { path.map { base + size + $0 } }
    public static func backdrop(_ path: String?, _ size: String = "w1280") -> String? { path.map { base + size + $0 } }
    public static func still(_ path: String?, _ size: String = "w300") -> String? { path.map { base + size + $0 } }
    public static func profile(_ path: String?, _ size: String = "w185") -> String? { path.map { base + size + $0 } }
    /// Network / company logos (PNG with transparency).
    public static func logo(_ path: String?, _ size: String = "w185") -> String? { path.map { base + size + $0 } }
}
