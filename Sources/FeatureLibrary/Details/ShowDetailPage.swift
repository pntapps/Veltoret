import SwiftUI
import VeltoretKit
import VeltoretUI

/// One row of the episode list (Windows EpisodeUi).
struct EpisodeUi: Identifiable, Sendable {
    var season: Int
    var number: Int
    var name: String
    var stillUrl: String?
    var runtime: String?
    var airDate: String?
    var airDateRaw: String?
    var overview: String
    var file: MediaFileEntity?
    var watched: Bool
    var progress: Double?
    var needsInternet: Bool
    var upcoming: Bool
    var available: Bool { file != nil && !needsInternet }
    var id: String { "\(season):\(number)" }
}

/// What the show page shows (Windows ShowDetailViewModel), loaded off the main thread.
struct ShowDetailData: Sendable {
    var show: ShowEntity?
    var files: [MediaFileEntity] = []
    var states: [WatchStateEntity] = []
    var episodes: [EpisodeEntity] = []
    var credits: [CreditEntity] = []
    var related: [PosterItem] = []
    var saved = false
    var reminders: [ReminderEntity] = []
    var target: EpisodeTarget?
    var seasons: [Int] = []

    static func load(_ id: Int) throws -> ShowDetailData {
        guard let lib = AppServices.library else { return ShowDetailData() }
        var d = ShowDetailData()
        d.show = try lib.show(id)
        guard d.show != nil else { return d }
        d.files = try lib.showFiles(id)
        d.states = (try AppServices.watch?.forShow(id)) ?? []
        d.episodes = try lib.episodes(id)
        d.credits = try lib.credits(type: "tv", id: id)
        d.related = try lib.relatedShows(id).map { PosterItems.show($0.show, $0.availableEpisodes) }
        d.saved = DetailCommon.isSaved(type: "tv", id: id)
        d.reminders = DetailCommon.reminders(type: "tv", id: id)
        d.target = PlayTargets.nextEpisode(d.files.filter(DetailCommon.canPlayNow), d.states)
        var seen = Set<Int>()
        d.seasons = d.files.compactMap(\.season).filter { seen.insert($0).inserted }
            .sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
        return d
    }

    private func stateOf(_ season: Int, _ episode: Int) -> WatchStateEntity? {
        states.first { $0.season == season && $0.episode == episode }
    }

    func episodesOf(_ season: Int) -> [EpisodeUi] {
        let today = Calendar.current.startOfDay(for: Date())
        var fileByEp: [Int: MediaFileEntity] = [:]
        for f in files where f.season == season {
            guard let e = f.episode else { continue }
            if let cur = fileByEp[e] {
                let better = (Accounts.isLocal(f.accountEmail) && !Accounts.isLocal(cur.accountEmail))
                    || (Accounts.isLocal(f.accountEmail) == Accounts.isLocal(cur.accountEmail) && f.height > cur.height)
                if better { fileByEp[e] = f }
            } else {
                fileByEp[e] = f
            }
        }
        var tmdb: [Int: EpisodeEntity] = [:]
        for e in episodes where e.seasonNumber == season { tmdb[e.episodeNumber] = e }
        let numbers = Set(fileByEp.keys).union(tmdb.keys).sorted()
        return numbers.map { n in
            let e = tmdb[n], f = fileByEp[n], st = stateOf(season, n)
            let date = Formats.parseDate(e?.airDate)
            var runtime: String?
            if let r = e?.runtimeMin, r > 0 { runtime = Formats.runtime(r) } else if let f { runtime = Formats.runtimeMs(f.durationMs) }
            var progress: Double?
            if let st, !st.watched, st.positionMs > 30_000 { progress = Double(st.progress) }
            return EpisodeUi(
                season: season, number: n,
                name: (e?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Episode \(n)" : e!.name,
                stillUrl: TmdbImages.still(e?.stillPath), runtime: runtime, airDate: Formats.longDate(e?.airDate),
                airDateRaw: e?.airDate, overview: e?.overview ?? "", file: f, watched: st?.watched == true,
                progress: progress, needsInternet: f.map { !DetailCommon.canPlayNow($0) } ?? false,
                upcoming: date.map { $0 >= today } ?? false)
        }
    }

    /// All available episodes of the season are watched.
    func seasonDone(_ season: Int) -> Bool {
        let eps = Set(files.filter { $0.season == season }.compactMap(\.episode))
        return !eps.isEmpty && eps.allSatisfy { stateOf(season, $0)?.watched == true }
    }
}

@MainActor
final class ShowDetailModel: ObservableObject {
    let id: Int
    @Published private(set) var data: ShowDetailData?
    @Published private(set) var trailerKey: String?
    @Published var season: Int?
    private var live: DetailLive?
    private var generation = 0
    private var fetched = false

