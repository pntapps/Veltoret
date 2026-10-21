import SwiftUI
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// Search results: movies and shows in the library (title, director, collection, cast, creator), with why each
/// matched (Windows SearchViewModel, spec §5).
@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var movies: [PosterItem] = []
    @Published private(set) var shows: [PosterItem] = []
    @Published private(set) var searched = false

    private var generation = 0
    private let bag = SubscriptionBag()
    private let route: Route
    private var stale = false

    static let tables: Set<String> = ["movies", "shows", "credits", "media_files"]

    init(route: Route) {
        self.route = route
        AppServices.db?.changed.subscribe { [weak self] t in
            guard !t.isDisjoint(with: SearchModel.tables) else { return }
            Task { @MainActor in self?.dataChanged() }
        }.store(in: bag)
        AppServices.connectivity?.onlineChanged.subscribe { [weak self] _ in
            Task { @MainActor in self?.dataChanged() }
        }.store(in: bag)
        Navigator.shared.navigated.subscribe { [weak self] r in
            Task { @MainActor in
                guard let self, self.stale, r == self.route else { return }
                self.stale = false
                await self.run(self.query)
            }
        }.store(in: bag)
    }

    private func dataChanged() {
        guard searched else { return }
        if Navigator.shared.current?.route == route { Task { await run(query) } } else { stale = true }
    }

    func run(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        if q.isEmpty {
            query = ""; movies = []; shows = []; searched = false
            return
        }
        let result = try? await Task.detached { () throws -> ([PosterItem], [PosterItem]) in
            let lib = AppServices.library!
            let (movieHits, showHits) = try lib.search(q)
            var movieMap: [Int: MovieEntity] = [:]
            for m in try lib.movies() { movieMap[m.movie.tmdbId] = m.movie }
            var showMap: [Int: ShowEntity] = [:]
            for s in try lib.shows() { showMap[s.show.tmdbId] = s.show }
            let movies = movieHits.compactMap { h -> PosterItem? in
                guard let m = movieMap[h.id] else { return nil }
                return PosterItem(id: m.tmdbId, title: m.title,
                                  subtitle: Formats.nilIfEmpty(Formats.joinTight(m.year.map(String.init), h.reason)),
                                  posterUrl: TmdbImages.poster(m.posterPath), rating: m.rating)
            }
            let shows = showHits.compactMap { h -> PosterItem? in
                guard let s = showMap[h.id] else { return nil }
                return PosterItem(id: s.tmdbId, isShow: true, title: s.name,
                                  subtitle: Formats.nilIfEmpty(Formats.joinTight(s.year.map(String.init), h.reason)),
                                  posterUrl: TmdbImages.poster(s.posterPath), rating: s.rating)
            }
            return (movies, shows)
        }.value
        guard gen == generation else { return }
        movies = result?.0 ?? []
        shows = result?.1 ?? []
        query = q
        searched = true
    }
}

struct SearchPage: View {
    let spoken: Bool
    @StateObject private var model: SearchModel
    @State private var text: String
    @State private var listening = false
    @FocusState private var focused: Bool
    @State private var hovering = false
    @ObservedObject private var nav = Navigator.shared
    private let initialSpoken: String?

