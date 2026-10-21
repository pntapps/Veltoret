import SwiftUI
import VeltoretKit
import VeltoretUI

/// What the collection page shows from the library.
struct CollectionData: Sendable {
    var owned: [MovieEntity]
    var states: [String: WatchStateEntity]
}

/// Collection page (Windows CollectionPage / Android CollectionScreen): owned parts link to the movie, the rest
/// are dimmed. Closes itself when no owned movie is left.
struct CollectionPage: View {
    let collectionId: Int
    let route: Route
    @StateObject private var live: LiveQuery<CollectionData>
    @State private var tmdb: TmdbCollection?
    @State private var tmdbTried = false

    init(collectionId: Int, route: Route) {
        self.collectionId = collectionId
        self.route = route
        let id = collectionId
        _live = StateObject(wrappedValue: LiveQuery(tables: ["movies", "media_files", "watch_state"], route: route) {
            let owned = try AppServices.library.movies().map(\.movie).filter { $0.collectionId == id }
            let sorted = stableSorted(owned) {
                (Formats.nilIfEmpty($0.releaseDate) ?? "9999") < (Formats.nilIfEmpty($1.releaseDate) ?? "9999")
            }
            return CollectionData(owned: sorted, states: PosterItems.statesByKey(try AppServices.watch.all()))
        })
    }

    var body: some View {
        GeometryReader { geo in
            let size = LibraryWidth(geo.size.width)
            if let data = live.value, !data.owned.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(data, width: geo.size.width)
                        VSectionHeader("Movies", gutter: size.gutter)
                            .padding(.top, 28)
                            .padding(.bottom, 12)
                        grid(parts(data), size)
                        Text("Metadata and artwork from TMDB").vBodySmall(Theme.textFaint)
                            .padding(.leading, size.gutter)
                            .padding(.top, 32)
                    }
                    .padding(.bottom, 40)
                }
            } else {
                VLoadingBox()
            }
        }
        .vPageBackground()
        .task { live.start() }
        .onChange(of: live.value?.owned.count) { _, count in
            if count == 0 && Navigator.shared.current?.route == route { Navigator.shared.goBack() }
        }
        .task(id: live.value == nil) { await loadTmdb() }
    }

    private func loadTmdb() async {
        guard !tmdbTried, live.value != nil, AppServices.connectivity?.isOnline ?? false, let repo = AppServices.tmdb else { return }
        tmdbTried = true
        let id = collectionId
        if let c = try? await Task.detached(operation: { try await repo.collection(id) }).value {
            tmdb = c
        }
    }

    // MARK: Parts

    private func parts(_ data: CollectionData) -> [PosterItem] {
        var ownedById: [Int: MovieEntity] = [:]
        for m in data.owned { ownedById[m.tmdbId] = m }
        func poster(_ m: MovieEntity) -> PosterItem { PosterItems.movie(m, data.states[WatchKeys.movie(m.tmdbId)]) }
        guard let tmdb, !tmdb.parts.isEmpty else { return data.owned.map(poster) }
        let sortedParts = stableSorted(tmdb.parts) {
            (Formats.nilIfEmpty($0.releaseDate) ?? "9999") < (Formats.nilIfEmpty($1.releaseDate) ?? "9999")
        }
        var list = sortedParts.map { p -> PosterItem in
            if let m = ownedById[p.id] { return poster(m) }
            let year = TmdbRepository.yearOf(p.releaseDate)
            return PosterItem(id: p.id, title: p.title,
                              subtitle: Formats.joinTight(year.map(String.init), "Not in your library"),
                              posterUrl: TmdbImages.poster(p.posterPath), clickable: false)
        }
        // Owned movies TMDB doesn't list (rare) still appear.
        let listed = Set(tmdb.parts.map(\.id))
        list += data.owned.filter { !listed.contains($0.tmdbId) }.map(poster)
        return list
    }

    private func grid(_ items: [PosterItem], _ size: LibraryWidth) -> some View {
        let cols = size == .expanded ? 6 : size == .medium ? 4 : 3
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: cols),
                         alignment: .leading, spacing: 20) {
            ForEach(items.map(KeyedPoster.init)) { LibraryPosterCard($0.item) }
        }
        .padding(.horizontal, size.gutter)
    }

    // MARK: Header (DetailHeader: info | backdrop with the poster hanging below it)

    @ViewBuilder
    private func header(_ data: CollectionData, width: CGFloat) -> some View {
        let first = data.owned[0]
        let name = Formats.nilIfEmpty(tmdb?.name) ?? first.collectionName ?? first.title
        let backdrop = TmdbImages.backdrop(tmdb?.backdropPath ?? first.backdropPath)
        let poster = TmdbImages.poster(tmdb?.posterPath ?? first.posterPath, "w500")
        let narrow = width < 720
        let info = VStack(alignment: .leading, spacing: 0) {
            VIconButton("chevron.left", help: "Back") { Navigator.shared.goBack() }
            VStack(alignment: .leading, spacing: 0) {
                Text(name).vDisplaySmall().fixedSize(horizontal: false, vertical: true)
                VPill(tmdb.map { !$0.parts.isEmpty } == true
                      ? "\(data.owned.count) of \(tmdb!.parts.count) in your library"
                      : "\(data.owned.count) in your library", style: .accent)
                    .padding(.top, 12)
                if let overview = Formats.nilIfEmpty(tmdb?.overview) {
                    Text(overview).vBodyLarge().opacity(0.88).padding(.top, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 24)
        }
        let art = artwork(backdrop: backdrop, poster: poster, title: name)
        if narrow {
            VStack(alignment: .leading, spacing: 0) {
                info
                art.padding(.top, 24).padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
        } else {
            let available = max(0, width - 80 - 40)
            HStack(alignment: .top, spacing: 40) {
                info.frame(width: available / 2.1, alignment: .leading)
                art.frame(width: available * 1.1 / 2.1)
                    .padding(.top, 58)
                    .padding(.bottom, 48)
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
    }

    private func artwork(backdrop: String?, poster: String?, title: String) -> some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(ArtworkImage(url: backdrop, fallbackText: title, cornerRadius: Theme.Radius.detailBackdrop,
                                  outlined: true, maxPixel: 1600))
            .vEntrance(1, key: "collection.\(collectionId).backdrop")
            .overlay(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay(ArtworkImage(url: poster, fallbackText: title, cornerRadius: Theme.Radius.poster, maxPixel: 400))
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.background))
                    .frame(width: 124 + 4)
                    .padding(.leading, 20)
                    .offset(y: 48)
                    .vEntrance(2, key: "collection.\(collectionId).poster")
            }
    }
}