    init(id: Int, season: Int?) {
        self.id = id
        self.season = season
        trailerKey = DetailCommon.cachedTrailer(type: "tv", id: id) ?? nil
    }

    func start() {
        guard live == nil else { return }
        live = DetailLive(tables: ["shows", "media_files", "watch_state", "credits", "recommendations", "watchlist",
                                   "reminders", "episodes", "seasons"]) { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        generation += 1
        let gen = generation, id = id
        Task {
            let result = await Task.detached { try? ShowDetailData.load(id) }.value
            guard gen == self.generation, let result else { return }
            if result.show == nil {
                if case .showDetail(let sid, _)? = Navigator.shared.current?.route, sid == id { Navigator.shared.goBack() }
                return
            }
            self.data = result
            await self.fetchOnline()
        }
    }

    private func fetchOnline() async {
        if fetched || !DetailCommon.online { return }
        fetched = true
        let id = id
        if let tmdb = AppServices.tmdb {
            Task.detached { try? await tmdb.ensureRecommendations(type: "tv", id: id) }
        }
        trailerKey = await DetailCommon.fetchTrailer(type: "tv", id: id)
    }

    var selectedSeason: Int {
        guard let d = data else { return season ?? 1 }
        if let s = season, d.seasons.contains(s) { return s }
        if let t = d.target?.file.season, d.seasons.contains(t) { return t }
        return d.seasons.first ?? 1
    }

    func playTarget() async {
        guard let t = data?.target, let s = t.file.season, let e = t.file.episode else { return }
        await DetailCommon.playEpisode(showId: id, season: s, episode: e, startOver: false)
    }

    func play(_ e: EpisodeUi) async {
        await DetailCommon.playEpisode(showId: id, season: e.season, episode: e.number, startOver: e.file != nil && e.watched)
    }

    func setWatched(_ e: EpisodeUi, _ watched: Bool) {
        let id = id
        Task.detached {
            do { try AppServices.watch?.setEpisodeWatched(showId: id, season: e.season, episode: e.number, watched: watched) }
            catch { Toast.show(error.localizedDescription) }
        }
    }

    /// Season actions apply to the episodes with files in the selected season.
    func markSeason(_ season: Int, _ watched: Bool) {
        guard let d = data else { return }
        let eps = Set(d.files.filter { $0.season == season }.compactMap(\.episode)).sorted().map { (season: season, episode: $0) }
        if eps.isEmpty { return }
        let id = id
        Task.detached {
            do { try AppServices.watch?.setEpisodesWatched(showId: id, eps, watched: watched) }
            catch { Toast.show(error.localizedDescription) }
        }
    }
}

/// Show detail (Windows ShowDetailPage): header, season chips, episodes (2 per row when wide), cast, more like this.
struct ShowDetailPage: View {
    let showId: Int
    @StateObject private var model: ShowDetailModel
    @StateObject private var keys = PlayKeyMonitor()

    init(showId: Int, season: Int?) {
        self.showId = showId
        _model = StateObject(wrappedValue: ShowDetailModel(id: showId, season: season))
    }

    var body: some View {
        GeometryReader { geo in
            if let d = model.data, let show = d.show {
                let season = model.selectedSeason
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        DetailHeader(width: geo.size.width, title: show.name, backdropUrl: TmdbImages.backdrop(show.backdropPath),
                                     posterUrl: TmdbImages.poster(show.posterPath, "w500"), entranceKey: "show.\(showId)") { w in
                            info(d, show, season: season, width: w)
                        }
                        if !d.seasons.isEmpty {
                            seasonChips(d, selected: season, wide: geo.size.width >= 900)
                            episodeList(d, show, season: season, width: geo.size.width)
                        }
                        CastSection(credits: d.credits)
                        MoreLikeThisSection(items: d.related)
                        DetailAttribution()
                    }
                    .padding(.bottom, 40)
                    .frame(width: geo.size.width, alignment: .leading)
                }
            } else {
                VLoadingBox().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .vPageBackground()
        .onAppear {
            model.start()
            let route = Navigator.shared.current?.route ?? .showDetail(showId: showId)
            keys.install(route: route) { [weak model] in
                guard let model else { return }
                Task { await model.playTarget() }
            }
        }
        .onDisappear { keys.remove() }
    }

