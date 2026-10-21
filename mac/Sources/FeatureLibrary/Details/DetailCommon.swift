import AppKit
import SwiftUI
import VeltoretKit
import VeltoretPlans
import VeltoretUI

// Pieces shared by the movie and show pages (Windows Pages/Details/DetailCommon.cs, Android DetailCommon.kt /
// DetailActions.kt).

// MARK: - Registration

/// Registers the detail, Fix match and onboarding pages (library-detail worker).
public enum DetailPages {
    @MainActor public static func register() {
        PageRegistry.register(.movieDetail) { route in
            guard case .movieDetail(let id) = route else { return nil }
            return AnyView(MovieDetailPage(movieId: id))
        }
        PageRegistry.register(.showDetail) { route in
            guard case .showDetail(let id, let season) = route else { return nil }
            return AnyView(ShowDetailPage(showId: id, season: season))
        }
        PageRegistry.register(.fixMatch) { route in
            guard case .fixMatch(let ids, let kind, let query) = route else { return nil }
            if let ids, !ids.isEmpty { return AnyView(FixMatchPage(fileIds: ids, kind: kind, query: query)) }
            return AnyView(UnmatchedPage())
        }
        PageRegistry.register(.onboarding) { _ in AnyView(OnboardingPage()) }
    }
}

// MARK: - Live reload

/// Calls `onChange` (coalesced, on the main actor) when the database changes one of `tables` or the connection
/// comes and goes. Keep it alive as long as the page's model.
@MainActor
final class DetailLive {
    private let bag = SubscriptionBag()
    private var pending = false
    private let onChange: @MainActor () -> Void

    init(tables: Set<String>, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        if let db = AppServices.db {
            bag.add(db.changed.subscribe { [weak self] changed in
                guard !changed.isDisjoint(with: tables) else { return }
                Task { @MainActor in self?.schedule() }
            })
        }
        if let connectivity = AppServices.connectivity {
            bag.add(connectivity.onlineChanged.subscribe { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            })
        }
    }

    deinit { bag.cancelAll() }

    private func schedule() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.onChange()
            }
        }
    }
}

// MARK: - Helpers

enum DetailCommon {
    static var online: Bool { AppServices.connectivity?.isOnline ?? true }

    static func canPlayNow(_ f: MediaFileEntity) -> Bool { online || Accounts.isLocal(f.accountEmail) }

