import SwiftUI
import VeltoretKit
import VeltoretUI

/// Featured hero (Windows FeaturedPager): backdrop (weight 1.2, 16:9, corner 20) | 36 | info (eyebrow, title,
/// rating + meta, overview, Play / Details). Narrow pages (< 820) stack the backdrop above the info. Auto-advances
/// every 8 s when there is more than one item and the pointer isn't over it; bar indicator below. Trackpad: swipe
/// horizontally over the hero; keyboard: ← / → while it has focus.
struct FeaturedPager: View {
    let items: [FeaturedItem]
    let width: CGFloat
    let gutter: CGFloat

    @State private var index = 0
    @State private var forward = true
    @State private var hovering = false
    @State private var currentKey: String?
    @FocusState private var focused: Bool

    private var narrow: Bool { width < 820 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if items.indices.contains(index) {
                    page(items[index])
                        .id(items[index].key)
                        .transition(.asymmetric(
                            insertion: .offset(x: forward ? 80 : -80).combined(with: .opacity),
                            removal: .offset(x: forward ? -80 : 80).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, gutter)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                step(v.translation.width < 0 ? 1 : -1)
            })
            .onHover { hovering = $0 }

            if items.count > 1 { dots.padding(.leading, gutter).padding(.top, 16) }
        }
        .padding(.bottom, 8)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onChange(of: items) { _, new in keepCurrent(new) }
        .onAppear { keepCurrent(items) }
        .task(id: "\(index)|\(items.count)") {
            // Auto-advance every 8 s (restarts after every change of page).
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                if !hovering && Navigator.shared.current?.route == .home { step(1); return }
            }
        }
    }

    private func keepCurrent(_ list: [FeaturedItem]) {
        if let key = currentKey, let i = list.firstIndex(where: { $0.key == key }) { index = i }
        else if index >= list.count { index = 0 }
        currentKey = list.indices.contains(index) ? list[index].key : nil
    }

    private func step(_ dir: Int) {
        guard items.count > 1 else { return }
        go((index + dir + items.count) % items.count, forward: dir > 0)
    }

    private func go(_ i: Int, forward f: Bool) {
        guard i != index, items.indices.contains(i) else { return }
        forward = f
        withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.45)) {
            index = i
            currentKey = items[i].key
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.key) { i, item in
                Button { go(i, forward: i > index) } label: {
                    Capsule()
                        .fill(i == index ? Theme.amber : Theme.outlineStrong)
                        .frame(width: i == index ? 22 : 8, height: 3)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .animation(.easeOut(duration: 0.25), value: index)
            }
        }
    }

    @ViewBuilder
    private func page(_ item: FeaturedItem) -> some View {
        if narrow {
            VStack(alignment: .leading, spacing: 20) {
                image(item)
                info(item)
            }
        } else {
            // Star columns 1.2 : 1 with a 36 gap (Windows grid).
            let available = max(0, width - 2 * gutter - 36)
            HStack(alignment: .center, spacing: 36) {
                image(item).frame(width: available * 1.2 / 2.2)
                info(item).frame(width: available / 2.2, alignment: .leading)
            }
        }
    }

    private func image(_ item: FeaturedItem) -> some View {
        Button { Navigator.shared.navigate(item.route) } label: {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(ArtworkImage(url: item.backdropUrl, fallbackText: item.title, cornerRadius: Theme.Radius.hero,
                                      outlined: true, maxPixel: 1600))
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.98))
        .help(item.title)
        .contextMenu {
            Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
            Button { Navigator.shared.navigate(item.route) } label: { Label("Details", systemImage: "info.circle") }
        }
    }

    private func info(_ item: FeaturedItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.isShow ? "SERIES" : "FILM").vLabelSmall(Theme.amber).lineLimit(1)
            Text(item.title).vDisplaySmall().lineLimit(3).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if item.rating > 0 { VRating(item.rating) }
                VMetaLine(item.meta)
            }
            .padding(.top, 8)
            if !item.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.overview).vBodyMedium(Theme.textMuted).lineLimit(3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                VButton("Play", icon: "play.fill", kind: .primary) { play(item) }
                VButton("Details", icon: "info.circle", kind: .secondary) { Navigator.shared.navigate(item.route) }
            }
            .padding(.top, 16)
        }
    }

    private func play(_ item: FeaturedItem) {
        if item.isShow { CardActions.playShow(item.id) } else { CardActions.playMovie(item.id) }
    }
}

