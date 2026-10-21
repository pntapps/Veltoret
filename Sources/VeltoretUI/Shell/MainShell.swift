import AppKit
import Combine
import SwiftUI
import VeltoretKit

/// One rail destination.
public struct RailTab: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let icon: String
    /// SF Symbol when selected.
    public let selectedIcon: String
    public let route: Route

    /// Rail order (⌘1 … ⌘6): Home, Movies, TV Shows, Search, Files, Settings.
    public static let all: [RailTab] = [
        RailTab(id: 0, label: "Home", icon: "house", selectedIcon: "house.fill", route: .home),
        RailTab(id: 1, label: "Movies", icon: "film", selectedIcon: "film.fill", route: .movies()),
        RailTab(id: 2, label: "TV Shows", icon: "tv", selectedIcon: "tv.fill", route: .shows()),
        RailTab(id: 3, label: "Search", icon: "magnifyingglass", selectedIcon: "magnifyingglass", route: .search()),
        RailTab(id: 4, label: "Files", icon: "folder", selectedIcon: "folder.fill", route: .files()),
        RailTab(id: 5, label: "Settings", icon: "gearshape", selectedIcon: "gearshape.fill", route: .settings),
    ]
}

/// Shell actions for menus and shortcuts (the app's menu bar items call these).
@MainActor
public enum ShellCommands {
    /// Back (⌘[, Esc outside text fields, mouse back button, two-finger swipe). False at the root or in onboarding.
    @discardableResult
    public static func goBack() -> Bool {
        let nav = Navigator.shared
        if nav.currentRoute?.kind == .onboarding { return false }
        return nav.goBack()
    }

    /// Rail tab by index (⌘1 … ⌘6). Search pushes (Back returns to where you were).
    public static func selectTab(_ index: Int) {
        guard RailTab.all.indices.contains(index) else { return }
        let tab = RailTab.all[index]
        let nav = Navigator.shared
        if nav.currentRoute?.kind == .onboarding { return }
        guard nav.isRegistered(tab.route.kind) else { Toast.show("\(tab.label) isn't available yet"); return }
        if tab.route.kind == .search { nav.push(tab.route); return }
        if let cur = nav.currentRoute, cur.kind == tab.route.kind { return }
        nav.selectTab(tab.route)
    }

    /// ⌘F: opens Search (pushed) unless it is already shown.
    public static func openSearch() {
        let nav = Navigator.shared
        if nav.currentRoute?.kind == .onboarding || nav.currentRoute?.kind == .search { return }
        if nav.isRegistered(.search) { nav.push(.search()) }
    }

    /// Brings the main window to the front.
    public static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = DialogHost.shared.shellWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// When true (default), the shell handles ⌘[, ⌘1–⌘6, ⌘F, Esc and the mouse back button itself (before menus).
    public static var handlesShortcuts = true
}

/// The main window's content (Windows `MainWindow`, Android AppShell Expanded): a dark left rail (traffic lights over
/// it) with Home, Movies, TV Shows, Search, Files, Settings; the page host with push/pop transitions; a back button in
/// the title-bar strip; toasts; dialogs; the offline label and scan indicator.
///
/// Host it as the window's root (`NSHostingView(rootView: MainShell())`); it configures its window itself (hidden,
/// transparent title bar, full-size content, dark) and becomes `DialogHost.shared.shellWindow`.
/// On first appearance it shows onboarding (when not completed and registered) or Home.
public struct MainShell: View {
    @ObservedObject private var nav = Navigator.shared
    @ObservedObject private var status = ShellStatus.shared
    @ObservedObject private var theme = ThemeState.shared

    public init() {}

    private var inOnboarding: Bool { nav.currentRoute?.kind == .onboarding }

