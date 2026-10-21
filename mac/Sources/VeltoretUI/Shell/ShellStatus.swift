import SwiftUI
import VeltoretKit

/// Live status the shell shows outside pages: the rail's Offline label, the rail's scan indicator, and optional slots.
/// `VeltoretUIModule.start()` binds `isOffline` / `scanText` to `AppServices.connectivity` / `AppServices.scanner`;
/// anything may also set them (main actor).
@MainActor
public final class ShellStatus: ObservableObject {
    public static let shared = ShellStatus()

    /// Shows "Offline" (CloudOff, AmberSoft) at the bottom of the rail.
    @Published public var isOffline = false
    /// When non-nil, the rail shows a small spinner with this text ("Syncing 120", "Matching").
    @Published public var scanText: String?
    /// 0…1 when known (drawn as a thin bar under the scan text), else indeterminate.
    @Published public var scanProgress: Double?
    /// Optional full-width banner above the page (e.g. "Reconnect your Google account").
    @Published public var banner: AnyView?
    /// Optional extra view in the rail above the status area (e.g. a Cast indicator).
    @Published public var railAccessory: AnyView?

    public init() {}
}
