import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI

/// The player's window: routes keys to the player before anything else (no text fields live here).
final class PlayerNSWindow: NSWindow {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler = keyDownHandler, handler(event) { return }
        if event.type == .keyUp { keyUpHandler?(event) }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘L locks / unlocks the controls (Windows Ctrl+L) before the menus see it.
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "l", let handler = keyDownHandler, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc is handled by the player (panel → mini player → full screen → close).
    override func cancelOperation(_ sender: Any?) {}
}

/// Hosts the VLC video view and the SwiftUI chrome over it.
final class PlayerContainerView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
        onLayout?()
    }
}

/// The player window (Windows `PlayerWindow`): a dark window of its own, separate from the main window, that keeps
/// playing episode after episode; native full screen; an always-on-top mini player (the same window, floating and
/// small, instead of picture-in-picture). `current` is the open one (the launcher reuses it; Cast hooks).
@MainActor
public final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    /// The open player, if any.
    public private(set) static var current: PlayerWindowController?

    let controller: PlayerController
    private var mouseMonitor: Any?
    private var savedFrame: NSRect?
    private var enterMiniAfterFullscreen = false
    private var closed = false

    /// Opens `args` in the open player (saving the current video's progress first), or in a new window.
    public static func open(_ args: PlayerArgs) {
        if let current {
            current.controller.open(args)
            current.bringToFront()
            return
        }
        let wc = PlayerWindowController()
        current = wc
        PlayerHooks.windowOpened?(wc)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.controller.open(args)
    }

    private init() {
        controller = PlayerController()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1280, screen.width * 0.9), height: min(760, screen.height * 0.9))
        let window = PlayerNSWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = "Veltoret"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 320, height: 180)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("VeltoretPlayer")
        super.init(window: window)
        window.delegate = self
        controller.host = self

        let container = PlayerContainerView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let video = controller.videoView
        video.frame = container.bounds
        container.addSubview(video)
        let overlay = NSHostingView(rootView: PlayerOverlay(controller: controller))
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        container.onLayout = { [weak self] in self?.controller.applyAspect() }
        window.contentView = container

        window.keyDownHandler = { [weak self] e in self?.controller.handleKeyDown(e) ?? false }
        window.keyUpHandler = { [weak self] e in self?.controller.handleKeyUp(e) }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            if let self, e.window === self.window, e.type == .mouseMoved {
                MainActor.assumeIsolated { self.controller.mouseMovedInWindow() }
            }
            return e
        }
        chromeVisibilityChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // ---------------------------------------------------------------------------------------------
    // Cast hooks (FeatureNetwork's CastPlayerBridge)
    // ---------------------------------------------------------------------------------------------

    /// Current position in seconds.
    public var positionSeconds: Double { Double(controller.positionMs) / 1000 }
    /// The library file playing (nil for files outside the library).
    public var currentFile: MediaFileEntity? { controller.file }
    /// The id of what's playing (library id / local path / smb:// id / Drive id) and its account.
    public var fileId: String { controller.fileId }
    public var account: String? { controller.account }
    public var videoTitle: String { controller.title }
    public var videoSubtitle: String? { controller.subtitle }
    /// Fires (main actor) whenever a new video starts loading in this window.
    public var videoChanged: Event<Void> { controller.videoChanged }
    /// True while the video plays (or will once loaded).
    public var isPlaying: Bool { controller.playWhenReady }

    /// The video moves to a TV: save progress here, pause, and stop saving until it comes back.
    public func pauseForCast() { controller.pauseForCast() }

    /// Casting stopped: continue here, paused at the TV's position.
    public func resumeAfterCast(positionMs: Int64) { controller.resumeAfterCast(positionMs: positionMs) }

    /// Saves the current video's progress now.
    public func saveProgress() { controller.saveProgress() }

    // ---------------------------------------------------------------------------------------------
    // Window lifecycle
    // ---------------------------------------------------------------------------------------------

    /// Shows the window again (restored if minimised) when a new video is sent to it.
    public func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the player (saves progress first).
    public override func close() {
        window?.performClose(nil)
        if window?.isVisible == true { window?.close() }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    public func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        // Remember the normal window's frame, not the mini player's.
        if controller.isMini, let savedFrame { window?.setFrame(savedFrame, display: false) }
        controller.close()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        if Self.current === self { Self.current = nil }
        // Stay alive until whatever closed the window (a button, the end of the video) has returned.
        let keep = self
        DispatchQueue.main.async { _ = keep }
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        // Minimising keeps playing (audio-only listening), but progress is saved.
        controller.saveProgress()
    }

    public func windowDidResize(_ notification: Notification) {
        controller.applyAspect()
        controller.changed()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        controller.isFullscreen = true
        chromeVisibilityChanged()
        controller.showControls()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        controller.isFullscreen = false
        chromeVisibilityChanged()
        controller.showControls()
        if enterMiniAfterFullscreen {
            enterMiniAfterFullscreen = false
            enterMini()
        }
    }

    func videoTitleChanged() {
        let t = controller.title
        window?.title = t.isEmpty ? "Veltoret" : t + " – Veltoret"
    }

    // ---------------------------------------------------------------------------------------------
    // Chrome, cursor
    // ---------------------------------------------------------------------------------------------

    /// The traffic lights follow the chrome (hidden with the controls, in the mini player and while locked).
    func chromeVisibilityChanged() {
        guard let window else { return }
        let show = controller.chromeShown && !controller.isFullscreen
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let alpha: CGFloat = show ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = show ? 0.18 : 0.22
            for b in buttons { window.standardWindowButton(b)?.animator().alphaValue = alpha }
        }
    }

    /// Hides the pointer until it moves (controls auto-hidden while playing).
    func hideCursor() {
        guard let window, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // ---------------------------------------------------------------------------------------------
    // Full screen and the mini player
    // ---------------------------------------------------------------------------------------------

    public var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    public var isMini: Bool { controller.isMini }

    public func toggleFullscreen() {
        if controller.isMini { exitMini() }
        window?.toggleFullScreen(nil)
    }

    /// Picture-in-picture on the Mac: the same window, small and always on top, keeps playing.
    public func enterMini() {
        guard let window, !controller.isMini else { return }
        controller.closePanel()
        if isFullscreen {
            enterMiniAfterFullscreen = true
            window.toggleFullScreen(nil)
            return
        }
        savedFrame = window.frame
        controller.isMini = true
        controller.controlsVisible = false
        controller.miniControlsVisible = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let aspect = miniAspect()
        let work = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let width: CGFloat = 400
        let height = (width / aspect).rounded()
        let frame = NSRect(x: work.maxX - width - 16, y: work.minY + 16, width: width, height: height)
        window.minSize = NSSize(width: 200, height: 112)
        window.setFrame(frame, display: true, animate: true)
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        chromeVisibilityChanged()
        controller.changed()
    }

    public func exitMini() {
        guard let window, controller.isMini else { return }
        controller.isMini = false
        controller.miniControlsVisible = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.resizeIncrements = NSSize(width: 1, height: 1) // cancels the aspect lock
        window.minSize = NSSize(width: 320, height: 180)
        if let savedFrame { window.setFrame(savedFrame, display: true, animate: true) }
        savedFrame = nil
        window.makeKeyAndOrderFront(nil)
        controller.showControls()
        chromeVisibilityChanged()
    }

    public func toggleMini() {
        if controller.isMini { exitMini() } else { enterMini() }
    }

    /// The video's shape, clamped to 1:2.39–2.39:1 (Android PiP limits).
    private func miniAspect() -> CGFloat {
        let (w, h) = controller.videoSize()
        let aspect = w > 0 && h > 0 ? CGFloat(w) / CGFloat(h) : 16.0 / 9
        return min(2.39, max(1 / 2.39, aspect))
    }
}