    public var body: some View {
        HStack(spacing: 0) {
            if !inOnboarding {
                SidebarRail()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if let banner = status.banner { banner }
                PageHost()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { TitleStripBack(visible: nav.canGoBack && !inOnboarding) }
        }
        .overlay(ToastHostView())
        .overlay(DialogHostView())
        .background(theme.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
        .frame(minWidth: 640, minHeight: 480)
        .background(WindowConfigurator())
        .onAppear(perform: showStart)
    }

    private func showStart() {
        if nav.current != nil { return }
        let s = AppServices.settings?.current
        if s?.onboardingComplete == false && PageRegistry.isRegistered(.onboarding) {
            nav.navigate(.onboarding)
        } else if PageRegistry.isRegistered(.home) {
            nav.navigate(.home)
        }
    }

    /// Applies the shell's window look to `window` (MainShell also does this itself when shown).
    @MainActor
    public static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ThemeState.shared.nsBackground
        window.minSize = NSSize(width: 640, height: 480)
        if window.title.isEmpty { window.title = "Veltoret" }
        window.tabbingMode = .disallowed
    }
}

// MARK: - Rail

private struct SidebarRail: View {
    @ObservedObject private var nav = Navigator.shared
    @ObservedObject private var status = ShellStatus.shared

    private var selectedKind: RouteKind {
        if let c = nav.currentRoute, c.kind == .search { return .search }
        return nav.currentTopLevel.kind
    }

    var body: some View {
        VStack(spacing: 0) {
            RailLogo()
                .padding(.leading, 1)
                .padding(.top, 22)
                .padding(.bottom, 28)
            ForEach(RailTab.all) { tab in
                RailButton(tab: tab, selected: tab.route.kind == selectedKind)
                    .padding(.vertical, 6)
            }
            Spacer(minLength: 12)
            if let accessory = status.railAccessory { accessory.padding(.bottom, 12) }
            if let text = status.scanText {
                VStack(spacing: 6) {
                    VSpinner(size: 16, lineWidth: 1.5)
                    Text(text).vLabelSmall(Theme.textMuted).multilineTextAlignment(.center).lineLimit(2)
                    if let p = status.scanProgress { VProgressBar(p, height: 2).frame(width: 48) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 14)
                .help(text)
                .transition(.opacity)
            }
            if status.isOffline {
                VStack(spacing: 4) {
                    Image(systemName: "icloud.slash").font(.system(size: 16)).foregroundStyle(Theme.amberSoft)
                    Text("Offline").vLabelSmall(Theme.amberSoft)
                }
                .help("Offline · showing videos on this Mac")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status.isOffline)
        .animation(.easeInOut(duration: 0.25), value: status.scanText == nil)
        .padding(.top, 28) // traffic lights
        .padding(.bottom, 20)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surface.ignoresSafeArea())
        .overlay(alignment: .trailing) { VDivider(vertical: true).ignoresSafeArea() }
        .ignoresSafeArea(edges: .top)
    }
}

private struct RailButton: View {
    let tab: RailTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button { ShellCommands.selectTab(tab.id) } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? Theme.amber : Theme.textMuted)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(selected ? Theme.amberDim : Theme.surface))
                Text(tab.label).vLabelSmall(selected ? Theme.amber : Theme.textMuted).lineLimit(1).fixedSize()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(hovering && !selected ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.97))
        .onHover { hovering = $0 }
        .help("\(tab.label) (⌘\(tab.id + 1))")
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Page host

/// Hosts the navigator's pages. Every page in the back stack stays mounted (hidden) so its state and scroll position
/// survive Back. Push: the new page slides in from +1/6 width and fades in; pop: the top page slides out and fades.
private struct PageHost: View {
    @ObservedObject private var nav = Navigator.shared

    var body: some View {
        GeometryReader { geo in
            let shift = max(1, geo.size.width) / 6
            let entries = nav.backStack + (nav.current.map { [$0] } ?? [])
            ZStack {
                if nav.current == nil {
                    VEmptyState(icon: "film.stack", title: "Veltoret", message: "Loading…")
                }
                ForEach(entries) { entry in
                    let isCurrent = entry.id == nav.current?.id
                    entry.view
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(isCurrent ? 1 : 0)
                        .allowsHitTesting(isCurrent)
                        .accessibilityHidden(!isCurrent)
                        .zIndex(isCurrent ? 1 : 0)
                        .transition(.asymmetric(
                            insertion: .offset(x: shift).combined(with: .opacity),
                            removal: .offset(x: shift).combined(with: .opacity)))
                }
            }
            .animation(.timingCurve(0.215, 0.61, 0.355, 1, duration: nav.lastNavigationWasBack ? 0.26 : 0.32),
                       value: nav.current?.id)
        }
        .clipped()
    }
}