    /// The source line of a FileRow: (SF Symbol, text, color).
    static func sourceLine(_ f: MediaFileEntity, playable: Bool) -> (icon: String, text: String, color: Color) {
        if Accounts.isLocal(f.accountEmail) { return ("desktopcomputer", "On this Mac", Theme.amberSoft) }
        if Accounts.isSmb(f.accountEmail) {
            if !playable { return ("server.rack", "Network server · needs Wi-Fi", Theme.textFaint) }
            let root = (try? AppServices.storage?.rootName(f.accountEmail))
                ?? f.accountEmail.replacingOccurrences(of: "smb://", with: "")
            return ("server.rack", "Network server · " + root, Theme.textFaint)
        }
        return ("cloud", playable ? f.accountEmail : "Google Drive · needs internet", Theme.textFaint)
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    static func filePath(_ f: MediaFileEntity) -> String {
        f.relativePath.isEmpty ? f.name : f.relativePath + "/" + f.name
    }

    // Trailer keys, kept for the session ("type:id" → key or "" for none).
    @MainActor private static var trailerCache: [String: String] = [:]

    @MainActor static func cachedTrailer(type: String, id: Int) -> String?? {
        guard let v = trailerCache["\(type):\(id)"] else { return nil }
        return .some(v.isEmpty ? nil : v)
    }

    @MainActor static func fetchTrailer(type: String, id: Int) async -> String? {
        if let cached = cachedTrailer(type: type, id: id) { return cached }
        guard online, let tmdb = AppServices.tmdb else { return nil }
        do {
            let key = try await tmdb.trailer(type: type, id: id)
            trailerCache["\(type):\(id)"] = key ?? ""
            return key
        } catch {
            return nil
        }
    }

    @MainActor static func openTrailer(_ key: String?) {
        guard let key, !key.isEmpty else { Toast.show("Install YouTube to watch trailers"); return }
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        openInBrowser("https://www.youtube.com/watch?v=" + escaped)
    }

    // MARK: Watchlist & reminders

    static func isSaved(type: String, id: Int) -> Bool {
        if let plans = AppServices.plans, let v = try? plans.isInWatchlist(type: type, id: id) { return v }
        return (try? AppServices.plansDao?.isInWatchlist(type, id)) ?? false
    }

    static func reminders(type: String, id: Int) -> [ReminderEntity] {
        (try? AppServices.plans?.remindersFor(type: type, id: id)) ?? []
    }

    static func toggleSaved(type: String, id: Int, saved: Bool) {
        guard let plans = AppServices.plans else { Toast.show("The Watchlist isn't available"); return }
        Task.detached {
            do {
                try plans.setWatchlist(type: type, id: id, on: !saved)
                Toast.show(saved ? "Removed from your Watchlist" : "Added to your Watchlist")
            } catch {
                Log.error("watchlist: \(error)")
                Toast.show(error.localizedDescription)
            }
        }
    }

    @MainActor static var canRemind: Bool { LibraryHooks.reminderDialog != nil }

    @MainActor static func remindMe(type: String, id: Int, season: Int?, episode: Int?, title: String, airDate: String?) {
        guard let dialog = LibraryHooks.reminderDialog else { Toast.show("Reminders aren't available"); return }
        Task { @MainActor in _ = await dialog(type, id, season, episode, title, airDate) }
    }

    static func cancelReminder(_ id: Int64) {
        guard let plans = AppServices.plans else { return }
        Task.detached {
            do { try plans.removeReminder(id) } catch { Log.error("reminder: \(error)") }
        }
    }

    // MARK: Playback

    @MainActor private static func launcher() -> PlaybackLauncher? {
        if let p = AppServices.playback { return p }
        Toast.show("The player isn't available")
        return nil
    }

    /// Casts `file` when a TV is connected (LibraryHooks.castIfConnected); true when it went to the TV.
    @MainActor private static func cast(_ file: MediaFileEntity?) async -> Bool {
        guard let file, let hook = LibraryHooks.castIfConnected else { return false }
        return await hook(file)
    }

    @MainActor static func playMovie(_ id: Int, startOver: Bool) async {
        let file = LibraryHooks.castIfConnected == nil ? nil : await Task.detached { try? AppServices.resolver?.movieFile(id) }.value
        if await cast(file) { return }
        await launcher()?.playMovie(id, startOver: startOver)
    }

    @MainActor static func playEpisode(showId: Int, season: Int, episode: Int, startOver: Bool) async {
        let file = LibraryHooks.castIfConnected == nil ? nil
            : await Task.detached { try? AppServices.resolver?.episodeFile(showId: showId, season: season, episode: episode) }.value
        if await cast(file) { return }
        await launcher()?.playEpisode(showId: showId, season: season, episode: episode, startOver: startOver)
    }

    @MainActor static func playFile(_ file: MediaFileEntity) async {
        if await cast(file) { return }
        await launcher()?.playFile(file, startOver: false)
    }

}

// MARK: - Popup menu (the "⋮" button and click-to-open menus)

/// An entry of a popup menu.
struct DetailMenuItem {
    let label: String
    let icon: String
    let run: @MainActor () -> Void
}

// MARK: - Keyboard (Space / Return play on detail pages)

/// Installs a key monitor while the page is mounted: Space or Return runs `action` when `route` is the page on
/// screen, no dialog is open and no text field has the focus.
@MainActor
final class PlayKeyMonitor: ObservableObject {
    private var monitor: Any?

