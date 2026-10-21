import Foundation
import SwiftUI
import VeltoretKit

/// What to open: a library file id (or a source file id), its account, a title hint, and "start over"
/// (Windows `PlayerArgs`).
public struct PlayerArgs: Hashable, Sendable {
    public var fileId: String
    public var account: String?
    public var title: String?
    public var fromStart: Bool

    public init(fileId: String, account: String?, title: String? = nil, fromStart: Bool = false) {
        self.fileId = fileId; self.account = account; self.title = title; self.fromStart = fromStart
    }
}

/// Slots other modules fill (they can't import each other; FeatureNetwork's `CastPlayerBridge` sets these).
@MainActor
public enum PlayerHooks {
    /// The Cast button shown in the player's top bar (`CastButton(onImage: true)`). Nil = no button.
    public static var castButton: (() -> AnyView)?
    /// Called (main actor) each time a player window opens, with its controller — the cast bridge hooks
    /// `videoChanged` there.
    public static var windowOpened: ((PlayerWindowController) -> Void)?
}

/// Side panels (Windows `PanelKind`).
enum PanelKind: Equatable {
    case none, more, sleep, speed, audio, subtitles, folderSubtitles, episodes, info
}

/// An audio or embedded subtitle track as the panels show it. `ordinal` = position among tracks of its type.
struct TrackItem: Hashable {
    let id: Int
    let ordinal: Int
    let language: String?
    let label: String?
    let fourCC: String?
    let channels: Int
    let rate: Int
    let name: String

    var forced: Bool { (label ?? name).range(of: "forced", options: .caseInsensitive) != nil }
}

/// A subtitle file Veltoret loaded (sidecar, from the folder, or from This Mac); libVLC renders it as a slave.
final class ExternalSub {
    let id: String
    let label: String
    let language: String?
    /// UTF-8 copy in `AppPaths.temp/subtitles` handed to libVLC.
    let path: URL
    /// libVLC's SPU id once the slave is added.
    var spuId: Int?

    init(id: String, label: String, language: String?, path: URL) {
        self.id = id; self.label = label; self.language = language; self.path = path
    }
}

/// One episode row of the in-player list.
struct EpisodeRowItem: Identifiable, Hashable {
    let fileId: String
    let account: String
    let season: Int
    let episode: Int
    let name: String
    let stillUrl: String?
    let watched: Bool
    let isCurrent: Bool
    var id: String { fileId }
}

/// The HUD pill (volume, zoom, notices, 2× speed).
struct HudState: Equatable {
    var text: String
    var icon: String
    var token = UUID()
}

/// Double-click / arrow seek feedback ("30 seconds").
struct RippleState: Equatable {
    var forward: Bool
    var total: Int
    var at: Date
}
