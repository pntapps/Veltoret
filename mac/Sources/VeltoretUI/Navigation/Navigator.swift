import SwiftUI
import VeltoretKit

/// The kind of a `Route`, without its parameters (the key pages are registered under).
public enum RouteKind: String, CaseIterable, Hashable, Sendable {
    case home, movies, shows, search, files, settings, movieDetail, showDetail, collection, fixMatch, archives, onboarding
}

public extension Route {
    /// This route's kind (`PageRegistry` key).
    var kind: RouteKind {
        switch self {
        case .home: return .home
        case .movies: return .movies
        case .shows: return .shows
        case .search: return .search
        case .files: return .files
        case .settings: return .settings
        case .movieDetail: return .movieDetail
        case .showDetail: return .showDetail
        case .collection: return .collection
        case .fixMatch: return .fixMatch
        case .archives: return .archives
        case .onboarding: return .onboarding
        }
    }
}

/// Where feature modules register their pages, one builder per `RouteKind`. Call from `<Module>Module.initialize()`:
///
/// ```swift
/// PageRegistry.register(.movieDetail) { route in
///     guard case .movieDetail(let id) = route else { return nil }
///     return AnyView(MovieDetailPage(movieId: id))
/// }
/// // or, typed:
/// PageRegistry.register(.home) { _ in HomePage() }
/// ```
/// The builder runs once per navigation; the page instance then lives in the back stack (its `@State` survives Back).
@MainActor
public enum PageRegistry {
    public typealias Builder = @MainActor (Route) -> AnyView?
    private static var builders: [RouteKind: Builder] = [:]

    /// Registers (or replaces) the page builder for `kind`. Return nil from the builder for routes it can't show.
    public static func register(_ kind: RouteKind, _ builder: @escaping Builder) { builders[kind] = builder }

    /// Typed convenience: `PageRegistry.register(.home) { _ in HomePage() }`.
    public static func register<V: View>(_ kind: RouteKind, view: @escaping @MainActor (Route) -> V) {
        builders[kind] = { AnyView(view($0)) }
    }

    public static func isRegistered(_ kind: RouteKind) -> Bool { builders[kind] != nil }

    /// Builds the page for `route` (nil when nothing is registered or the builder declined).
    public static func build(_ route: Route) -> AnyView? { builders[route.kind]?(route) }
}

/// Shows pages in the main window (port of Windows `Navigator`, Android Navigation.kt): one back stack; top-level
/// destinations reset it. The shell (`MainShell`) hosts `current`; `AppServices.navigate` calls `navigate(_:)`.
///
/// Semantics:
/// - `navigate(_:)`: top-level routes clear the stack; others push. No-op when `route` is already shown.
/// - `push(_:)`: always pushes, even top-level (Search from a page keeps Back).
/// - `selectTab(_:)`: rail tab; clears to Home then pushes `route`, so Back from any tab exits through Home.
/// - `goBack()`: pops; returns false at the root.
@MainActor
public final class Navigator: ObservableObject {
    public static let shared = Navigator()

    /// A shown page: its route and the view built for it (kept alive while in the stack).
    public struct Entry: Identifiable {
        public let id = UUID()
        public let route: Route
        public let view: AnyView
    }

    /// The page on screen (nil before the first navigation).
    @Published public private(set) var current: Entry?
    /// Pages under `current`, oldest first.
    @Published public private(set) var backStack: [Entry] = []
    /// True when the last change came from `goBack()` (the shell plays the pop transition).
    public private(set) var lastNavigationWasBack = false

    /// Fires after every change of `current` (main actor).
    public let navigated = Event<Route>()

    public init() {}

    public var canGoBack: Bool { !backStack.isEmpty }
    public var currentRoute: Route? { current?.route }

    /// Same as `PageRegistry.register(_:_:)` (the contract's `register(_ kind:, view:)`).
    public func register(_ kind: RouteKind, view: @escaping PageRegistry.Builder) { PageRegistry.register(kind, view) }
    public func isRegistered(_ kind: RouteKind) -> Bool { PageRegistry.isRegistered(kind) }

