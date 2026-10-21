import Foundation
import VeltoretKit
import VeltoretUI

/// What Play buttons call (`AppServices.playback`). Picks the best copy (device first; offline only This Mac copies,
/// via PlaybackResolver), then opens it in the player window — reusing the open one, which saves the current video's
/// progress first. Resume position, next/previous episodes and the episode list are worked out by the player.
public final class VeltoretPlaybackLauncher: PlaybackLauncher, @unchecked Sendable {
    public init() {}

    public func playMovie(_ movieId: Int, startOver: Bool) async {
        let file = (try? AppServices.resolver.movieFile(movieId)) ?? nil
        if let file { Self.open(PlayerArgs(fileId: file.driveId, account: file.accountEmail, fromStart: startOver)) }
        else { Self.unavailable() }
    }

    public func playShow(_ showId: Int) async {
        let target = (try? AppServices.resolver.showPlayTarget(showId)) ?? nil
        if let target {
            Self.open(PlayerArgs(fileId: target.file.driveId, account: target.file.accountEmail, fromStart: false))
        } else { Self.unavailable() }
    }

    public func playEpisode(showId: Int, season: Int, episode: Int, startOver: Bool) async {
        let file = (try? AppServices.resolver.episodeFile(showId: showId, season: season, episode: episode)) ?? nil
        if let file { Self.open(PlayerArgs(fileId: file.driveId, account: file.accountEmail, fromStart: startOver)) }
        else { Self.unavailable() }
    }

    public func playFile(_ file: MediaFileEntity, startOver: Bool) async {
        Self.open(PlayerArgs(fileId: file.driveId, account: file.accountEmail, fromStart: startOver))
    }

    public func playItem(account: String, fileId: String, name: String) async {
        Self.open(PlayerArgs(fileId: fileId, account: account, title: name, fromStart: false))
    }

    /// Opens in the existing player window, or a new one. Any thread.
    public static func open(_ args: PlayerArgs) {
        Task { @MainActor in PlayerWindowController.open(args) }
    }

    /// Plays a video file on this Mac by path (Finder "Open With", drag and drop onto the Dock icon).
    public static func openLocalFile(_ url: URL) {
        open(PlayerArgs(fileId: url.path, account: Accounts.device, title: url.lastPathComponent, fromStart: false))
    }

    /// Nothing playable (offline with no copy on This Mac, or the files were removed): tell the user in-app.
    static func unavailable() {
        Task { @MainActor in Toast.show("This video isn't available right now") }
    }
}
