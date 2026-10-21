import AppKit
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// Veltoret's item in the menu bar (Windows TrayIcon): the "V." mark drawn as a template image, and a menu with the
/// scan progress, Open Veltoret, Scan library (Cancel scan while one runs), Pause / Resume (while something plays),
/// Reminders and Quit Veltoret. It follows Settings → "Show in menu bar" live.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    /// Current playback for the Pause / Resume item, provided by the player module (nil = nothing playing):
    /// `MenuBarController.nowPlaying = { player.isActive ? (title, player.isPlaying, { player.togglePlay() }) : nil }`.
    public static var nowPlaying: (@MainActor () -> (title: String, isPlaying: Bool, toggle: @MainActor () -> Void)?)?

    /// "Open Veltoret" (and a click on a notification); the app target may replace it to re-create a closed window.
    public static var openMainWindow: @MainActor () -> Void = { OpenRequests.showMainWindow() }

    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var subs: [VeltoretKit.Subscription] = []
    private var scanLine = ""

    override private init() { super.init() }

    /// Shows or hides the item from the settings and keeps following them and the scanner.
    public func start() {
        subs.removeAll()
        apply(AppServices.settings?.current.showMenuBarItem ?? true)
        if let settings = AppServices.settings {
            subs.append(settings.changed.subscribe { s in
                Task { @MainActor in MenuBarController.shared.apply(s.showMenuBarItem) }
            })
        }
        if let scanner = AppServices.scanner {
            scanLine = ScanText.menuLine(scanner.state)
            subs.append(scanner.stateChanged.subscribe { state in
                let line = ScanText.menuLine(state)
                Task { @MainActor in MenuBarController.shared.scanChanged(line) }
            })
        }
    }

    public func stop() {
        subs.removeAll()
        apply(false)
    }

    private func apply(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Self.icon()
            item.button?.toolTip = "Veltoret"
            item.button?.setAccessibilityLabel("Veltoret")
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
            updateTooltip()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func scanChanged(_ line: String) {
        scanLine = line
        updateTooltip()
        if menu.highlightedItem != nil || isMenuOpen { rebuild() }
    }

    private var isMenuOpen = false

    private func updateTooltip() {
        item?.button?.toolTip = scanLine.isEmpty ? "Veltoret" : "Veltoret · \(scanLine)"
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    public func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    public func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    private func rebuild() {
        menu.removeAllItems()
        if !scanLine.isEmpty {
            let status = NSMenuItem(title: scanLine, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }
        menu.addItem(entry("Open Veltoret", #selector(openApp)))
        let scanning = AppServices.scanner?.state.running ?? false
        menu.addItem(entry(scanning ? "Cancel scan" : "Scan library", #selector(scanLibrary)))
        if let now = Self.nowPlaying?() {
            let title = now.isPlaying ? "Pause" : "Resume"
            let play = entry(now.title.isEmpty ? title : "\(title) “\(now.title)”", #selector(togglePlayback))
            menu.addItem(play)
        }
        menu.addItem(entry("Reminders…", #selector(showReminders)))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Veltoret", #selector(quit), key: "q"))
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = true
        return i
    }

    @objc private func openApp() { Self.openMainWindow() }

    @objc private func scanLibrary() {
        if AppServices.scanner?.state.running ?? false {
            AppServices.scans?.cancel()
            return
        }
        guard let scans = AppServices.scans else { return }
        Task { await scans.runNow() }
    }

    @objc private func togglePlayback() { Self.nowPlaying?()?.toggle() }

    @objc private func showReminders() {
        Self.openMainWindow()
        Task { @MainActor in await RemindersDialog.show() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Icon

    /// The app mark as a template image: a bold "V" with a dot after it ("V."), 18 pt tall.
    static func icon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let v = NSBezierPath()
            v.lineWidth = 2.6
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            v.move(to: NSPoint(x: 2.5, y: 14.5))
            v.line(to: NSPoint(x: 8.5, y: 3))
            v.line(to: NSPoint(x: 14.5, y: 14.5))
            v.stroke()
            NSBezierPath(ovalIn: NSRect(x: 16.6, y: 1.8, width: 3.6, height: 3.6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Veltoret"
        return image
    }
}