    @ViewBuilder
    private func info(_ d: ShowDetailData, _ show: ShowEntity, season: Int, width: CGFloat) -> some View {
        let target = d.target
        let code = target.map { Formats.episodeCode($0.file.season, $0.file.episode) } ?? ""
        VStack(alignment: .leading, spacing: 0) {
            DetailTitle(title: show.name, tagline: show.tagline)
            DetailMeta(rating: show.rating, parts: [show.year.map(String.init), show.certification, show.network,
                                                    show.seasonCount > 0 ? Formats.seasons(show.seasonCount) : nil])
            DetailTags(quality: show.status == "Returning Series" ? ["Returning"] : [], genres: show.genreList)
            VStack(alignment: .leading, spacing: 0) {
                if let t = target, t.resuming, let st = t.state {
                    VProgressBar(Double(st.progress)).padding(.bottom, 12)
                }
                DetailActionRow(
                    availableWidth: width,
                    playLabel: target == nil ? "All caught up" : target!.resuming ? "Resume \(code)" : "Play \(code)",
                    playEnabled: target != nil,
                    onPlay: { await model.playTarget() },
                    trailerKey: model.trailerKey,
                    labelledTrailer: true,
                    saved: d.saved,
                    onToggleSaved: { DetailCommon.toggleSaved(type: "tv", id: show.tmdbId, saved: d.saved) },
                    menu: menu(d, show, season: season))
            }
            .padding(.top, 20)
            ReminderList(reminders: d.reminders)
            DetailOverview(text: show.overview)
            CreditLine(label: "Next episode", value: nextEpisode(show))
            CreditLine(label: "Created by", value: show.creator)
            CreditLine(label: "First aired", value: Formats.longDate(show.firstAirDate))
        }
    }

    private func nextEpisode(_ show: ShowEntity) -> String? {
        guard let next = Formats.parseDate(show.nextEpisodeAirDate), show.nextEpisodeSeason != nil,
              next >= Calendar.current.startOfDay(for: Date()) else { return nil }
        let name = (show.nextEpisodeName ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : "“\(show.nextEpisodeName!)”"
        return Formats.join(Formats.episodeCode(show.nextEpisodeSeason, show.nextEpisodeNumber), name, Formats.airLabel(next))
    }

    private func menu(_ d: ShowDetailData, _ show: ShowEntity, season: Int) -> [DetailMenuItem] {
        var items: [DetailMenuItem] = []
        if DetailCommon.canRemind {
            items.append(DetailMenuItem(label: "Remind me…", icon: "bell") {
                DetailCommon.remindMe(type: "tv", id: show.tmdbId, season: nil, episode: nil, title: show.name, airDate: nil)
            })
        }
        items.append(DetailMenuItem(label: "Mark season watched", icon: "checkmark.circle") { model.markSeason(season, true) })
        items.append(DetailMenuItem(label: "Mark season unwatched", icon: "arrow.uturn.backward") { model.markSeason(season, false) })
        let ids = d.files.map(\.driveId)
        items.append(DetailMenuItem(label: "Fix match", icon: "pencil") {
            Navigator.shared.navigate(.fixMatch(fileIds: ids, kind: "EPISODE", query: show.name))
        })
        return items
    }

    // MARK: Seasons

    private func seasonChips(_ d: ShowDetailData, selected: Int, wide: Bool) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(d.seasons, id: \.self) { s in
                VChip((s == 0 ? "Specials" : "Season \(s)") + (d.seasonDone(s) ? "  ✓" : ""), selected: s == selected) {
                    model.season = s
                }
                .contextMenu {
                    Button("Mark season watched") { model.markSeason(s, true) }
                    Button("Mark season unwatched") { model.markSeason(s, false) }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, wide ? 40 : 8)
        .padding(.bottom, 16)
    }

    // MARK: Episodes

    private func episodeList(_ d: ShowDetailData, _ show: ShowEntity, season: Int, width: CGFloat) -> some View {
        let wide = width >= 900
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: wide ? 2 : 1)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(d.episodesOf(season)) { e in
                EpisodeRow(episode: e, wide: width >= 760,
                           onPlay: { Task { await model.play(e) } },
                           onWatched: { model.setWatched(e, $0) },
                           onRemind: { remindEpisode(show, e) })
            }
        }
        .padding(.horizontal, Theme.gutter - 20)
    }

