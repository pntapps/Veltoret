import SwiftUI

/// A horizontal shelf of cards (Home rows, "More like this", cast). Scrolls with trackpad / Shift+wheel; on hover
/// it shows round ‹ › arrows (SurfaceHighest discs) that page by roughly a screenful. Content is lazy.
///
/// ```swift
/// HorizontalRow(items, itemWidth: 160) { item in PosterCard(item) }
/// ```
/// `arrowCenter`: the arrows' vertical center from the top of the row (e.g. the poster image center); nil = middle.
public struct HorizontalRow<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let itemWidth: CGFloat?
    let spacing: CGFloat
    let gutter: CGFloat
    let arrowCenter: CGFloat?
    let cell: (Item) -> Cell

    @State private var visible = Set<Int>()
    @State private var hovering = false

    public init(_ items: [Item], itemWidth: CGFloat? = nil, spacing: CGFloat = Theme.rowSpacing, gutter: CGFloat = Theme.gutter,
                arrowCenter: CGFloat? = nil, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items; self.itemWidth = itemWidth; self.spacing = spacing; self.gutter = gutter
        self.arrowCenter = arrowCenter; self.cell = cell
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        cell(item)
                            .frame(width: itemWidth)
                            .id(index)
                            .onAppear { visible.insert(index) }
                            .onDisappear { visible.remove(index) }
                    }
                }
                .padding(.horizontal, gutter)
            }
            .overlay(alignment: arrowCenter == nil ? .leading : .topLeading) {
                if hovering, let first = visible.min(), first > 0 {
                    arrow("chevron.left", "Scroll left") {
                        let target = max(0, first - max(1, visible.count - 1))
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .leading) }
                    }
                    .padding(.leading, 8)
                    .padding(.top, arrowCenter.map { max(0, $0 - 20) } ?? 0)
                }
            }
            .overlay(alignment: arrowCenter == nil ? .trailing : .topTrailing) {
                if hovering, let last = visible.max(), last < items.count - 1 {
                    arrow("chevron.right", "Scroll right") {
                        let target = min(items.count - 1, last)
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .leading) }
                    }
                    .padding(.trailing, 8)
                    .padding(.top, arrowCenter.map { max(0, $0 - 20) } ?? 0)
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func arrow(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .buttonStyle(ArrowStyle())
        .help(help)
        .transition(.opacity)
    }
}

private struct ArrowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.surfaceHighest))
            .overlay(Circle().strokeBorder(Theme.outline, lineWidth: 1))
            .contentShape(Circle())
            .vPressScale(configuration.isPressed, 0.94)
    }
}

/// A virtualized adaptive grid (Windows `VirtualGrid`): `LazyVGrid` with as many columns of at least `minItemWidth`
/// as fit, gaps 20 h / 28 v by default, gutter padding. Put it inside a `ScrollView` (with headers above it).
///
/// ```swift
/// ScrollView { VScreenHeader("Movies"); VAdaptiveGrid(items) { PosterCard($0) } }
/// ```
public struct VAdaptiveGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let minItemWidth: CGFloat
    let maxItemWidth: CGFloat
    let hSpacing: CGFloat
    let vSpacing: CGFloat
    let gutter: CGFloat
    let cell: (Item) -> Cell

    public init(_ items: [Item], minItemWidth: CGFloat = 150, maxItemWidth: CGFloat = 240, hSpacing: CGFloat = 20,
                vSpacing: CGFloat = 28, gutter: CGFloat = Theme.gutter, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items; self.minItemWidth = minItemWidth; self.maxItemWidth = maxItemWidth; self.hSpacing = hSpacing
        self.vSpacing = vSpacing; self.gutter = gutter; self.cell = cell
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minItemWidth, maximum: maxItemWidth), spacing: hSpacing, alignment: .top)],
                  alignment: .leading, spacing: vSpacing) {
            ForEach(items) { item in cell(item) }
        }
        .padding(.horizontal, gutter)
    }
}

/// A grid of `PosterCard`s (library pages, search, collection). `onTap` defaults to opening the item's detail page.
public struct VPosterGrid: View {
    let items: [PosterItem]
    let minItemWidth: CGFloat
    let hSpacing: CGFloat
    let vSpacing: CGFloat
    let onTap: ((PosterItem) -> Void)?

    public init(_ items: [PosterItem], minItemWidth: CGFloat = 150, hSpacing: CGFloat = 20, vSpacing: CGFloat = 28,
                onTap: ((PosterItem) -> Void)? = nil) {
        self.items = items; self.minItemWidth = minItemWidth; self.hSpacing = hSpacing; self.vSpacing = vSpacing; self.onTap = onTap
    }

    public var body: some View {
        VAdaptiveGrid(items, minItemWidth: minItemWidth, hSpacing: hSpacing, vSpacing: vSpacing) { item in
            PosterCard(item, onTap: onTap.map { f in { f(item) } })
        }
    }
}
