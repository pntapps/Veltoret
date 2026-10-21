import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// Settings → "ZIP archives" (Android ArchivesScreen, Windows ArchivesPage): ZIPs the scanner found in Drive library
/// folders, each with its latest extraction job or an "Extract to Drive" button.
struct ArchivesPage: View {
    @StateObject private var model = ArchivesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VScreenHeader("Archives", subtitle: "ZIP files in your library folders", showsBack: Navigator.shared.canGoBack)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Videos inside a ZIP can't be streamed. Extracting unpacks them into a folder next to the ZIP without saving anything on this Mac.")
                        .vBodyMedium(Theme.textMuted).frame(maxWidth: 720, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.archives.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No archives").vHeadlineSmall()
                            Text("When a ZIP turns up in your Movies or TV folders, it appears here so you can unpack it into Drive.")
                                .vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(.top, 6)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(model.archives) { a in card(a) }
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vPageBackground()
        .onAppear { model.reload() }
    }

    private func card(_ a: ArchiveFileEntity) -> some View {
        let job = model.jobs[a.driveId]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                FileTile(icon: "doc.zipper", color: Theme.amberSoft)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).vTitleSmall().lineLimit(2)
                    Text([DriveFormat.bytes(a.sizeBytes), a.relativePath, a.accountEmail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let job {
                TransferCard(job: job, title: job.isActive ? "Extracting" : "Extraction", actions: false).padding(.top, 14)
                if job.state == .failed {
                    VButton("Try again", icon: "archivebox", kind: .secondary, compact: true) { extract(a) }.padding(.top, 10)
                }
            } else {
                VButton("Extract to Drive", icon: "archivebox", kind: .primary, compact: true) { extract(a) }.padding(.top, 14)
            }
        }
        .vPanel()
        .contextMenu {
            Button("Extract to Drive") { extract(a) }
            Button("Show in Files") { AppServices.navigate(.files(account: a.accountEmail, folderId: a.parentId)) }
        }
    }

    private func extract(_ a: ArchiveFileEntity) {
        Task {
            if await ExtractDialog.show(account: a.accountEmail, zipId: a.driveId, zipName: a.name, size: a.sizeBytes, parentId: a.parentId) {
                model.refreshJobs()
            }
        }
    }
}

@MainActor
private final class ArchivesModel: ObservableObject {
    @Published var archives: [ArchiveFileEntity] = []
    @Published var jobs: [String: TransferJob] = [:]
    private let subs = SubscriptionBag()
    private var throttle: Task<Void, Never>?

    init() {
        if let db = AppServices.db {
            subs.add(db.changed.subscribe { [weak self] tables in
                guard tables.contains("archive_files") else { return }
                DispatchQueue.main.async { self?.reload() }
            })
        }
        if let t = AppServices.transfers {
            subs.add(t.jobChanged.subscribe { [weak self] job in
                guard job.kind == .extract else { return }
                DispatchQueue.main.async { self?.schedule() }
            })
            subs.add(t.jobRemoved.subscribe { [weak self] _ in DispatchQueue.main.async { self?.schedule() } })
        }
        reload()
    }

    deinit { subs.cancelAll() }

    func reload() {
        archives = ((try? AppServices.library?.archives()) ?? []).filter { Accounts.isDrive($0.accountEmail) }
        refreshJobs()
    }

    func refreshJobs() {
        var map: [String: TransferJob] = [:]
        if let t = AppServices.transfers {
            for a in archives { if let j = t.latestForZip(a.driveId) { map[a.driveId] = j } }
        }
        jobs = map
    }

    private func schedule() {
        if throttle != nil { return }
        throttle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.throttle = nil
            self?.refreshJobs()
        }
    }
}
