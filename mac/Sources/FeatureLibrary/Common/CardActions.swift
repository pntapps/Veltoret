import SwiftUI
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// What cards do (port of Windows `CardActions`, plus the Mac context menus): play, open details, Watchlist,
/// watched, Fix match. Everything is safe to call before the player / plans modules exist (it toasts instead).
@MainActor
public enum CardActions {
    // MARK: Playback

    private static var launcher: PlaybackLauncher? {
        guard let p = AppServices.playback else {
            Toast.show("Playback isn't available yet")
            return nil
        }
        return p
    }

    public static func playMovie(_ id: Int, startOver: Bool = false) {
        guard let p = launcher else { return }
        Task { await p.playMovie(id, startOver: startOver) }
    }

    public static func playShow(_ id: Int) {
        guard let p = launcher else { return }
        Task { await p.playShow(id) }
    }

    public static func playEpisode(showId: Int, season: Int, episode: Int, startOver: Bool = false) {
        guard let p = launcher else { return }
        Task { await p.playEpisode(showId: showId, season: season, episode: episode, startOver: startOver) }
    }

    /// Plays a poster's title: a movie, or what "Play" means for a show (collections open instead).
    public static func play(_ item: PosterItem) {
        if item.isCollection { open(item); return }
        if item.isShow { playShow(item.id) } else { playMovie(item.id) }
    }

    /// Plays a wide card's file (Continue Watching / Next Up); casts it when a TV is connected.
    public static func play(_ item: PlayItem) {
        guard let p = launcher else { return }
        Task {
            let fileId = item.fileId
            let file = try? await Task.detached { try AppServices.library.file(fileId) }.value
            if let file {
                if let cast = LibraryHooks.castIfConnected, await cast(file) { return }
                await p.playFile(file, startOver: false)
            } else if let m = item.movieId {
                await p.playMovie(m, startOver: false)
            } else if let s = item.showId, let se = item.season, let e = item.episode {
                await p.playEpisode(showId: s, season: se, episode: e, startOver: false)
            }
        }
    }

    // MARK: Navigation

    public static func open(_ item: PosterItem) {
        guard item.clickable else { return }
        Navigator.shared.navigate(item.route)
    }

    public static func openDetails(_ item: PlayItem) {
        if let r = item.detailRoute { Navigator.shared.navigate(r) }
    }

    /// Opens Fix match for every file of the title (Windows detail menu "Fix match").
    public static func fixMatch(_ item: PosterItem) {
        guard !item.isCollection else { return }
        let id = item.id, isShow = item.isShow, title = item.title
        Task {
            let files = (try? await Task.detached {
                isShow ? try AppServices.library.showFiles(id) : try AppServices.library.movieFiles(id)
            }.value) ?? []
            if files.isEmpty { Toast.show("No files to match"); return }
            Navigator.shared.navigate(.fixMatch(fileIds: files.map(\.driveId), kind: isShow ? "EPISODE" : "MOVIE", query: title))
        }
    }

    // MARK: Watchlist / watched

    /// Adds or removes a title from the Watchlist, with the detail page's toasts.
    public static func toggleWatchlist(type: String, id: Int) {
        let saved = WatchlistMarks.shared.contains(type: type, id: id)
        Task {
            do {
                try await Task.detached {
                    if let plans = AppServices.plans { try plans.setWatchlist(type: type, id: id, on: !saved) }
                    else { throw PlansMissing() }
                }.value
                WatchlistMarks.shared.set(type: type, id: id, on: !saved)
                Toast.show(saved ? "Removed from your Watchlist" : "Added to your Watchlist")
            } catch {
                Log.error(error, "watchlist")
                Toast.show("Couldn't update your Watchlist")
            }
        }
    }

    public static func setMovieWatched(_ id: Int, watched: Bool) {
        Task {
            do { try await Task.detached { try AppServices.watch.setMovieWatched(id, watched: watched) }.value }
            catch { Log.error(error, "watched"); Toast.show(error.localizedDescription) }
        }
    }

