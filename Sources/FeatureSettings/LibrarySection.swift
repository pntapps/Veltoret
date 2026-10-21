import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeltoretKit
import VeltoretUI

/// Live data for the Library section (Windows SettingsPage Refresh): accounts, folders, video counts, the files that
/// need a match, ignored files and archives, plus the scan state. Re-queries on `db.changed` (250 ms debounce) and
/// follows the scanner (300 ms throttle).
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var accounts: [AccountEntity] = []
    @Published private(set) var folders: [LibraryFolderEntity] = []
    @Published private(set) var counts: [Int64: Int] = [:]
    @Published private(set) var unmatched = 0
    @Published private(set) var ignored = 0
    @Published private(set) var archives = 0
    @Published private(set) var scan = ScanState()
    @Published private(set) var lastScanAt: Int64 = 0

    private var subs: [VeltoretKit.Subscription] = []
    private var refreshPending = false
    private var scanPending = false
    private static let watched: Set<String> = ["accounts", "library_folders", "media_files", "archive_files"]

    init() {
        if let db = AppServices.db {
            subs.append(db.changed.subscribe { [weak self] tables in
                guard !tables.isDisjoint(with: LibraryModel.watched) else { return }
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        if let scanner = AppServices.scanner {
            scan = scanner.state
            subs.append(scanner.stateChanged.subscribe { [weak self] _ in
                Task { @MainActor in self?.scheduleScan() }
            })
        }
        if let settings = AppServices.settings {
            lastScanAt = settings.current.lastScanAt
            subs.append(settings.changed.subscribe { [weak self] s in
                Task { @MainActor in if self?.lastScanAt != s.lastScanAt { self?.lastScanAt = s.lastScanAt } }
            })
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func scheduleScan() {
        guard !scanPending else { return }
        scanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.scanPending = false
            if let s = AppServices.scanner?.state { self.scan = s }
        }
    }

    func refresh() {
        guard let lib = AppServices.library else { return }
        do {
            accounts = try lib.accountList()
            folders = try lib.folders()
            counts = try lib.folderCounts()
            unmatched = try lib.unmatched().count
            ignored = try lib.ignored().count
            archives = try lib.archives().count
        } catch {
            Log.error(error, "Loading Settings")
        }
        if let s = AppServices.scanner?.state { scan = s }
    }

    /// This Mac first, then Google accounts. Network servers have their own section.
    var libraryAccounts: [AccountEntity] {
        accounts.filter { !Accounts.isSmb($0.email) }
            .sorted { Accounts.isLocal($0.email) && !Accounts.isLocal($1.email) }
    }

    var hasDevice: Bool { accounts.contains { Accounts.isLocal($0.email) } }

    func folders(of account: String) -> [LibraryFolderEntity] { folders.filter { $0.accountEmail == account } }
}

/// Settings → Library (Windows "Sources" + "Library"): This Mac and Google accounts with their library folders
/// (video counts, scan one folder, remove), "Add library folder", "Use files on this Mac", the scan block with live
/// progress and Cancel, "Needs a match", "Ignored files" and "ZIP archives". Folders dropped on it are added.
struct LibrarySection: View {
    @StateObject private var model = LibraryModel()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.libraryAccounts, id: \.email) { account in
                AccountPanel(account: account, folders: model.folders(of: account.email), counts: model.counts,
                             scan: model.scan)
            }
            if !model.hasDevice {
                VButton("Use files on this Mac", icon: "desktopcomputer", kind: .secondary) {
                    Task { await LibraryActions.addFolder(Accounts.device) }
                }
            }
            SettingsPanel {
                if model.scan.running {
                    ScanProgressBlock(scan: model.scan)
                } else {
                    SettingRow("Scan library now", subtitle: ScanText.idle(model.scan, lastScanAt: model.lastScanAt),
                               icon: "arrow.clockwise", chevron: false) {
                        Task {
                            _ = await MacNotifier.shared.requestAuthorizationIfNeeded()
                            await AppServices.scans?.runNow()
                        }
                    }
                }
                if model.unmatched > 0 {
                    SettingsDivider()
                    SettingRow("Needs a match",
                               subtitle: "\(model.unmatched) \(model.unmatched == 1 ? "file" : "files") need identifying",
                               icon: "exclamationmark.circle") { Navigator.shared.navigate(.fixMatch()) }
                }
                if model.ignored > 0 {
                    SettingsDivider()
                    SettingRow("Ignored files", subtitle: "\(model.ignored) kept out of your library",
                               icon: "eye.slash") { Navigator.shared.navigate(.fixMatch()) }
                }
                SettingsDivider()
                SettingRow("ZIP archives",
                           subtitle: model.archives == 0 ? "None found in your library" : "\(model.archives) waiting to be extracted",
                           icon: "doc.zipper") { Navigator.shared.navigate(.archives) }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            LibraryActions.addDropped(providers)
            return true
        }
    }
}

/// One account: avatar, name, subtitle, "Remove" (This Mac only; Google accounts are removed in their own
/// section, which also forgets the tokens), its folders and "Add library folder".
private struct AccountPanel: View {
    let account: AccountEntity
    let folders: [LibraryFolderEntity]
    let counts: [Int64: Int]
    let scan: ScanState

    private var isDevice: Bool { Accounts.isLocal(account.email) }
    private var name: String {
        if isDevice { return account.displayName.isEmpty ? Accounts.deviceDisplayName : account.displayName }
        return account.displayName.isEmpty ? account.email : account.displayName
    }

    var body: some View {
        SettingsPanel {
            HStack(spacing: 14) {
                if isDevice {
                    SettingsAvatar(icon: "desktopcomputer", letter: nil)
                } else {
                    SettingsAvatar(icon: nil, letter: String((account.displayName.isEmpty ? account.email : account.displayName)
                        .prefix(1)).uppercased())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).vTitleSmall().lineLimit(1)
                    Text(isDevice ? "Folders on this Mac, external drives and USB" : account.email)
                        .vBodySmall(Theme.textMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isDevice {
                    Button("Remove") { Task { await LibraryActions.removeDevice(account) } }
                        .buttonStyle(.vTextMuted)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 12))

            if folders.isEmpty {
                Text("No library folders yet.").vBodySmall(Theme.textMuted)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            ForEach(folders) { f in FolderRow(folder: f, count: counts[f.id] ?? 0, scan: scan) }
            VButton("Add library folder", icon: "folder.badge.plus", kind: .ghost, compact: true) {
                Task { await LibraryActions.addFolder(account.email) }
            }
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        }
    }
}

private struct FolderRow: View {
    let folder: LibraryFolderEntity
    let count: Int
    let scan: ScanState

    var body: some View {
        let hasError = scan.folderErrors[folder.id] != nil
        HStack(spacing: 0) {
            Image(systemName: folder.type == .MOVIES ? "film" : "tv")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.amber)
                .frame(width: 22).padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).vTitleSmall().lineLimit(1).truncationMode(.middle)
                Text(ScanText.folder(folder, count: count, scan)).vBodySmall(hasError ? Theme.danger : Theme.textFaint)
                    .lineLimit(2).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Accounts.isLocal(folder.accountEmail) ? folder.driveFolderId : folder.name)
            VPill(folder.type == .MOVIES ? "Movies" : "TV").padding(.leading, 10).padding(.trailing, 4)
            if scan.running && scan.currentFolderId == folder.id {
                VSpinner(size: 18).frame(width: 34, height: 34)
            } else {
                VIconButton("arrow.clockwise", help: "Scan this folder", size: 34, kind: .flat) {
                    Toast.show("Scanning \"\(folder.name)\"")
                    Task { await AppServices.scans?.runNow([folder.id]) }
                }
                .disabled(scan.waiting(folder.id))
            }
            VIconButton("xmark", help: "Remove folder", size: 34, kind: .flat) {
                do { try AppServices.library.removeFolder(folder.id) } catch { Toast.show(error.localizedDescription) }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
        .contextMenu {
            Button("Scan this folder") { Task { await AppServices.scans?.runNow([folder.id]) } }
                .disabled(scan.waiting(folder.id))
            if Accounts.isLocal(folder.accountEmail) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.driveFolderId)])
                }
            }
            Divider()
            Button("Remove folder") { try? AppServices.library.removeFolder(folder.id) }
        }
    }
}

