import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI

/// A group of unmatched (or ignored) files with the same kind and parsed title (Windows FileGroup).
struct FileGroup: Identifiable, Sendable {
    let kind: MediaKind
    let title: String
    let files: [MediaFileEntity]
    var ids: [String] { files.map(\.driveId) }
    var id: String { kind.rawValue + "|" + title }

    static func of(_ files: [MediaFileEntity]) -> [FileGroup] {
        var order: [String] = []
        var groups: [String: (MediaKind, String, [MediaFileEntity])] = [:]
        for f in files {
            let title = f.parsedTitle.trimmingCharacters(in: .whitespaces).isEmpty ? f.name : f.parsedTitle
            let key = f.kind.rawValue + "|" + title
            if groups[key] == nil { order.append(key); groups[key] = (f.kind, title, []) }
            groups[key]!.2.append(f)
        }
        let list = order.map { k -> FileGroup in let g = groups[k]!; return FileGroup(kind: g.0, title: g.1, files: g.2) }
        // Stable, case-insensitive by title.
        return list.enumerated().sorted { a, b in
            let c = a.element.title.compare(b.element.title, options: .caseInsensitive)
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
        }.map(\.element)
    }
}

struct UnmatchedData: Sendable {
    var unmatched: [FileGroup] = []
    var ignored: [FileGroup] = []
}

@MainActor
final class UnmatchedModel: ObservableObject {
    @Published private(set) var data: UnmatchedData?
    private var live: DetailLive?
    private var generation = 0

    func start() {
        guard live == nil else { return }
        live = DetailLive(tables: ["media_files"]) { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        generation += 1
        let gen = generation
        Task {
            let d = await Task.detached { () -> UnmatchedData in
                guard let lib = AppServices.library else { return UnmatchedData() }
                return UnmatchedData(unmatched: FileGroup.of((try? lib.unmatched()) ?? []),
                                     ignored: FileGroup.of((try? lib.ignored()) ?? []))
            }.value
            guard gen == self.generation else { return }
            self.data = d
        }
    }

    func ignore(_ g: FileGroup) {
        guard let scanner = AppServices.scanner else { return }
        let ids = g.ids
        Task {
            do { try await scanner.ignore(ids) } catch { Toast.show(error.localizedDescription) }
        }
    }

    func restore(_ g: FileGroup) {
        guard let scanner = AppServices.scanner else { return }
        let ids = g.ids, folders = Set(g.files.map(\.libraryFolderId))
        Task {
            do {
                try await scanner.restore(ids)
                if let scans = AppServices.scans { Task.detached { await scans.runNow(folders) } }
            } catch {
                Toast.show(error.localizedDescription)
            }
        }
    }
}

/// "Needs a match": files we couldn't identify, grouped; Ignore / Restore (Windows UnmatchedPage).
struct UnmatchedPage: View {
    @StateObject private var model = UnmatchedModel()
    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VScreenHeader("Needs a match", subtitle: "Files we couldn't identify automatically", showsBack: true)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vPageBackground()
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        if let d = model.data {
            if d.unmatched.isEmpty && d.ignored.isEmpty {
                VEmptyState(icon: "checkmark.circle", title: "All matched", message: "Every file in your library has been identified.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if d.unmatched.isEmpty {
                            Text("Everything else is matched.").vBodyMedium(Theme.textMuted)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(d.unmatched) { unmatchedCard($0) }
                        }
                        if !d.ignored.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ignored").vTitleLarge()
                                Text("Kept out of your library. Restore one to match it again.").vBodySmall(Theme.textMuted)
                            }
                            .padding(.top, 18)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                ForEach(d.ignored) { ignoredCard($0) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, 20)
                }
            }
        } else {
            VLoadingBox().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func count(_ g: FileGroup) -> String {
        (g.kind == .MOVIE ? "Movie · " : "TV · ") + Formats.plural(g.files.count, "file", "files")
    }

    private func open(_ g: FileGroup) {
        Navigator.shared.navigate(.fixMatch(fileIds: g.ids, kind: g.kind.rawValue, query: g.title))
    }

    private func unmatchedCard(_ g: FileGroup) -> some View {
        VClickPanel(action: { open(g) }) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(g.title).vTitleMedium().lineLimit(1)
                    Text(count(g)).vBodySmall(Theme.amber).lineLimit(1).padding(.top, 2)
                    Text(DetailCommon.filePath(g.files[0])).vBodySmall(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                        .help(g.files.prefix(12).map(DetailCommon.filePath).joined(separator: "\n"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VButton("Ignore", kind: .textMuted, compact: true) { model.ignore(g) }
                    .fixedSize()
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
        }
        .contextMenu {
            Button("Fix match…") { open(g) }
            if g.files.count == 1 {
                Button("Play") { Task { await DetailCommon.playFile(g.files[0]) } }
            }
            if Accounts.isLocal(g.files[0].accountEmail) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(g.files.map { URL(fileURLWithPath: $0.driveId) })
                }
            }
            Divider()
            Button("Ignore") { model.ignore(g) }
        }
    }

    private func ignoredCard(_ g: FileGroup) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(g.title).vTitleSmall(Theme.textMuted).lineLimit(1)
                Text(g.files[0].name).vBodySmall(Theme.textFaint).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VButton("Restore", kind: .text, compact: true) { model.restore(g) }.fixedSize()
        }
        .vPanel()
        .contextMenu { Button("Restore") { model.restore(g) } }
    }
}