    func install(route: Route, action: @escaping @MainActor () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keys: Set<UInt16> = [49, 36, 76] // space, return, keypad enter
            guard keys.contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard Navigator.shared.current?.route == route, DialogHost.shared.items.isEmpty else { return false }
                guard let window = event.window, window === (DialogHost.shared.shellWindow ?? window) else { return false }
                if window.firstResponder is NSText || window.firstResponder is NSTextView { return false }
                action()
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Header

/// DetailHeader: wide = Back + info on the left, the framed 16:9 backdrop on the right with the poster hanging 48 pt
/// below its bottom-left corner; narrow (< 900 pt) = a 2.4:1 backdrop with Back on the image, then poster | info.
/// No text is ever placed on artwork.
struct DetailHeader<Info: View>: View {
    let width: CGFloat
    let title: String
    let backdropUrl: String?
    let posterUrl: String?
    let entranceKey: String
    let info: (CGFloat) -> Info

    static func isWide(_ width: CGFloat) -> Bool { width >= 900 }

    /// The width the info column gets (the action row lays out against it).
    static func infoWidth(_ width: CGFloat) -> CGFloat {
        if isWide(width) { return max(200, (width - 80 - 40) / 2.1) }
        let poster: CGFloat = width < 700 ? 0 : 160
        return max(200, width - 56 - (poster > 0 ? poster + 28 : 0))
    }

    var body: some View {
        if Self.isWide(width) { wide } else { narrow }
    }

    private var wide: some View {
        let left = Self.infoWidth(width)
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 0) {
                VIconButton("chevron.left", help: "Back") { Navigator.shared.goBack() }
                info(left).padding(.top, 24)
            }
            .frame(width: left, alignment: .leading)
            artwork
                .padding(.top, 58)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 40)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(ArtworkImage(url: backdropUrl, fallbackText: title, cornerRadius: Theme.Radius.detailBackdrop,
                                  outlined: true, maxPixel: 1600))
            .vEntrance(1, key: entranceKey + ".backdrop")
            .overlay(alignment: .bottomLeading) {
                poster(width: 124)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
                    .offset(x: 20, y: 48)
                    .vEntrance(2, key: entranceKey + ".poster")
            }
    }

    private func poster(width: CGFloat) -> some View {
        ArtworkImage(url: posterUrl, fallbackText: title, cornerRadius: Theme.Radius.poster, maxPixel: 500)
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
    }

    private var narrow: some View {
        let showPoster = width >= 700
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(2.4, contentMode: .fit)
                .overlay(ArtworkImage(url: backdropUrl, fallbackText: title, cornerRadius: Theme.Radius.detailBackdrop,
                                      outlined: true, maxPixel: 1600))
                .overlay(alignment: .topLeading) {
                    VIconButton("chevron.left", help: "Back", kind: .onImage) { Navigator.shared.goBack() }
                        .padding(12)
                }
                .vEntrance(1, key: entranceKey + ".backdrop")
                .padding(.horizontal, 20)
                .padding(.top, 12)
            HStack(alignment: .top, spacing: 28) {
                if showPoster {
                    poster(width: 160)
                        .vHairline(Theme.Radius.poster)
                        .vEntrance(2, key: entranceKey + ".poster")
                }
                info(Self.infoWidth(width)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
    }
}

// MARK: - Info pieces

/// Title (displaySmall) + optional tagline (serif titleMedium italic, muted).
struct DetailTitle: View {
    let title: String
    let tagline: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).vDisplaySmall().fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let tagline, !tagline.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(tagline).font(Theme.serif(VTextStyle.titleMedium.size)).italic().foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// RatingText + MetaLine (12 gap above).
struct DetailMeta: View {
    let rating: Double
    let parts: [String?]
    var body: some View {
        HStack(spacing: 12) {
            if rating > 0 { VRating(rating) }
            VMetaLine(parts: parts)
        }
        .padding(.top, 12)
    }
}

/// TagRow: accent quality pills (max 4) then plain genre pills, wrapping with spacing 6.
struct DetailTags: View {
    let quality: [String]
    let genres: [String]
    var body: some View {
        let q = Array(quality.prefix(4))
        if !q.isEmpty || !genres.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(q, id: \.self) { VPill($0, style: .accent) }
                ForEach(genres, id: \.self) { VPill($0) }
            }
            .padding(.top, 12)
        }
    }
}

/// CreditLine: label (labelLarge muted, 96 wide) + value; a clickable value is Amber with "  ›".
struct CreditLine: View {
    let label: String
    let value: String?
    var onClick: (() -> Void)? = nil

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label).vLabelLarge(Theme.textMuted).lineLimit(1).frame(width: 96, alignment: .leading)
                if let onClick {
                    Button(action: onClick) { Text(value + "  ›").vBodyMedium(Theme.amber) }
                        .buttonStyle(VPlainButtonStyle())
                        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                } else {
                    Text(value).vBodyMedium().fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct DetailOverview: View {
    let text: String?
    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text).vBodyLarge(Theme.text.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 20)
        }
    }
}

