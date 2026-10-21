import AppKit
import SwiftUI

/// The video area under the chrome: clicks (toggle controls / double-click seek or full screen), press-and-hold 2×,
/// drag to pan when zoomed, scroll for volume (⌘-scroll zoom), trackpad pinch zoom. In the mini player a drag moves
/// the window and a double-click expands it.
struct VideoGestureLayer: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> VideoGestureNSView {
        let v = VideoGestureNSView()
        v.controller = controller
        return v
    }

    func updateNSView(_ nsView: VideoGestureNSView, context: Context) {
        nsView.controller = controller
    }
}

final class VideoGestureNSView: NSView {
    weak var controller: PlayerController?
    private var pressPoint: NSPoint = .zero
    private var lastDrag: NSPoint = .zero
    private var preciseScroll: CGFloat = 0
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let c = controller, c.isMini else { return }
            c.miniControlsVisible = false
            c.changed()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p
        lastDrag = p
        let width = bounds.width
        let clicks = event.clickCount
        let mini = MainActor.assumeIsolated { controller?.isMini ?? false }
        if mini {
            if clicks >= 2 { MainActor.assumeIsolated { controller?.host?.exitMini() } }
            else { window?.performDrag(with: event) }
            return
        }
        MainActor.assumeIsolated { controller?.videoMouseDown(x: p.x, width: width, clickCount: clicks) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - lastDrag.x
        let dy = p.y - lastDrag.y
        lastDrag = p
        let moved = abs(p.x - pressPoint.x) + abs(p.y - pressPoint.y)
        let size = bounds.size
        MainActor.assumeIsolated { controller?.videoMouseDragged(moved: moved, dx: dx, dy: dy, size: size) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let c = controller, !c.isMini else { return }
            c.videoMouseUp()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.bumpInteraction() }
    }

    override func scrollWheel(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        var notches: Double
        if event.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: one notch per ~12 points of scrolling.
            preciseScroll += event.scrollingDeltaY
            let n = (preciseScroll / 12).rounded(.towardZero)
            guard n != 0 else { return }
            preciseScroll -= n * 12
            notches = Double(n)
        } else {
            notches = Double(event.scrollingDeltaY)
            if notches == 0 { return }
            notches = notches > 0 ? max(1, notches.rounded()) : min(-1, notches.rounded())
        }
        if event.isDirectionInvertedFromDevice { notches = -notches }
        MainActor.assumeIsolated { controller?.videoScroll(notches: notches, command: command) }
    }

    override func magnify(with event: NSEvent) {
        let m = event.magnification
        MainActor.assumeIsolated { controller?.videoMagnify(m) }
    }
}
