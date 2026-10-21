import SwiftUI
import VeltoretKit
import VeltoretUI

/// A TMDB search result to pick (Windows Candidate).
struct MatchCandidate: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let year: String?
    let overview: String?
    let posterUrl: String?
}

@MainActor
final class FixMatchModel: ObservableObject {
    let fileIds: [String]
    private let kindHint: String?
    private let queryHint: String?

    @Published var kind: MediaKind = .MOVIE
    @Published var query = ""
    @Published private(set) var ready = false
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var results: [MatchCandidate] = []
    @Published private(set) var applying: Int?
    private var searchGen = 0

    init(fileIds: [String], kind: String?, query: String?) {
        self.fileIds = fileIds
        kindHint = kind
        queryHint = query
    }

    /// `^(.*?)\s*\(?((?:19|20)[0-9]{2})\)?$` on the trimmed query: (title, year) when the title part isn't blank.
    nonisolated static func split(_ query: String) -> (title: String, year: Int?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: "^(.*?)\\s*\\(?((?:19|20)[0-9]{2})\\)?$"),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r1 = Range(m.range(at: 1), in: q), let r2 = Range(m.range(at: 2), in: q) else { return (q, nil) }
        let title = q[r1].trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return (q, nil) }
        return (title, Int(q[r2]))
    }

    func start() {
        guard !ready else { return }
        let ids = fileIds, kindHint = kindHint, queryHint = queryHint
        Task {
            let files = await Task.detached { (try? AppServices.mediaFileDao?.files(ids)) ?? [] }.value
            let kind: MediaKind = kindHint == "MOVIE" ? .MOVIE : kindHint == "EPISODE" ? .EPISODE : files.first?.kind ?? .MOVIE
            var q = queryHint ?? ""
            if queryHint == nil, let first = files.first {
                if first.parsedTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    q = (first.name as NSString).deletingPathExtension
                } else if let y = first.parsedYear, kind == .MOVIE {
                    q = "\(first.parsedTitle) \(y)"
                } else {
                    q = first.parsedTitle
                }
            }
            self.kind = kind
            self.query = q
            self.ready = true
            await self.search()
        }
    }

    func setKind(_ k: MediaKind) {
        guard k != kind else { return }
        kind = k
        Task { await search() }
    }

    func search() async {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, let tmdb = AppServices.tmdb else { return }
        searchGen += 1
        let gen = searchGen, kind = kind
        searching = true
        error = nil
        let (title, year) = Self.split(q)
        do {
            let list: [MatchCandidate]
            if kind == .MOVIE {
                list = try await tmdb.searchMovies(title, year: year).map {
                    MatchCandidate(id: $0.id, title: $0.title, year: TmdbRepository.yearOf($0.releaseDate).map(String.init),
                                   overview: $0.overview, posterUrl: TmdbImages.poster($0.posterPath, "w185"))
                }
            } else {
                list = try await tmdb.searchShows(title, year: year).map {
                    MatchCandidate(id: $0.id, title: $0.name, year: TmdbRepository.yearOf($0.firstAirDate).map(String.init),
                                   overview: $0.overview, posterUrl: TmdbImages.poster($0.posterPath, "w185"))
                }
            }
            guard gen == searchGen else { return }
            results = list
        } catch {
            guard gen == searchGen else { return }
            results = []
            let msg = error.localizedDescription
            self.error = msg.trimmingCharacters(in: .whitespaces).isEmpty ? "Search failed" : msg
        }
        searching = false
    }

    func apply(_ c: MatchCandidate) {
        guard applying == nil, let scanner = AppServices.scanner else { return }
        applying = c.id
        error = nil
        let ids = fileIds, kind = kind
        Task {
            do {
                try await scanner.applyManualMatch(fileIds: ids, kind: kind, tmdbId: c.id)
                applying = nil
                Navigator.shared.goBack()
            } catch {
                applying = nil
                let msg = error.localizedDescription
                self.error = msg.trimmingCharacters(in: .whitespaces).isEmpty ? "Could not apply match" : msg
            }
        }
    }

    func ignore() {
        guard let scanner = AppServices.scanner else { return }
        let ids = fileIds
        Task {
            do {
                try await scanner.ignore(ids)
                Navigator.shared.goBack()
            } catch {
                Toast.show(error.localizedDescription)
            }
        }
    }
}

/// Fix match: search TMDB as a movie or a show and apply the pick to the files (Windows FixMatchPage).
struct FixMatchPage: View {
    @StateObject private var model: FixMatchModel

    init(fileIds: [String], kind: String?, query: String?) {
        _model = StateObject(wrappedValue: FixMatchModel(fileIds: fileIds, kind: kind, query: query))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VScreenHeader("Fix match", subtitle: Formats.plural(model.fileIds.count, "file", "files"), showsBack: true)
            HStack(spacing: 8) {
                VChip("Movie", selected: model.kind == .MOVIE) { model.setKind(.MOVIE) }
                VChip("TV Show", selected: model.kind == .EPISODE) { model.setKind(.EPISODE) }
            }
            .padding(.horizontal, Theme.gutter)
            HStack(spacing: 10) {
                VTextField("Title (add a year to narrow)", text: $model.query, icon: "magnifyingglass",
                            onSubmit: { Task { await model.search() } })
                VButton("Search", kind: .primary, loading: model.searching) { Task { await model.search() } }
                    .fixedSize()
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 12)
            VButton(model.fileIds.count == 1 ? "Not a movie or show? Ignore this file" : "Not a movie or show? Ignore these files",
                    kind: .textMuted) { model.ignore() }
                .fixedSize()
                .padding(.leading, Theme.gutter - 8)
                .padding(.top, 8)
            if let error = model.error {
                Text(error).vBodySmall(Theme.danger).padding(.horizontal, Theme.gutter).padding(.top, 8)
            }
            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vPageBackground()
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var results: some View {
        if !model.ready || (model.searching && model.results.isEmpty) {
            VLoadingBox().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.searching && model.results.isEmpty && model.error == nil {
            VEmptyState(icon: "film", title: "No results", message: "Try a shorter title or switch between Movie and TV Show.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(model.results) { c in candidate(c) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }

    private func candidate(_ c: MatchCandidate) -> some View {
        VClickPanel(padding: 12, action: { model.apply(c) }) {
            HStack(alignment: .top, spacing: 14) {
                ArtworkImage(url: c.posterUrl, fallbackText: c.title.isEmpty ? "?" : String(c.title.prefix(1)),
                             cornerRadius: Theme.Radius.poster, outlined: true, maxPixel: 185)
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.title).vTitleMedium().lineLimit(2).multilineTextAlignment(.leading)
                    if let y = c.year { Text(y).vBodySmall(Theme.amber).lineLimit(1) }
                    if let o = c.overview, !o.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(o).vBodySmall(Theme.textMuted).lineLimit(3).multilineTextAlignment(.leading).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.applying == c.id { VSpinner(size: 20).frame(maxHeight: .infinity) }
            }
        }
        .disabled(model.applying != nil)
        .help("Match as \(c.title)")
    }
}
