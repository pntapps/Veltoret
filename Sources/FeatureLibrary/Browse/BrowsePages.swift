import SwiftUI
import VeltoretKit
import VeltoretUI

/// Registers the browse pages: home, movies, shows, search, collection (library-browse).
enum BrowsePages {
    @MainActor static func register() {
        _ = WatchlistMarks.shared
        PageRegistry.register(.home) { _ in AnyView(HomePage()) }
        PageRegistry.register(.movies) { route in
            guard case .movies(let genre) = route else { return nil }
            return AnyView(LibraryPage(shows: false, genre: genre, route: route))
        }
        PageRegistry.register(.shows) { route in
            guard case .shows(let genre) = route else { return nil }
            return AnyView(LibraryPage(shows: true, genre: genre, route: route))
        }
        PageRegistry.register(.search) { route in
            guard case .search(let query, let spoken) = route else { return nil }
            return AnyView(SearchPage(query: query, spoken: spoken, route: route))
        }
        PageRegistry.register(.collection) { route in
            guard case .collection(let id) = route else { return nil }
            return AnyView(CollectionPage(collectionId: id, route: route))
        }
    }
}