/// ReminderList: bell, "[S1 · E2  ·  ]Reminder {label}", cancel button.
struct ReminderList: View {
    let reminders: [ReminderEntity]
    var body: some View {
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(reminders) { r in
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge.fill").font(.system(size: 15)).foregroundStyle(Theme.amber)
                            .frame(width: 18)
                        let code = Formats.episodeCode(r.season, r.episode)
                        let label = "Reminder " + Formats.reminderLabel(ms: r.at)
                        Text(code.isEmpty ? label : code + "  ·  " + label).vBodyMedium().lineLimit(1)
                        VIconButton("xmark", help: "Cancel reminder", size: 32, kind: .flat) {
                            DetailCommon.cancelReminder(r.id)
                        }
                    }
                }
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Action row

/// DetailActionRow (§6.4): always one line — [Play] [Trailer?] [Watchlist?] [⋮] — with the exact overflow rules:
/// buttonWidth(label) = text width + 70; fits(ws) = play + 48 + Σ(w + 10) + 10 ≤ width.
struct DetailActionRow: View {
    let availableWidth: CGFloat
    let playLabel: String
    var playIcon: String = "play.fill"
    var playEnabled: Bool = true
    let onPlay: @MainActor () async -> Void
    let trailerKey: String?
    var labelledTrailer: Bool = false
    let saved: Bool
    let onToggleSaved: () -> Void
    var menu: [DetailMenuItem] = []

    @State private var playing = false

    private enum TrailerMode { case none, labelled, icon, menu }
    private static let gap: CGFloat = 10, icon: CGFloat = 48, chrome: CGFloat = 20 * 2 + 20 + 8 + 2

    private static func textWidth(_ s: String) -> CGFloat {
        let font = Fonts.nsSans(VTextStyle.labelLarge.size, .semibold)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private var layout: (TrailerMode, Bool) {
        let play = Self.textWidth(playLabel) + Self.chrome
        let labelled = Self.textWidth("Trailer") + Self.chrome
        func fits(_ ws: [CGFloat]) -> Bool { play + Self.icon + ws.reduce(0) { $0 + $1 + Self.gap } + Self.gap <= availableWidth }
        let mode: TrailerMode = trailerKey == nil || !DetailCommon.online ? .none
            : labelledTrailer && fits([Self.icon, labelled]) ? .labelled
            : fits([Self.icon, Self.icon]) ? .icon
            : .menu
        let watchlistInRow = mode == .menu || mode == .none ? fits([Self.icon]) : true
        return (mode, watchlistInRow)
    }

    var body: some View {
        let (mode, watchlistInRow) = layout
        HStack(spacing: Self.gap) {
            VButton(playLabel, icon: playIcon, kind: .primary, loading: playing) {
                playing = true
                Task { @MainActor in
                    await onPlay()
                    playing = false
                }
            }
            .disabled(!playEnabled)
            .opacity(playEnabled ? 1 : 0.5)
            .fixedSize()
            if mode == .labelled {
                VButton("Trailer", icon: "play.rectangle", kind: .ghost) { DetailCommon.openTrailer(trailerKey) }.fixedSize()
            } else if mode == .icon {
                VIconButton("play.rectangle", help: "Watch trailer", size: Self.icon) { DetailCommon.openTrailer(trailerKey) }
            }
            if watchlistInRow {
                VIconButton(saved ? "bookmark.fill" : "bookmark", help: saved ? "Remove from Watchlist" : "Watch later",
                            size: Self.icon, tint: saved ? Theme.amber : Theme.text, action: onToggleSaved)
            }
            VIconButton("ellipsis", help: "More", size: Self.icon) {
                var items: [DetailMenuItem] = []
                if mode == .menu {
                    let key = trailerKey
                    items.append(DetailMenuItem(label: "Watch trailer", icon: "play.rectangle") { DetailCommon.openTrailer(key) })
                }
                if !watchlistInRow {
                    let toggle = onToggleSaved
                    items.append(DetailMenuItem(label: saved ? "Remove from Watchlist" : "Watch later",
                                                icon: saved ? "bookmark.fill" : "bookmark") { toggle() })
                }
                PopupMenu.show((items + menu).map { m in .item(m.label, action: { MainActor.assumeIsolated { m.run() } }) })
            }
        }
        .frame(minHeight: 48, alignment: .leading)
    }
}

// MARK: - Sections below the header

/// SectionHeader + content (top padding, gap).
struct DetailSection<Content: View>: View {
    let title: String
    var top: CGFloat = 32
    var gap: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            VSectionHeader(title)
            content
        }
        .padding(.top, top)
    }
}

