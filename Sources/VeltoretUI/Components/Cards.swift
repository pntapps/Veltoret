import SwiftUI
import VeltoretKit

/// A poster card's data (Android `PosterItem`, Windows `PosterItem`). Stable `key`: "m{id}" / "s{id}" / "c{id}".
public struct PosterItem: Hashable, Identifiable, Sendable {
    public var id: Int
    public var isShow: Bool
    public var isCollection: Bool
    public var title: String
    public var subtitle: String?
    public var posterUrl: String?
    /// 0…1 when partly watched, else nil.
    public var progress: Double?
    public var watched: Bool
    /// Pill text (uppercased when shown), e.g. "New", "4K".
    public var badge: String?
    /// False for collection parts that aren't in the library (dimmed to 42 %, not clickable).
    public var clickable: Bool
    public var rating: Double

    public init(id: Int, isShow: Bool = false, isCollection: Bool = false, title: String, subtitle: String? = nil,
                posterUrl: String? = nil, progress: Double? = nil, watched: Bool = false, badge: String? = nil,
                clickable: Bool = true, rating: Double = 0) {
        self.id = id; self.isShow = isShow; self.isCollection = isCollection; self.title = title; self.subtitle = subtitle
        self.posterUrl = posterUrl; self.progress = progress; self.watched = watched; self.badge = badge
        self.clickable = clickable; self.rating = rating
    }

    public var key: String { isCollection ? "c\(id)" : isShow ? "s\(id)" : "m\(id)" }
    public var hasProgress: Bool { (progress ?? 0) > 0 }

    /// The detail page this poster opens.
    public var route: Route {
        isCollection ? .collection(collectionId: id) : isShow ? .showDetail(showId: id) : .movieDetail(movieId: id)
    }
}

/// A wide 16:9 card that plays something (Continue Watching, Next Up).
public struct PlayItem: Hashable, Identifiable, Sendable {
    public var fileId: String
    public var title: String
    public var subtitle: String?
    public var imageUrl: String?
    /// nil = no bar; 0…1 = progress bar under the image.
    public var progress: Double?
    /// Solid pill top-right ("New", "S2 · E3").
    public var caption: String?
    public var movieId: Int?
    public var showId: Int?
    public var season: Int?
    public var episode: Int?

    public init(fileId: String, title: String, subtitle: String? = nil, imageUrl: String? = nil, progress: Double? = nil,
                caption: String? = nil, movieId: Int? = nil, showId: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.fileId = fileId; self.title = title; self.subtitle = subtitle; self.imageUrl = imageUrl; self.progress = progress
        self.caption = caption; self.movieId = movieId; self.showId = showId; self.season = season; self.episode = episode
    }

    public var id: String { "\(fileId)|\(movieId ?? 0)|\(showId ?? 0)|\(season ?? -1)|\(episode ?? -1)" }

    /// The detail page for this item (movie or show), if any.
    public var detailRoute: Route? {
        if let movieId { return .movieDetail(movieId: movieId) }
        if let showId { return .showDetail(showId: showId, season: season) }
        return nil
    }
}

/// Poster card (Android `PosterCard`): 2:3 image (corner 12, hairline; TextFaint hairline on hover), optional solid
/// badge pill top-left, watched check top-right, progress bar at the bottom over the image, then a one-line title
/// and an optional muted subtitle. Press scale 0.96; tooltip = title. Width comes from the container.
///
/// Default tap opens `item.route` via `Navigator.shared.navigate`. Add a context menu with `.contextMenu { … }`.
public struct PosterCard: View {
    let item: PosterItem
    let onTap: (() -> Void)?
    @State private var hovering = false

    public init(_ item: PosterItem, onTap: (() -> Void)? = nil) { self.item = item; self.onTap = onTap }

    public var body: some View {
        Button {
            if let onTap { onTap() } else { Navigator.shared.navigate(item.route) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay(ArtworkImage(url: item.posterUrl, fallbackText: item.title, cornerRadius: Theme.Radius.poster,
                                          outlined: true, maxPixel: 520))
                    .overlay(alignment: .topLeading) {
                        if let badge = item.badge { VPill(badge, style: .solid).padding(8) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.watched { WatchedCheck().padding(8) }
                    }
                    .overlay(alignment: .bottom) {
                        if item.hasProgress { VProgressBar(item.progress ?? 0, track: Theme.imageDim).padding(8) }
                    }
                    .overlay {
                        if hovering && item.clickable {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .strokeBorder(Theme.textFaint, lineWidth: 1)
                        }
                    }
                Text(item.title).vOneLine().padding(.top, 8)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).vMuted().lineLimit(1)
                }
            }
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.96))
        .disabled(!item.clickable)
        .opacity(item.clickable ? 1 : 0.42)
        .onHover { hovering = $0 }
        .help(item.title)
    }
}

/// The 22 pt amber "Watched" disc with a check.
public struct WatchedCheck: View {
    public init() {}
    public var body: some View {
        ZStack {
            Circle().fill(Theme.amber)
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAmber)
        }
        .frame(width: 22, height: 22)
        .help("Watched")
    }
}

/// Wide card (Android `WideCard`): 16:9 image (corner 14, hairline), 34 pt play disc bottom-left, caption pill
/// top-right, progress bar *below* the image when `progress != nil`, title and muted subtitle. Press scale 0.96.
///
/// Default tap: nothing (pass `onTap`, usually `AppServices.playback`). `onDetails` adds "Play" / "Details" to the
/// context menu.
public struct WideCard: View {
    let item: PlayItem
    let onTap: () -> Void
    let onDetails: (() -> Void)?
    @State private var hovering = false

    public init(_ item: PlayItem, onDetails: (() -> Void)? = nil, onTap: @escaping () -> Void) {
        self.item = item; self.onTap = onTap; self.onDetails = onDetails
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(ArtworkImage(url: item.imageUrl, fallbackText: item.title, cornerRadius: Theme.Radius.card,
                                          outlined: true, maxPixel: 900))
                    .overlay(alignment: .bottomLeading) {
                        ZStack {
                            Circle().fill(Theme.imageDim)
                            Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Theme.text)
                        }
                        .frame(width: 34, height: 34)
                        .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let caption = item.caption { VPill(caption, style: .solid).padding(8) }
                    }
                    .overlay {
                        if hovering {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .strokeBorder(Theme.textFaint, lineWidth: 1)
                        }
                    }
                if let p = item.progress { VProgressBar(p).padding(.top, 8) }
                Text(item.title).vOneLine().padding(.top, 8)
                if let subtitle = item.subtitle, !subtitle.isEmpty { Text(subtitle).vMuted().lineLimit(1) }
            }
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.96))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play", action: onTap)
            if let onDetails { Button("Details", action: onDetails) }
        }
    }
}
