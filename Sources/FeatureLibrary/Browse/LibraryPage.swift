import SwiftUI
import VeltoretKit
import VeltoretUI

/// Filter state per screen, in memory (survives navigating away and back), as on Windows.
@MainActor
private final class LibraryMemory {
    var filter: WatchFilter = .all
    var genre: String?
    var sort: LibrarySort = .recent
    var source: String?
    static let movies = LibraryMemory()
    static let shows = LibraryMemory()
}

/// Movies / TV Shows grid with filter chips, genre, sort and source menus (Windows LibraryPage, spec §4).
struct LibraryPage: View {
    let shows: Bool
    @StateObject private var live: LiveQuery<LibraryData>
    @State private var filter: WatchFilter
    @State private var genre: String?
    @State private var sort: LibrarySort
    @State private var source: String?

    init(shows: Bool, genre: String?, route: Route) {
        self.shows = shows
        let mem = shows ? LibraryMemory.shows : LibraryMemory.movies
        if let genre { mem.genre = genre }
        _filter = State(initialValue: mem.filter)
        _genre = State(initialValue: mem.genre)
        _sort = State(initialValue: mem.sort)
        _source = State(initialValue: mem.source)
        _live = StateObject(wrappedValue: LiveQuery(tables: LibraryModel.watchedTables, route: route) {
            try LibraryModel.load(shows: shows)
        })
    }

    private var memory: LibraryMemory { shows ? LibraryMemory.shows : LibraryMemory.movies }
    private var title: String { shows ? "TV Shows" : "Movies" }

    /// A source or genre that disappeared falls back to all.
    private var effectiveSource: String? {
        guard let source, let data = live.value, data.sources.contains(where: { $0.account == source }) else { return nil }
        return source
    }
    private var effectiveGenre: String? {
        guard let genre, let data = live.value, data.genres.contains(genre) else { return nil }
        return genre
    }

    private var shown: [PosterItem] {
        guard let data = live.value else { return [] }
        return LibraryModel.apply(data.all, filter: filter, genre: effectiveGenre, sort: sort, source: effectiveSource)
    }

    var body: some View {
        GeometryReader { geo in
            let size = LibraryWidth(geo.size.width)
            let items = shown
            VStack(spacing: 0) {
                VScreenHeader(title, subtitle: subtitle(items.count)) {
                    VIconButton("magnifyingglass", help: "Search") { Navigator.shared.push(.search()) }
                    VIconButton("arrow.up.arrow.down", help: "Sort") { showSortMenu() }
                }
                content(items, size)
            }
        }
        .vPageBackground()
        .task { live.start() }
    }

    private func subtitle(_ shownCount: Int) -> String? {
        guard let data = live.value else { return nil }
        let total = data.all.count
        if let src = effectiveSource, let label = data.sources.first(where: { $0.account == src })?.label {
            return "\(shownCount) of \(total) titles · \(label)"
        }
        return total == 1 ? "1 title" : "\(total) titles"
    }

    @ViewBuilder
    private func content(_ items: [PosterItem], _ size: LibraryWidth) -> some View {
        if let data = live.value {
            let lower = title.lowercased()
            if data.all.isEmpty && !data.online {
                VEmptyState(icon: "icloud.slash", title: "No \(lower) on this device",
                            message: "Your \(lower) are on Google Drive. Connect to the internet to watch them, or add a folder from this device in Settings.")
            } else if data.all.isEmpty && data.unmatched == 0 {
                VEmptyState(icon: shows ? "tv" : "film", title: "No \(lower) yet",
                            message: "Add a \(lower) folder in Settings, or wait for the library scan to finish.")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        chips(data)
                            .padding(.horizontal, size.gutter)
                            .padding(.top, 4)
                            .padding(.bottom, 20)
                        if items.isEmpty {
                            Text("Nothing matches these filters.").vBodyMedium(Theme.textMuted)
                                .padding(.horizontal, size.gutter)
                                .padding(.vertical, 40)
                        } else {
                            VAdaptiveGrid(items.map(KeyedPoster.init), minItemWidth: minCell(size), hSpacing: 20, vSpacing: 28,
                                          gutter: size.gutter) { k in
                                LibraryPosterCard(k.item)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        } else {
            VLoadingBox()
        }
    }

    private func minCell(_ size: LibraryWidth) -> CGFloat {
        switch size { case .expanded: return 156; case .medium: return 140; case .compact: return 108 }
    }

    // MARK: Chips and menus

    private func chips(_ data: LibraryData) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            if data.unmatched > 0 && data.online {
                VChip("\(data.unmatched) unmatched", icon: "exclamationmark.circle", selected: false) {
                    Navigator.shared.navigate(.fixMatch())
                }
            }
            ForEach(WatchFilter.allCases, id: \.self) { f in
                VChip(f.label, selected: filter == f) { setFilter(f) }
            }
            if !data.genres.isEmpty {
                VChip(effectiveGenre ?? "Genre", icon: "slider.horizontal.3", selected: effectiveGenre != nil) {
                    showGenreMenu(data)
                }
            }
        }
    }

    private func setFilter(_ f: WatchFilter) { filter = f; memory.filter = f }
    private func setGenre(_ g: String?) { genre = g; memory.genre = g }
    private func setSort(_ s: LibrarySort) { sort = s; memory.sort = s }
    private func setSource(_ s: String?) { source = s; memory.source = s }

    private func showGenreMenu(_ data: LibraryData) {
        let current = effectiveGenre
        var entries: [PopupMenu.Entry] = [.item("All genres", selected: current == nil, action: { setGenre(nil) })]
        for name in data.genres { entries.append(.item(name, selected: current == name, action: { setGenre(name) })) }
        PopupMenu.show(entries)
    }

    private func showSortMenu() {
        var entries: [PopupMenu.Entry] = LibrarySort.allCases.map { s in .item(s.label, selected: sort == s, action: { setSort(s) }) }
        if let sources = live.value?.sources, !sources.isEmpty {
            let current = effectiveSource
            entries.append(.separator)
            entries.append(.caption("SOURCE"))
            entries.append(.item("All sources", selected: current == nil, action: { setSource(nil) }))
            for src in sources {
                entries.append(.item(src.label, selected: current == src.account, action: { setSource(src.account) }))
            }
        }
        PopupMenu.show(entries)
    }
}