    private func remindEpisode(_ show: ShowEntity, _ e: EpisodeUi) {
        DetailCommon.remindMe(type: "tv", id: show.tmdbId, season: e.season, episode: e.number,
                              title: "\(show.name) · \(Formats.episodeCode(e.season, e.number))",
                              airDate: e.upcoming ? e.airDateRaw : nil)
    }
}

/// EpisodeRow: thumbnail (play disc, progress), "{n}. {name}", meta, overview, watched toggle or reminder bell.
private struct EpisodeRow: View {
    let episode: EpisodeUi
    let wide: Bool
    let onPlay: () -> Void
    let onWatched: (Bool) -> Void
    let onRemind: () -> Void

    private var menuItems: [DetailMenuItem] {
        var items: [DetailMenuItem] = []
        if DetailCommon.canRemind { items.append(DetailMenuItem(label: "Remind me…", icon: "bell") { onRemind() }) }
        if episode.available {
            let w = episode.watched
            items.append(DetailMenuItem(label: w ? "Mark unwatched" : "Mark watched", icon: w ? "arrow.uturn.backward" : "checkmark") {
                onWatched(!w)
            })
        }
        return items
    }

    var body: some View {
        let e = episode
        let dim = e.available ? 1.0 : 0.45
        let thumbW: CGFloat = wide ? 200 : 136
        Button {
            if e.available { onPlay() } else { PopupMenu.show(menuItems.map { m in .item(m.label, action: { MainActor.assumeIsolated { m.run() } }) }) }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                ZStack {
                    ArtworkImage(url: e.stillUrl, fallbackText: "E\(e.number)", cornerRadius: Theme.Radius.card, outlined: true, maxPixel: 400)
                    if e.available {
                        Circle().fill(Theme.imageDim).frame(width: 34, height: 34)
                            .overlay(Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Theme.text))
                    }
                    if let p = e.progress {
                        VStack { Spacer(); VProgressBar(p, height: 3, track: Theme.imageDim).padding(6) }
                    }
                }
                .frame(width: thumbW, height: thumbW * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .opacity(dim)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(e.number). \(e.name)").vTitleSmall().lineLimit(2).multilineTextAlignment(.leading)
                    let status: String? = e.needsInternet
                        ? (Accounts.isSmb(e.file?.accountEmail) ? "Network server · needs Wi-Fi" : "On Google Drive · needs internet")
                        : e.file == nil ? "Not in library" : nil
                    Text(Formats.joinTight(e.runtime, e.airDate, status)).vBodySmall(Theme.textMuted).lineLimit(1)
                    if !e.overview.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(e.overview).vBodySmall(Theme.textMuted).lineLimit(wide ? 3 : 2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .opacity(dim)
                if e.available {
                    VIconButton(e.watched ? "checkmark.circle.fill" : "circle", help: e.watched ? "Mark unwatched" : "Mark watched",
                                size: 36, kind: .flat, tint: e.watched ? Theme.amber : Theme.textFaint) { onWatched(!e.watched) }
                        .font(.system(size: 22))
                        .padding(.leading, 8)
                } else if e.upcoming && DetailCommon.canRemind {
                    VIconButton("bell.badge", help: "Remind me", size: 36, kind: .flat, tint: Theme.amber) { onRemind() }
                        .padding(.leading, 8)
                }
            }
        }
        .buttonStyle(VRowButtonStyle(padding: EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)))
        .contextMenu {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { _, m in
                Button { m.run() } label: { Label(m.label, systemImage: m.icon) }
            }
        }
    }
}