/// The running scan (Android ScanProgress): spinner, title, step, Cancel, progress bar, counts and %, the current
/// path while reading, and "Keeps going if you close the window."
private struct ScanProgressBlock: View {
    let scan: ScanState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VSpinner(size: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScanText.title(scan)).vTitleSmall()
                    Text(ScanText.step(scan)).vBodySmall(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { AppServices.scans?.cancel() }.buttonStyle(.vText)
            }
            Group {
                if let p = scan.progress {
                    VProgressBar(Double(p), height: 4).animation(.easeInOut(duration: 0.4), value: p)
                } else {
                    IndeterminateBar()
                }
            }
            .padding(.top, 12).padding(.bottom, 8)
            HStack {
                Text(ScanText.counts(scan)).vBodySmall(Theme.textMuted)
                Spacer()
                if let p = scan.progress { Text("\(Int((Double(p) * 100).rounded()))%").vBodySmall(Theme.textMuted) }
            }
            if scan.toMatch == 0 && !scan.currentPath.isEmpty {
                Text(scan.currentPath).vBodySmall(Theme.textFaint).lineLimit(1).truncationMode(.middle).padding(.top, 4)
            }
            Text("Keeps going if you close the window.").vBodySmall(Theme.textFaint).padding(.top, 6)
        }
        .padding(16)
    }
}