/// A small back chevron in the title-bar strip above the page (shown when Back is possible).
private struct TitleStripBack: View {
    let visible: Bool
    @State private var hovering = false
    var body: some View {
        if visible {
            Button { ShellCommands.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text : Theme.textMuted)
                    .frame(width: 28, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Back (⌘[)")
            .padding(.leading, 10)
            .padding(.top, 4)
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }
}

// MARK: - Window, keyboard, swipe

/// Finds the hosting NSWindow, configures it once and installs the keyboard / mouse / swipe monitors.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {}
}

private final class ConfiguratorView: NSView {
    private var monitor: Any?
    private var themeSub: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        MainShell.configure(window)
        DialogHost.shared.shellWindow = window
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                nonisolated(unsafe) let ev = event
                let consumed = MainActor.assumeIsolated { ShellEvents.handle(ev, in: window) == nil }
                return consumed ? nil : event
            }
        }
        if themeSub == nil {
            themeSub = ThemeState.shared.$oledBlack.sink { [weak window] _ in
                DispatchQueue.main.async { window?.backgroundColor = ThemeState.shared.nsBackground }
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor
private enum ShellEvents {
    static func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        guard event.window === window else { return event }
        switch event.type {
        case .keyDown: return key(event, window) ? nil : event
        case .otherMouseDown:
            if event.buttonNumber == 3, ShellCommands.handlesShortcuts, DialogHost.shared.items.isEmpty {
                return ShellCommands.goBack() ? nil : event
            }
            return event
        case .scrollWheel:
            swipe(event, window)
            return event
        default: return event
        }
    }

    private static func editingText(_ window: NSWindow) -> Bool {
        window.firstResponder is NSText || window.firstResponder is NSTextView
    }

    private static func key(_ e: NSEvent, _ window: NSWindow) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let host = DialogHost.shared
        if e.keyCode == 53, mods.isEmpty { // Esc
            if !host.items.isEmpty { host.escapeTop(); return true }
            guard ShellCommands.handlesShortcuts, !editingText(window) else { return false }
            return ShellCommands.goBack()
        }
        guard ShellCommands.handlesShortcuts, host.items.isEmpty, mods == .command else { return false }
        let ch = e.charactersIgnoringModifiers ?? ""
        switch ch {
        case "[": ShellCommands.goBack(); return true
        case "f": ShellCommands.openSearch(); return true
        case "1", "2", "3", "4", "5", "6": ShellCommands.selectTab(Int(ch)! - 1); return true
        default: return false
        }
    }

    private static var tracking = false

    /// Two-finger swipe right = Back (when the pointer isn't over a horizontal scroller that can still scroll left).
    private static func swipe(_ e: NSEvent, _ window: NSWindow) {
        guard e.phase == .began, !tracking, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), e.scrollingDeltaX > 0,
              Navigator.shared.canGoBack, DialogHost.shared.items.isEmpty,
              Navigator.shared.currentRoute?.kind != .onboarding else { return }
        if let content = window.contentView, let hit = content.hitTest(content.convert(e.locationInWindow, from: nil)) {
            var v: NSView? = hit
            while let view = v {
                if let sv = view as? NSScrollView, let doc = sv.documentView,
                   doc.frame.width > sv.contentView.bounds.width + 1, sv.contentView.bounds.origin.x > 0.5 {
                    return
                }
                v = view.superview
            }
        }
        tracking = true
        e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: 0, max: 1) { amount, phase, complete, _ in
            if complete || phase == .ended || phase == .cancelled {
                Task { @MainActor in
                    tracking = false
                    if complete && amount >= 1 { ShellCommands.goBack() }
                }
            }
        }
    }
}