    private struct PlansMissing: Error {}
}

/// The Watchlist as a set, kept current from `db.changed("watchlist")`, so context menus can say "Watch later" or
/// "Remove from Watchlist" without querying per card.
@MainActor
public final class WatchlistMarks: ObservableObject {
    public static let shared = WatchlistMarks()
    @Published public private(set) var keys: Set<String> = []
    private let bag = SubscriptionBag()

    private init() {
        AppServices.db?.changed.subscribe { [weak self] tables in
            guard tables.contains("watchlist") else { return }
            Task { @MainActor in self?.reload() }
        }.store(in: bag)
        reload()
    }

    public func contains(type: String, id: Int) -> Bool { keys.contains("\(type):\(id)") }

    func set(type: String, id: Int, on: Bool) {
        if on { keys.insert("\(type):\(id)") } else { keys.remove("\(type):\(id)") }
    }

    public func reload() {
        Task {
            let list = (try? await Task.detached { () throws -> [WatchlistEntity] in
                if let plans = AppServices.plans { return try plans.watchlist() }
                return try AppServices.plansDao?.watchlist() ?? []
            }.value) ?? []
            keys = Set(list.map { "\($0.mediaType):\($0.mediaId)" })
        }
    }
}

// MARK: - Context menus

public extension View {
    /// Right-click menu for a poster card: Play, Details, Watch later / Remove from Watchlist, Mark watched /
    /// unwatched (movies), Fix match. Collections get Open only; dimmed (not clickable) parts get nothing.
    func posterContextMenu(_ item: PosterItem) -> some View {
        modifier(PosterMenu(item: item))
    }
}

private struct PosterMenu: ViewModifier {
    let item: PosterItem
    @ObservedObject private var marks = WatchlistMarks.shared

    func body(content: Content) -> some View {
        if !item.clickable {
            content
        } else {
            content.contextMenu {
                if item.isCollection {
                    Button("Open collection") { CardActions.open(item) }
                } else {
                    let type = item.isShow ? "tv" : "movie"
                    let saved = marks.contains(type: type, id: item.id)
                    Button { CardActions.play(item) } label: { Label("Play", systemImage: "play.fill") }
                    Button { CardActions.open(item) } label: { Label("Details", systemImage: "info.circle") }
                    Divider()
                    Button { CardActions.toggleWatchlist(type: type, id: item.id) } label: {
                        Label(saved ? "Remove from Watchlist" : "Watch later", systemImage: saved ? "bookmark.fill" : "bookmark")
                    }
                    if !item.isShow {
                        if item.watched {
                            Button { CardActions.setMovieWatched(item.id, watched: false) } label: {
                                Label("Mark unwatched", systemImage: "arrow.uturn.backward")
                            }
                        } else {
                            Button { CardActions.setMovieWatched(item.id, watched: true) } label: {
                                Label("Mark watched", systemImage: "checkmark")
                            }
                        }
                    }
                    Divider()
                    Button { CardActions.fixMatch(item) } label: { Label("Fix match", systemImage: "pencil") }
                }
            }
        }
    }
}

/// A poster card with the standard context menu and keyboard focus ring (Space / Return opens).
public struct LibraryPosterCard: View {
    let item: PosterItem
    public init(_ item: PosterItem) { self.item = item }
    public var body: some View {
        PosterCard(item) { CardActions.open(item) }
            .posterContextMenu(item)
    }
}

/// A wide card (Continue Watching / Next Up) that plays its file; right-click offers Play / Details.
public struct LibraryWideCard: View {
    let item: PlayItem
    public init(_ item: PlayItem) { self.item = item }
    public var body: some View {
        WideCard(item, onDetails: item.detailRoute == nil ? nil : { CardActions.openDetails(item) }) {
            CardActions.play(item)
        }
    }
}