/// A 4 pt bar with a sliding amber segment (unknown progress).
private struct IndeterminateBar: View {
    @State private var phase: CGFloat = -0.35
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.outline)
                Capsule().fill(Theme.amber).frame(width: geo.size.width * 0.35)
                    .offset(x: geo.size.width * phase)
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Adding and removing library folders (Windows SettingsPage.AddFolder / RemoveDevice).
@MainActor
enum LibraryActions {
    static func addFolder(_ account: String) async {
        guard let picked = await FolderPicker.pickLibraryFolder(account: account) else { return }
        add(account: account, id: picked.id, name: picked.name, type: picked.type)
    }

    static func add(account: String, id: String, name: String, type: LibraryType) {
        do {
            guard let folderId = try AppServices.library.addFolder(account: account, folderId: id, name: name, type: type) else {
                Toast.show("\"\(name)\" is already in your library")
                return
            }
            Toast.show("Added \"\(name)\" — scanning now")
            Task { await AppServices.scans?.runNow([folderId]) }
        } catch {
            Toast.show(Accounts.isLocal(account) ? "Couldn't open that folder" : error.localizedDescription)
        }
    }

    static func removeDevice(_ a: AccountEntity) async {
        let name = a.displayName.isEmpty ? Accounts.deviceDisplayName : a.displayName
        guard await Dialogs.confirm(title: "Remove \(name)?",
                                    message: "Its folders will be removed from your library. Nothing is deleted from this Mac.",
                                    confirm: "Remove", danger: true) else { return }
        let email = a.email
        Task.detached {
            do { try AppServices.library.removeAccount(email) } catch { Log.error(error, "Removing This Mac") }
        }
    }

    /// Folders dragged from Finder: ask Movies / TV Shows for each, then add them as This Mac folders.
    static func addDropped(_ providers: [NSItemProvider]) {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    Task { @MainActor in Toast.show("Drop a folder to add it to your library") }
                    return
                }
                let path = url.path
                Task { @MainActor in
                    var name = FileManager.default.displayName(atPath: path)
                    if name.isEmpty { name = url.lastPathComponent }
                    guard let type = await FolderPicker.askLibraryType(folderName: name) else { return }
                    add(account: Accounts.device, id: path, name: name, type: type)
                }
            }
        }
    }
}

extension MacNotifier {
    /// Asks for permission only while macOS hasn't asked yet (spec: "Scan library now" asks first).
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        guard MacNotifier.isSupported else { return false }
        if let s = status, s != .notDetermined { return MacNotifier.allows(s) }
        return await requestAuthorization()
    }
}