    private func make(_ route: Route) -> Entry? {
        guard let view = PageRegistry.build(route) else {
            Log.info("No page registered for \(route.kind.rawValue)")
            Toast.show("This page isn't available yet")
            return nil
        }
        return Entry(route: route, view: view)
    }

    private func show(_ entry: Entry, back: Bool) {
        lastNavigationWasBack = back
        current = entry
        navigated.fire(entry.route)
    }

    /// Top-level routes reset the stack; other routes push. No-op when `route` is already shown.
    public func navigate(_ route: Route) {
        if current?.route == route { return }
        guard let entry = make(route) else { return }
        if route.isTopLevel { backStack.removeAll() } else if let c = current { backStack.append(c) }
        show(entry, back: false)
    }

    /// Always pushes `route` (even top-level). No-op when it is already shown.
    public func push(_ route: Route) {
        if current?.route == route { return }
        guard let entry = make(route) else { return }
        if let c = current { backStack.append(c) }
        show(entry, back: false)
    }

    /// Nav rail tab: no-op when already shown; otherwise clears the stack to Home and pushes `route`. Reuses a Home
    /// page already in the history so its scroll position survives.
    public func selectTab(_ route: Route) {
        if current?.route == route { return }
        if route == .home || !PageRegistry.isRegistered(.home) { navigate(route); return }
        guard let entry = make(route) else { return }
        var history = backStack
        if let c = current { history.append(c) }
        let home = history.first(where: { $0.route == .home }) ?? make(.home)
        backStack = home.map { [$0] } ?? []
        show(entry, back: false)
    }

    /// Pops the top page. Returns false when there is nothing to go back to.
    @discardableResult
    public func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        show(previous, back: true)
        return true
    }

    /// Replaces the whole history with `route` (e.g. onboarding finished → Home).
    public func reset(to route: Route) {
        guard let entry = make(route) else { return }
        backStack.removeAll()
        show(entry, back: false)
    }

    /// The last top-level route in the history (drives the rail selection), else Home. Search counts only when it is
    /// the root.
    public var currentTopLevel: Route {
        if let c = current?.route, c.isTopLevel, c.kind != .search { return c }
        for e in backStack.reversed() where e.route.isTopLevel && e.route.kind != .search { return e.route }
        if let c = current?.route, c.kind == .search, backStack.isEmpty { return c }
        return .home
    }
}

/// One section of the Settings page, contributed by any module (accounts, network servers, Play on TV…).
public struct SettingsSection: Identifiable {
    public let id: String
    public let title: String
    /// Sort key (lower first). Suggested: Library 100, Accounts 200, Network 300, Playback 400, Play on TV 500,
    /// Notifications 600, Appearance 700, Advanced 800, About 900.
    public let order: Int
    /// Optional SF Symbol for the section's navigation entry.
    public let icon: String?
    public let content: @MainActor () -> AnyView

    public init(id: String, title: String, order: Int, icon: String? = nil, content: @escaping @MainActor () -> AnyView) {
        self.id = id; self.title = title; self.order = order; self.icon = icon; self.content = content
    }
}

/// Registry the Settings page reads its sections from. Modules register in `initialize()`:
///
/// ```swift
/// SettingsSections.register(id: "network", title: "Network servers", order: 300) { NetworkServersSection() }
/// ```
/// The Settings page observes `SettingsSections.shared` and renders `sections` in order.
@MainActor
public final class SettingsSections: ObservableObject {
    public static let shared = SettingsSections()
    @Published public private(set) var sections: [SettingsSection] = []

    /// Adds or replaces (same id) a section.
    public func register(_ section: SettingsSection) {
        sections.removeAll { $0.id == section.id }
        sections.append(section)
        sections.sort { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }
    }

    public func remove(id: String) { sections.removeAll { $0.id == id } }

    /// Convenience: `SettingsSections.register(id:title:order:) { SomeView() }`.
    public static func register<V: View>(id: String, title: String, order: Int, icon: String? = nil,
                                         @ViewBuilder content: @escaping @MainActor () -> V) {
        shared.register(SettingsSection(id: id, title: title, order: order, icon: icon) { AnyView(content()) })
    }

    /// The registered sections, sorted.
    public static var all: [SettingsSection] { shared.sections }
}
