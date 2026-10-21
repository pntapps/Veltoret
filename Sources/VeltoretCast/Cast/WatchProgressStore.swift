import Foundation
import VeltoretKit

/// Saves cast progress into the watch state through the core WatchRepository (watched at ≥ 92% or < 2 minutes left,
/// keyed by WatchKeys), so casting and the Mac resume each other.
public final class WatchProgressStore: CastProgressStore, @unchecked Sendable {
    private let repository: () -> WatchRepository

    /// Default: `AppServices.watch` (or one over `AppServices.watchDao` before core is initialized, e.g. in tests).
    public init(repository: @escaping () -> WatchRepository = { AppServices.watch ?? WatchRepository(AppServices.watchDao) }) {
        self.repository = repository
    }

    public func savePosition(file: MediaFileEntity?, fallbackFileId: String, positionMs: Int64, durationMs: Int64) async throws {
        try repository().savePosition(file, fallbackFileId: fallbackFileId, positionMs: positionMs, durationMs: durationMs)
    }

    public func saved(for file: MediaFileEntity) async throws -> WatchStateEntity? {
        try repository().get(WatchKeys.forFile(file))
    }
}