private struct CastItem: Identifiable {
    let credit: CreditEntity
    var id: String { "\(credit.personId)-\(credit.ord)" }
}

/// Cast: 76 pt round photos, name (2 lines) and character (1 line), max 30 by order.
struct CastSection: View {
    let credits: [CreditEntity]
    var body: some View {
        if !credits.isEmpty {
            let items = credits.sorted { $0.ord < $1.ord }.prefix(30).map(CastItem.init)
            DetailSection(title: "Cast", top: 32, gap: 14) {
                HorizontalRow(Array(items), itemWidth: 84, spacing: 16, arrowCenter: 38) { item in
                    let c = item.credit
                    VStack(spacing: 0) {
                        ArtworkImage(url: TmdbImages.profile(c.profilePath), fallbackText: DetailCommon.initials(c.name),
                                     cornerRadius: 38, outlined: true, maxPixel: 185)
                            .frame(width: 76, height: 76)
                            .clipShape(Circle())
                        Text(c.name).vLabelMedium().lineLimit(2).multilineTextAlignment(.center).padding(.top, 8)
                        if let ch = c.character, !ch.isEmpty {
                            Text(ch).vBodySmall(Theme.textMuted).lineLimit(1).multilineTextAlignment(.center)
                        }
                    }
                    .frame(width: 84)
                    .help((c.character ?? "").isEmpty ? c.name : "\(c.name) as \(c.character!)")
                }
            }
        }
    }
}

/// Versions / File: FileRows, 2 per row on wide windows, spacing 10. Click plays that exact file.
struct VersionsSection: View {
    let files: [MediaFileEntity]
    let width: CGFloat

    var body: some View {
        if !files.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: width >= 900 ? 2 : 1)
            DetailSection(title: files.count > 1 ? "Versions" : "File") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(files) { FileRow(file: $0) }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }
}

private struct FileRow: View {
    let file: MediaFileEntity

    var body: some View {
        let playable = DetailCommon.canPlayNow(file)
        let src = DetailCommon.sourceLine(file, playable: playable)
        VClickPanel(padding: 14, action: { Task { await DetailCommon.playFile(file) } }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(Theme.amber).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).vTitleSmall().lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        ForEach(Array(FilenameParser.qualityTags(file.name, height: file.height).prefix(3)), id: \.self) {
                            VPill($0, style: .accent)
                        }
                        Text(Formats.joinTight(file.sizeBytes > 0 ? Formats.size(file.sizeBytes) : nil, Formats.runtimeMs(file.durationMs)))
                            .vBodySmall(Theme.textMuted).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: src.icon).font(.system(size: 11)).foregroundStyle(src.color)
                        Text(src.text).vBodySmall(src.color).lineLimit(1)
                    }
                }
            }
        }
        .help(DetailCommon.filePath(file))
        .disabled(!playable)
        .opacity(playable ? 1 : 0.45)
        .contextMenu {
            Button("Play") { Task { await DetailCommon.playFile(file) } }.disabled(!playable)
            if Accounts.isLocal(file.accountEmail) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.driveId)]) }
            }
            Button("Copy file name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.name, forType: .string)
            }
        }
    }
}

/// "More like this": a row of poster cards (164 wide).
struct MoreLikeThisSection: View {
    let items: [PosterItem]
    var body: some View {
        if !items.isEmpty {
            DetailSection(title: "More like this", top: 36) {
                HorizontalRow(items, itemWidth: 164, spacing: 16, arrowCenter: 164 * 1.5 / 2) { LibraryPosterCard($0) }
            }
        }
    }
}

struct DetailAttribution: View {
    var body: some View {
        Text("Metadata and artwork from TMDB").vBodySmall(Theme.textFaint)
            .padding(.leading, Theme.gutter)
            .padding(.top, 32)
    }
}
