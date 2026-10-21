import Foundation

/// "More like this": TMDB's recommendations for a title, narrowed to the ones in the library.
public enum RelatedTitles {
    public static let limit = 20

    /// Parses RecommendationEntity.recommendedIds.
    public static func parseIds(_ csv: String?) -> [Int] {
        (csv ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The recommended titles found in `library`, in TMDB's order, without `selfId` or repeats.
    public static func inLibrary<T, S: Sequence>(_ recommended: S, _ library: [Int: T], selfId: Int,
                                                 limit: Int = RelatedTitles.limit) -> [T] where S.Element == Int {
        var seen = Set<Int>()
        var out: [T] = []
        for id in recommended where id != selfId && seen.insert(id).inserted {
            guard let t = library[id] else { continue }
            if out.count >= limit { break }
            out.append(t)
        }
        return out
    }
}
