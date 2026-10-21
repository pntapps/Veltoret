import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI

/// Builders shared by Home, grids, search, collection and detail rows (Windows `PosterItems`).
public enum PosterItems {
    /// Movie poster: subtitle "{year} · {runtime}", progress when partly watched, watched check.
    public static func movie(_ m: MovieEntity, _ state: WatchStateEntity?, badge: String? = nil) -> PosterItem {
        var progress: Double?
        if let state, !state.watched, state.positionMs > 0 { progress = Double(state.progress) }
        return PosterItem(
            id: m.tmdbId, title: m.title,
            subtitle: Formats.nilIfEmpty(Formats.joinTight(m.year.map(String.init), Formats.runtime(m.runtimeMin))),
            posterUrl: TmdbImages.poster(m.posterPath), progress: progress, watched: state?.watched == true,
            badge: badge, rating: m.rating)
    }

    /// Show poster: subtitle "{n} episodes" unless given.
    public static func show(_ s: ShowEntity, _ availableEpisodes: Int, subtitle: String? = nil, badge: String? = nil) -> PosterItem {
        PosterItem(id: s.tmdbId, isShow: true, title: s.name, subtitle: subtitle ?? Formats.episodes(availableEpisodes),
                   posterUrl: TmdbImages.poster(s.posterPath), badge: badge, rating: s.rating)
    }

    /// Watch states by key (`WatchKeys`).
    public static func statesByKey(_ states: [WatchStateEntity]) -> [String: WatchStateEntity] {
        var map: [String: WatchStateEntity] = [:]
        for s in states { map[s.key] = s }
        return map
    }
}

/// Width classes used by the library screens (Android Compact / Medium / Expanded, measured on the page width).
public enum LibraryWidth {
    case compact, medium, expanded

    public init(_ width: CGFloat) {
        self = width < 600 ? .compact : width < 840 ? .medium : .expanded
    }

    /// Home poster row card width (164 / 150 / 124).
    public var posterWidth: CGFloat { self == .expanded ? 164 : self == .medium ? 150 : 124 }
    /// Home wide card width (360 / 320 / 260).
    public var wideWidth: CGFloat { self == .expanded ? 360 : self == .medium ? 320 : 260 }
    /// Page side padding (40; 24 when compact).
    public var gutter: CGFloat { self == .compact ? 24 : Theme.gutter }
}

/// A wrapping row layout (chip strips).
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) { self.spacing = spacing; self.lineSpacing = lineSpacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

/// A dropdown (Android DropdownMenu, Windows ContextMenu) shown as a native menu at the mouse: selected items get a
/// check, `caption` adds a section header ("SOURCE").
@MainActor
public enum PopupMenu {
    public enum Entry {
        case item(String, selected: Bool = false, action: () -> Void)
        case separator
        case caption(String)
    }

    public static func show(_ entries: [Entry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            switch e {
            case .item(let title, let selected, let action):
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
                let target = MenuTarget(action)
                item.target = target
                item.representedObject = target
                item.state = selected ? .on : .off
                if selected {
                    item.attributedTitle = NSAttributedString(string: title, attributes: [
                        .foregroundColor: NSColor(Theme.amber), .font: NSFont.menuFont(ofSize: 0)])
                }
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .caption(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            }
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ sender: Any?) { action() }
    }
}

/// A poster keyed by "m{id}" / "s{id}" / "c{id}" (PosterItem's own `id` is the bare TMDB id, which a movie and a show
/// can share), for lists that mix kinds.
public struct KeyedPoster: Identifiable, Hashable {
    public let item: PosterItem
    public init(_ item: PosterItem) { self.item = item }
    public var id: String { item.key }
}
