import SwiftUI
import VeltoretKit
import VeltoretUI

/// What the movie page shows (Windows MovieDetailViewModel), loaded off the main thread.
struct MovieDetailData: Sendable {
    var movie: MovieEntity?
    var files: [MediaFileEntity] = []
    var state: WatchStateEntity?
    var credits: [CreditEntity] = []
    var related: [PosterItem] = []
    var saved = false
    var reminders: [ReminderEntity] = []

    var resumable: Bool { if let s = state { return !s.watched && s.positionMs > 30_000 }; return false }
    var watched: Bool { state?.watched == true }
    var bestFile: MediaFileEntity? { files.first }

    static func load(_ id: Int) throws -> MovieDetailData {
        guard let lib = AppServices.library else { return MovieDetailData() }
        var d = MovieDetailData()
        d.movie = try lib.movie(id)
        guard d.movie != nil else { return d }
        d.files = try lib.movieFiles(id)
        d.state = try AppServices.watch?.get(WatchKeys.movie(id))
        d.credits = try lib.credits(type: "movie", id: id)
        let states = PosterItems.statesByKey((try? AppServices.watch?.all()) ?? [])
        d.related = try lib.relatedMovies(id).map { PosterItems.movie($0.movie, states[WatchKeys.movie($0.movie.tmdbId)]) }
        d.saved = DetailCommon.isSaved(type: "movie", id: id)
        d.reminders = DetailCommon.reminders(type: "movie", id: id)
        return d
    }
}

@MainActor
final class MovieDetailModel: ObservableObject {
    let id: Int
    @Published private(set) var data: MovieDetailData?
    @Published private(set) var trailerKey: String?
    private var live: DetailLive?
    private var generation = 0
    private var fetched = false

    init(id: Int) {
        self.id = id
        trailerKey = DetailCommon.cachedTrailer(type: "movie", id: id) ?? nil
    }

    func start() {
        guard live == nil else { return }
        live = DetailLive(tables: ["movies", "media_files", "watch_state", "credits", "recommendations", "watchlist", "reminders"]) {
            [weak self] in self?.reload()
        }
        reload()
    }

    func reload() {
        generation += 1
        let gen = generation, id = id
        Task {
            let result = await Task.detached { try? MovieDetailData.load(id) }.value
            guard gen == self.generation, let result else { return }
            if result.movie == nil {
                // Re-matched or removed: close the page.
                if Navigator.shared.current?.route == .movieDetail(movieId: id) { Navigator.shared.goBack() }
                return
            }
            self.data = result
            await self.fetchOnline()
        }
    }

    /// On open (online): recommendations and the trailer key.
    private func fetchOnline() async {
        if fetched || !DetailCommon.online { return }
        fetched = true
        let id = id
        if let tmdb = AppServices.tmdb {
            Task.detached { try? await tmdb.ensureRecommendations(type: "movie", id: id) }
        }
        trailerKey = await DetailCommon.fetchTrailer(type: "movie", id: id)
    }

    func play() async {
        guard let d = data else { return }
        guard let best = d.bestFile, DetailCommon.canPlayNow(best) else { return }
        await DetailCommon.playMovie(id, startOver: d.watched && !d.resumable)
    }

    func setWatched(_ watched: Bool) {
        let id = id
        Task.detached {
            do { try AppServices.watch?.setMovieWatched(id, watched: watched) } catch { Toast.show(error.localizedDescription) }
        }
    }
}

/// Movie detail (Windows MovieDetailPage, Android MovieDetailScreen).
struct MovieDetailPage: View {
    let movieId: Int
    @StateObject private var model: MovieDetailModel
    @StateObject private var keys = PlayKeyMonitor()

    init(movieId: Int) {
        self.movieId = movieId
        _model = StateObject(wrappedValue: MovieDetailModel(id: movieId))
    }

    var body: some View {
        GeometryReader { geo in
            if let d = model.data, let m = d.movie {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        DetailHeader(width: geo.size.width, title: m.title, backdropUrl: TmdbImages.backdrop(m.backdropPath),
                                     posterUrl: TmdbImages.poster(m.posterPath, "w500"), entranceKey: "movie.\(movieId)") { w in
                            info(d, m, width: w)
                        }
                        CastSection(credits: d.credits)
                        VersionsSection(files: d.files, width: geo.size.width)
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
            keys.install(route: .movieDetail(movieId: movieId)) { [weak model] in
                guard let model else { return }
                Task { await model.play() }
            }
        }
        .onDisappear { keys.remove() }
    }

    @ViewBuilder
    private func info(_ d: MovieDetailData, _ m: MovieEntity, width: CGFloat) -> some View {
        let best = d.bestFile
        VStack(alignment: .leading, spacing: 0) {
            DetailTitle(title: m.title, tagline: m.tagline)
            DetailMeta(rating: m.rating, parts: [m.year.map(String.init), m.certification, Formats.runtime(m.runtimeMin)])
            DetailTags(quality: best.map { FilenameParser.qualityTags($0.name, height: $0.height) } ?? [], genres: m.genreList)
            VStack(alignment: .leading, spacing: 0) {
                if d.resumable, let s = d.state {
                    VProgressBar(Double(s.progress)).padding(.bottom, 6)
                    Text(Formats.remaining(positionMs: s.positionMs, durationMs: s.durationMs)).vBodySmall(Theme.textMuted)
                        .padding(.bottom, 12)
                }
                DetailActionRow(
                    availableWidth: width,
                    playLabel: d.resumable ? "Resume" : d.watched ? "Watch again" : "Play",
                    playIcon: d.watched && !d.resumable ? "arrow.counterclockwise" : "play.fill",
                    playEnabled: best.map(DetailCommon.canPlayNow) ?? false,
                    onPlay: { await model.play() },
                    trailerKey: model.trailerKey,
                    labelledTrailer: false,
                    saved: d.saved,
                    onToggleSaved: { DetailCommon.toggleSaved(type: "movie", id: m.tmdbId, saved: d.saved) },
                    menu: menu(d, m))
            }
            .padding(.top, 20)
            ReminderList(reminders: d.reminders)
            DetailOverview(text: m.overview)
            CreditLine(label: "Director", value: m.director)
            if let cid = m.collectionId {
                CreditLine(label: "Collection", value: m.collectionName) { Navigator.shared.navigate(.collection(collectionId: cid)) }
            }
            CreditLine(label: "Released", value: Formats.longDate(m.releaseDate))
        }
    }

    private func menu(_ d: MovieDetailData, _ m: MovieEntity) -> [DetailMenuItem] {
        var items: [DetailMenuItem] = []
        if d.watched {
            items.append(DetailMenuItem(label: "Mark unwatched", icon: "arrow.uturn.backward") { model.setWatched(false) })
        } else {
            items.append(DetailMenuItem(label: "Mark watched", icon: "checkmark") { model.setWatched(true) })
        }
        if DetailCommon.canRemind {
            items.append(DetailMenuItem(label: "Remind me…", icon: "bell") {
                DetailCommon.remindMe(type: "movie", id: m.tmdbId, season: nil, episode: nil, title: m.title, airDate: nil)
            })
        }
        let ids = d.files.map(\.driveId)
        items.append(DetailMenuItem(label: "Fix match", icon: "pencil") {
            Navigator.shared.navigate(.fixMatch(fileIds: ids, kind: "MOVIE", query: m.title))
        })
        return items
    }
}