    init(query: String?, spoken: Bool, route: Route) {
        self.spoken = spoken
        _model = StateObject(wrappedValue: SearchModel(route: route))
        // A spoken query ("play Dune 2021") searches for its title part.
        let q = query ?? ""
        if spoken, !q.isEmpty {
            let parsed = VoiceQuery.parse(q).title
            _text = State(initialValue: parsed.isEmpty ? q : parsed)
            initialSpoken = q
        } else {
            _text = State(initialValue: q)
            initialSpoken = nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = LibraryWidth(geo.size.width)
            VStack(alignment: .leading, spacing: 0) {
                VScreenHeader("Search", showsBack: nav.canGoBack)
                field
                    .frame(maxWidth: 720)
                    .padding(.horizontal, size.gutter)
                    .padding(.top, 4)
                results(size)
            }
        }
        .vPageBackground()
        .task(id: text) {
            // Debounced 200 ms (the first run, e.g. a query from the route, too).
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await model.run(text)
        }
        .task {
            if !spoken { focused = true }
            if let said = initialSpoken { await playIfAsked(said) }
        }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                .foregroundStyle(focused ? Theme.amber : Theme.textMuted)
                .frame(width: 20)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Titles, actors, directors, collections").font(Fonts.sans(16)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Fonts.sans(16))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.amber)
                    .focused($focused)
                    .onSubmit { Task { await model.run(text) } }
                    .accessibilityLabel("Titles, actors, directors, collections")
                    .onExitCommand { if !text.isEmpty { text = "" } else { Navigator.shared.goBack() } }
            }
            if !text.isEmpty {
                VIconButton("xmark", help: "Clear", size: 32, kind: .flat) { text = ""; focused = true }
            } else if LibraryHooks.voiceSearch != nil {
                VIconButton(listening ? "waveform" : "mic", help: "Search by voice", size: 32, kind: .flat, tint: Theme.amber) {
                    Task { await listen() }
                }
                .disabled(listening)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            .strokeBorder(focused ? Theme.amber : hovering ? Theme.outlineStrong : Theme.outline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ size: LibraryWidth) -> some View {
        if !model.searched {
            Spacer(minLength: 0)
        } else if model.movies.isEmpty && model.shows.isEmpty {
            VEmptyState(icon: "magnifyingglass", title: "No results",
                        message: "Nothing in your library matches \"\(model.query)\".")
        } else {
            let minCell: CGFloat = size == .compact ? 108 : 150
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.movies.isEmpty {
                        Text("Movies").vHeadlineSmall().lineLimit(1)
                            .padding(.horizontal, size.gutter).padding(.bottom, 20)
                        VAdaptiveGrid(model.movies.map(KeyedPoster.init), minItemWidth: minCell, hSpacing: 14, vSpacing: 20,
                                      gutter: size.gutter) { LibraryPosterCard($0.item) }
                    }
                    if !model.shows.isEmpty {
                        Text("TV Shows").vHeadlineSmall().lineLimit(1)
                            .padding(.horizontal, size.gutter)
                            .padding(.top, model.movies.isEmpty ? 0 : 28)
                            .padding(.bottom, 20)
                        VAdaptiveGrid(model.shows.map(KeyedPoster.init), minItemWidth: minCell, hSpacing: 14, vSpacing: 20,
                                      gutter: size.gutter) { LibraryPosterCard($0.item) }
                    }
                }
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: Voice

    private func listen() async {
        guard let voice = LibraryHooks.voiceSearch else { return }
        listening = true
        Toast.show("Say a title, actor or director")
        let heard = await voice()
        listening = false
        guard let heard, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show("Voice search isn't available")
            return
        }
        let parsed = VoiceQuery.parse(heard).title
        text = parsed.isEmpty ? heard : parsed
        await model.run(text)
        await playIfAsked(heard)
    }

    /// "Play Below season 1 episode 2": when the phrase asks to play and the library has the title, play it
    /// (Android VoiceRequests: MEDIA_PLAY_FROM_SEARCH). Otherwise the results stay on screen.
    private func playIfAsked(_ said: String) async {
        let lower = said.trimmingCharacters(in: .whitespaces).lowercased()
        guard ["play ", "watch ", "start ", "resume "].contains(where: { lower.hasPrefix($0) }) else { return }
        let parsed = VoiceQuery.parse(said)
        let match = try? await Task.detached { () throws -> VoiceQuery.Candidate? in
            let lib = AppServices.library!
            let candidates = try lib.movies().map { VoiceQuery.Candidate(id: $0.movie.tmdbId, isShow: false, title: $0.movie.title, year: $0.movie.year) }
                + lib.shows().map { VoiceQuery.Candidate(id: $0.show.tmdbId, isShow: true, title: $0.show.name, year: $0.show.year) }
            return VoiceQuery.best(parsed, candidates)
        }.value
        guard let match = match ?? nil else { return }
        if match.isShow {
            if let s = parsed.season, let e = parsed.episode { CardActions.playEpisode(showId: match.id, season: s, episode: e) }
            else { CardActions.playShow(match.id) }
        } else {
            CardActions.playMovie(match.id)
        }
    }
}
