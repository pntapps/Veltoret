import SwiftUI
import VeltoretKit
import VeltoretUI

/// Home (Windows HomePage / Android HomeScreen): header, status block, featured hero, panels, rows.
struct HomePage: View {
    @StateObject private var live = LiveQuery(tables: HomeModel.watchedTables, route: .home, watchScan: true) {
        try HomeModel.load()
    }

    var body: some View {
        GeometryReader { geo in
            let size = LibraryWidth(geo.size.width)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(size)
                    if let state = live.value, !state.online, !state.isEmpty { offlineNote(size) }
                    status
                    if let state = live.value {
                        if !state.featured.isEmpty {
                            FeaturedPager(items: state.featured, width: geo.size.width, gutter: size.gutter)
                                .vEntrance(0, key: "home.hero")
                        }
                        panels(state, size)
                        ForEach(state.rows) { row in
                            if row.title == "Continue Watching" {
                                rowView(row, size).vEntrance(1, key: "home.continue")
                            } else {
                                rowView(row, size)
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
        }
        .vPageBackground()
        .task { live.start() }
    }

    // MARK: Header

    private func header(_ size: LibraryWidth) -> some View {
        HStack(spacing: 8) {
            Wordmark()
            Spacer(minLength: 8)
            if live.scan.running {
                VScanChip(live.scan.phase.hasPrefix("Matching") ? "Matching" : "Syncing \(live.scan.filesFound)")
                    .transition(.opacity)
            }
            if let cast = LibraryHooks.castButton { cast() }
            VIconButton("magnifyingglass", help: "Search") { Navigator.shared.push(.search()) }
        }
        .animation(.easeInOut(duration: 0.2), value: live.scan.running)
        .padding(.leading, size.gutter)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
    }

    private func offlineNote(_ size: LibraryWidth) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amberSoft)
            Text("Offline · showing videos on this Mac").vLabelMedium(Theme.amberSoft).lineLimit(1)
        }
        .padding(.horizontal, size.gutter)
        .padding(.bottom, 12)
    }

    // MARK: Status block (first match wins)

    @ViewBuilder
    private var status: some View {
        let scan = live.scan
        if let state = live.value {
            if !state.hasFolders {
                VEmptyState(icon: "folder.badge.plus", title: "Choose your library folders",
                            message: "Pick the Google Drive or device folders that hold your movies and TV shows.",
                            actionTitle: "Open Settings") { Navigator.shared.selectTab(.settings) }
                    .padding(.top, 40)
            } else if state.isEmpty && scan.running {
                VEmptyState(icon: "rectangle.stack", title: "Building your library",
                            message: "Found \(scan.filesFound) videos so far. Posters will appear here as titles are matched.")
                    .padding(.top, 40)
            } else if state.isEmpty && !state.online {
                VEmptyState(icon: "icloud.slash", title: "Nothing on this device",
                            message: "Your library is on Google Drive. Connect to the internet to watch it, or add a folder from this device in Settings.")
                    .padding(.top, 40)
            } else if state.isEmpty {
                VEmptyState(icon: "rectangle.stack", title: "Nothing here yet",
                            message: Formats.nilIfEmpty(scan.error)
                                ?? "No videos were found in your library folders. Add files to Drive and scan again.",
                            actionTitle: "Scan now") { scanNow() }
                    .padding(.top, 40)
            }
        } else {
            VLoadingBox(height: 400)
        }
    }

    private func scanNow() {
        guard let scans = AppServices.scans else { return }
        Task { await scans.runNow() }
    }

    // MARK: Panels

    @ViewBuilder
    private func panels(_ state: HomeState, _ size: LibraryWidth) -> some View {
        if state.unmatchedCount > 0 && state.online {
            panel(icon: "exclamationmark.circle",
                  title: state.unmatchedCount == 1 ? "1 file needs a match" : "\(state.unmatchedCount) files need a match",
                  body: "Click to identify them on TMDB") { Navigator.shared.navigate(.fixMatch()) }
                .padding(.horizontal, size.gutter)
                .padding(.vertical, 12)
        }
        if state.archiveCount > 0 {
            panel(icon: "doc.zipper",
                  title: state.archiveCount == 1 ? "1 ZIP archive in your library" : "\(state.archiveCount) ZIP archives in your library",
                  body: "Click to unpack them so they can play") { Navigator.shared.navigate(.archives) }
                .padding(.horizontal, size.gutter)
                .padding(.vertical, 6)
        }
    }

    private func panel(icon: String, title: String, body: String, action: @escaping () -> Void) -> some View {
        VClickPanel(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.amber).frame(width: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).vTitleSmall().lineLimit(1)
                    Text(body).vBodySmall(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: Rows

    private func rowView(_ row: HomeRow, _ size: LibraryWidth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VSectionHeader(row.title, actionTitle: row.action, gutter: size.gutter,
                           action: row.actionRoute.map { r in { Navigator.shared.selectTab(r) } })
            if row.wide {
                let w = size.wideWidth
                HorizontalRow(row.plays, itemWidth: w, gutter: size.gutter, arrowCenter: w * 9 / 16 / 2) { item in
                    LibraryWideCard(item)
                }
            } else {
                let w = size.posterWidth
                HorizontalRow(row.posters.map(KeyedPoster.init), itemWidth: w, gutter: size.gutter, arrowCenter: w * 1.5 / 2) { k in
                    LibraryPosterCard(k.item)
                }
            }
        }
        .padding(.top, Theme.sectionSpacing)
    }
}
