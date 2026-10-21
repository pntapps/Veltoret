import Foundation
import VeltoretKit

/// The core services UpcomingService needs (TmdbRepository.ensureShow, Connectivity), read when used so the
/// order of module initialization doesn't matter.
enum PlansCoreBridge {
    /// Refetches /tv/{id} when older than UpcomingService.refreshMs (Windows: Tmdb.EnsureShow(id, {}, RefreshMs)).
    static func refreshShow(_ id: Int) async throws {
        guard let tmdb = AppServices.tmdb else { return }
        try await tmdb.ensureShow(id, seasons: [], maxAgeMs: UpcomingService.refreshMs)
    }

    static func isOnline() -> Bool { AppServices.connectivity?.isOnline ?? true }

    static func subscribeOnline(_ handler: @escaping (Bool) -> Void) -> Subscription? {
        AppServices.connectivity?.onlineChanged.subscribe(handler)
    }
}
