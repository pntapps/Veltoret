import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// The Cast button: amber while connected (or connecting). Opens the cast panel (device picker, pairing, and the
/// remote while casting). Placed in the player's top bar (`onImage: true`, via `CastPlayerBridge.makeCastButton()`)
/// and on Home (`LibraryHooks.castButton`).
public struct CastButton: View {
    let onImage: Bool
    let size: CGFloat
    @ObservedObject private var model = CastStateModel.shared

    /// - Parameter onImage: over video or artwork (the player's top bar): a dimmed disc instead of a surface one.
    public init(onImage: Bool = false, size: CGFloat = 42) {
        self.onImage = onImage
        self.size = size
    }

    public var body: some View {
        let s = model.state
        let label = s.connected ? "Casting to \(s.deviceName ?? "TV")"
            : s.connecting ? "Connecting to \(s.deviceName ?? "TV")…" : "Cast to a TV"
        Button { CastPanel.open() } label: {
            CastIcon(connected: s.connected, size: size * 0.5,
                     color: s.connected || s.connecting ? Theme.amber : Theme.text)
        }
        .buttonStyle(VIconButtonStyle(size: size, kind: onImage ? .onImage : .standard))
        .help(label)
        .accessibilityLabel(label)
        .focusable(false)
        .onAppear { model.bind() }
    }
}
