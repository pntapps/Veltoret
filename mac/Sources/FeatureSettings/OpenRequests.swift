import AppKit
import Foundation
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// Opens what a notification points at (Windows `ToastNotifier.Open`, Android HandleOpenRequests): shows the main
/// window, navigates to the title, and plays it for "Play". Requests are handled one at a time, in order, by a
/// single long-lived consumer, so navigating never cancels a playback lookup.
@MainActor
public enum OpenRequests {
    /// Shows (or re-creates) the main window. The app target may replace it (e.g. when the window was closed).
    public static var showMainWindow: @MainActor () -> Void = { ShellCommands.showMainWindow() }

    private static var queue: [OpenTarget] = []
    private static var running = false

    /// Opens the title's page (and plays it when `target.play`).
    public static func open(_ target: OpenTarget) {
        queue.append(target)
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await handle(next)
            }
            running = false
        }
    }

    private static func handle(_ target: OpenTarget) async {
        showMainWindow()
        let route: Route = target.mediaType == Plans.movie
            ? .movieDetail(movieId: target.mediaId)
            : .showDetail(showId: target.mediaId, season: target.season)
        Navigator.shared.navigate(route)
        guard target.play, let playback = AppServices.playback else { return }
        if target.mediaType == Plans.movie {
            await playback.playMovie(target.mediaId, startOver: false)
        } else if let s = target.season, let e = target.episode {
            await playback.playEpisode(showId: target.mediaId, season: s, episode: e, startOver: false)
        } else {
            await playback.playShow(target.mediaId)
        }
    }
}
