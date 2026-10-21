import AppKit
import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

enum FileSort: Hashable { case name, modified, size }

/// State and actions of the Files page (Android FilesViewModel, Windows FilesPage), for every source: Google Drive
/// (My Drive / Shared with me), This Mac and network servers.
@MainActor
final class FilesModel: ObservableObject {
    struct Crumb: Hashable { let id: String; let name: String }

    // ---- state (FilesState) ----
    @Published private(set) var accounts: [AccountEntity] = []
    @Published private(set) var account: String?
    @Published private(set) var sharedRoot = false
    @Published private(set) var stack: [Crumb] = []
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var loading = true
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var errorNeedsSignIn = false
    @Published var sort: FileSort = .name
    /// Name sorts A→Z, date and size newest/largest first; clicking the column again flips it.
    @Published var reversed = false
    @Published var selection: Set<String> = []
    private var anchor: String?
    /// nil = search closed.
    @Published private(set) var searchQuery: String?
    @Published var searchText = ""
    @Published private(set) var space: StorageSpace?
    private var spaceKey: String?
    @Published private(set) var libraryFolders: [String: LibraryType] = [:]
    @Published private(set) var online = true
    @Published private(set) var transfers: [TransferJob] = []
    @Published var quickLookURL: URL?
    /// Bumped to move keyboard focus into the search field.
    @Published private(set) var focusSearch = 0

    private var loadTask: Task<Void, Never>?
    private var spaceTask: Task<Void, Never>?
    private var searchDebounce: Task<Void, Never>?
    private var transferThrottle: Task<Void, Never>?
    private let subs = SubscriptionBag()
    private let initialAccount: String?
    private let initialFolder: String?
    private var started = false

    init(account: String?, folderId: String?) {
        initialAccount = account
        initialFolder = folderId
        FilesModel.register(self)
    }

    deinit { subs.cancelAll() }

    // MARK: - lifecycle

    func start() {
        if started { return }
        started = true
        if let db = AppServices.db {
            subs.add(db.changed.subscribe { [weak self] tables in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if tables.contains("accounts") { self.loadAccounts(initial: false) }
                    else if tables.contains("library_folders") { self.loadLibraryFolders() }
                }
            })
        }
        if let t = AppServices.transfers {
            subs.add(t.jobChanged.subscribe { [weak self] job in DispatchQueue.main.async { self?.onJobChanged(job) } })
            subs.add(t.jobRemoved.subscribe { [weak self] _ in DispatchQueue.main.async { self?.scheduleTransfers() } })
        }
        if let c = AppServices.connectivity {
            online = c.isOnline
            subs.add(c.onlineChanged.subscribe { [weak self] on in DispatchQueue.main.async { self?.onOnlineChanged(on) } })
        }
        refreshTransfers()
        loadAccounts(initial: true)
    }

    private func onOnlineChanged(_ on: Bool) {
        let was = online
        online = on
        guard let account else { return }
        if !was && on && !Accounts.isLocal(account) { load(refresh: true) }
    }

    private func onJobChanged(_ job: TransferJob) {
        scheduleTransfers()
        guard job.state == .succeeded, job.account == account else { return }
        // Show the new files: an upload into the open folder, or any finished extraction.
        if job.kind == .extract || job.parentId == current?.id { load(refresh: true) }
    }

    private func scheduleTransfers() {
        if transferThrottle != nil { return }
        transferThrottle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.transferThrottle = nil
            self.refreshTransfers()
        }
    }

    func refreshTransfers() {
        let jobs = (AppServices.transfers?.jobs ?? []).sorted { $0.createdAt < $1.createdAt }
        let extracts = jobs.filter { $0.kind == .extract && ($0.isActive || $0.state == .failed) }.prefix(2)
        let uploads = jobs.filter { $0.kind == .upload && ($0.isActive || $0.state == .failed) }.prefix(3)
        transfers = Array(extracts) + Array(uploads)
    }

    private func loadAccounts(initial: Bool) {
        accounts = (try? AppServices.library?.accountList()) ?? (try? AppServices.accountDao?.accounts()) ?? []
        if initial, let a = initialAccount, accounts.contains(where: { $0.email == a }) {
            selectAccount(a, folderId: initialFolder)
            return
        }
        if account == nil || !accounts.contains(where: { $0.email == account }) {
            if let first = accounts.first {
                selectAccount(first.email)
            } else {
                account = nil
                loading = false
                items = []
            }
        }
    }

    private func loadLibraryFolders() {
        let folders = (try? AppServices.library?.folders()) ?? []
        var map: [String: LibraryType] = [:]
        for f in folders where f.accountEmail == account && map[f.driveFolderId] == nil { map[f.driveFolderId] = f.type }
        libraryFolders = map
    }

    // MARK: - derived

    var current: Crumb? { stack.last }
    var atSharedRoot: Bool { sharedRoot && stack.count == 1 }
    var selecting: Bool { !selection.isEmpty }
    var isDrive: Bool { Accounts.isDrive(account) }
    var isLocal: Bool { Accounts.isLocal(account) }
    var isSmb: Bool { Accounts.isSmb(account) }
    var permanent: Bool { isLocal || isSmb }
    /// The top of This Mac lists places and volumes, a server's top lists shares: neither can be moved or deleted.
    var movable: Bool { !(permanent && stack.count == 1) }
    var offlineHere: Bool { !online && !isLocal && account != nil }
    var currentAccount: AccountEntity? { accounts.first { $0.email == account } }
    var serverName: String? { isSmb ? currentAccount.map(FileUi.accountName) : nil }
    var hasDeviceAccount: Bool { accounts.contains { Accounts.isLocal($0.email) } }
    var showsAddButton: Bool { account != nil && !selecting && !atSharedRoot && !offlineHere && !(isSmb && stack.count == 1) }
    var canUploadHere: Bool { isDrive && !atSharedRoot && !offlineHere && current != nil }
    var selectedItems: [StorageItem] { items.filter { selection.contains($0.id) } }

    var sorted: [StorageItem] {
        func order(_ xs: [StorageItem]) -> [StorageItem] {
            let s: [StorageItem]
            switch sort {
            case .modified: s = xs.sorted { ($0.modifiedTime ?? "") > ($1.modifiedTime ?? "") }
            case .size: s = xs.sorted { $0.sizeBytes > $1.sizeBytes }
            case .name: s = xs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            return reversed ? s.reversed() : s
        }
        return order(items.filter(\.isFolder)) + order(items.filter { !$0.isFolder })
    }

    func setSort(_ s: FileSort) {
        if sort == s { reversed.toggle() } else { sort = s; reversed = false }
    }

    // MARK: - navigation

    func selectAccount(_ email: String, folderId: String? = nil) {
        account = email
        sharedRoot = false
        selection = []
        anchor = nil
        searchQuery = nil
        searchText = ""
        space = nil
        spaceKey = nil
        items = []
        error = nil
        let storage = AppServices.storage
        let rootId = (try? storage?.rootId(email)) ?? DriveFileSource.rootFolder
        let rootName = (try? storage?.rootName(email)) ?? email
        stack = [Crumb(id: rootId, name: rootName)]
        if let folderId, !folderId.isEmpty, folderId != rootId {
            let name: String
            if Accounts.isLocal(email) {
                let n = (folderId as NSString).lastPathComponent
                name = n.isEmpty ? folderId : FileManager.default.displayName(atPath: folderId)
            } else if Accounts.isSmb(email) {
                name = folderId.split(separator: "/").last.map(String.init) ?? "Folder"
            } else {
                name = "Folder"
            }
            stack.append(Crumb(id: folderId, name: name))
        }
        loadLibraryFolders()
        load()
    }

    func setSharedRoot(_ shared: Bool) {
        if sharedRoot == shared && stack.count == 1 { return }
        sharedRoot = shared
        stack = [shared ? Crumb(id: DriveFileSource.sharedRoot, name: "Shared with me")
                        : Crumb(id: DriveFileSource.rootFolder, name: "My Drive")]
        selection = []
        closeSearchSilently()
        load()
    }

    func open(_ folder: StorageItem) {
        stack.append(Crumb(id: folder.id, name: folder.name))
        selection = []
        closeSearchSilently()
        load()
    }

    func goTo(_ index: Int) {
        guard index < stack.count - 1, index >= 0 else { return }
        stack.removeSubrange((index + 1)...)
        selection = []
        closeSearchSilently()
        load()
    }

    /// Up one folder (⌘↑). False at the top.
    @discardableResult
    func goUp() -> Bool {
        guard stack.count > 1 else { return false }
        goTo(stack.count - 2)
        return true
    }

    /// Selection → clear; search open → close; deeper than the top → up one level. False when there's nothing to do
    /// (the shell's Back then leaves the page).
    func handleBack() -> Bool {
        if quickLookURL != nil { quickLookURL = nil; return true }
        if selecting { selection = []; return true }
        if searchQuery != nil { setSearch(nil); return true }
        return goUp()
    }

    private func closeSearchSilently() {
        searchQuery = nil
        searchText = ""
        searchDebounce?.cancel()
    }

    /// Opens ("" or a query) or closes (nil) the search.
    func setSearch(_ q: String?) {
        searchDebounce?.cancel()
        searchQuery = q
        if let q {
            searchText = q
            focusSearch += 1
        } else {
            searchText = ""
            load()
        }
    }

    func toggleSearch() { setSearch(searchQuery == nil ? "" : nil) }

    /// Typing in the search field (300 ms debounce; searches from 2 characters).
    func searchTextChanged(_ text: String) {
        guard searchQuery != nil, text != searchQuery else { return }
        searchQuery = text
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            let t = (self.searchQuery ?? "").trimmingCharacters(in: .whitespaces)
            if self.searchQuery == nil || t.count >= 2 || t.isEmpty { self.load() }
        }
    }

    // MARK: - loading

    func load(refresh: Bool = false) {
        guard let account, let folder = current else { return }
        loadTask?.cancel()
        loading = !refresh || items.isEmpty
        refreshing = refresh
        error = nil
        errorNeedsSignIn = false
        refreshSpace(force: refresh)
        if offlineHere {
            loading = false
            refreshing = false
            items = []
            return
        }
        let q = searchQuery?.trimmingCharacters(in: .whitespaces)
        let shared = atSharedRoot
        loadTask = Task { [weak self] in
            do {
                guard let storage = AppServices.storage else { return }
                let result: [StorageItem]
                if let q, q.count >= 2 {
                    result = try await storage.search(account, query: q, currentFolder: folder.id)
                } else if shared {
                    result = try await storage.list(account, folderId: DriveFileSource.sharedRoot)
                } else {
                    result = try await storage.list(account, folderId: folder.id)
                }
                guard let self, !Task.isCancelled, account == self.account else { return }
                self.items = result.filter(FileUi.isUseful)
                self.selection.formIntersection(self.items.map(\.id))
            } catch {
                guard let self, !Task.isCancelled, account == self.account else { return }
                if error is CancellationError { return }
                self.items = []
                self.error = FileUi.message(error, "Couldn't load this folder")
                self.errorNeedsSignIn = error is AuthRequiredError
            }
            self?.loading = false
            self?.refreshing = false
        }
    }

    private func refreshSpace(force: Bool) {
        guard let account, let folder = current else { return }
        let key = AppServices.storage?.spaceKey(account, folderId: folder.id)
        if key == spaceKey && !force && space != nil { return }
        if key != spaceKey { space = nil }
        spaceKey = key
        guard key != nil, !offlineHere else { return }
        spaceTask?.cancel()
        spaceTask = Task { [weak self] in
            let s = try? await AppServices.storage?.space(account, folderId: folder.id)
            guard let self, !Task.isCancelled, account == self.account, key == self.spaceKey else { return }
            self.space = s ?? nil
        }
    }

    // MARK: - clicks and selection

    /// Click: ⇧ extends from the anchor, ⌘ toggles (and so does any click while selecting); otherwise opens it.
    func click(_ item: StorageItem) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.shift), let anchor {
            let list = sorted
            if let a = list.firstIndex(where: { $0.id == anchor }), let b = list.firstIndex(where: { $0.id == item.id }) {
                for i in list[min(a, b)...max(a, b)] { selection.insert(i.id) }
                return
            }
        }
        if selecting || mods.contains(.command) || mods.contains(.shift) {
            toggle(item)
            return
        }
        activate(item)
    }

    func toggle(_ item: StorageItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        anchor = item.id
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func activate(_ item: StorageItem) {
        if item.isFolder { open(item) }
        else if FileUi.isVideo(item) { play(item) }
        else if FileUi.isZip(item) && isDrive { extract(item) }
        else { Task { await FileDialogs.details(item) } }
    }

    // MARK: - menus

    /// The row's "More" / right-click menu (Windows ItemMenu). When the item is part of a multi-selection, the
    /// menu acts on the selection.
    func menu(for item: StorageItem) -> [MenuEntry] {
        if selection.count > 1 && selection.contains(item.id) { return selectionMenu() }
        var m: [MenuEntry] = []
        if FileUi.isVideo(item) { m.append(MenuEntry(title: "Play", symbol: "play.fill") { [weak self] in self?.play(item) }) }
        if item.isFolder {
            m.append(MenuEntry(title: "Open", symbol: "folder") { [weak self] in self?.open(item) })
        }
        if item.isFolder && libraryFolders[item.id] == nil {
            m.append(MenuEntry(title: "Use as Movies library", symbol: "film") { [weak self] in self?.setLibrary(item, .MOVIES) })
            m.append(MenuEntry(title: "Use as TV library", symbol: "tv") { [weak self] in self?.setLibrary(item, .SHOWS) })
        }
        m.append(.divider)
        if item.canRename { m.append(MenuEntry(title: "Rename", symbol: "pencil") { [weak self] in self?.rename(item) }) }
        if movable { m.append(MenuEntry(title: "Move", symbol: "folder.badge.gearshape") { [weak self] in self?.move([item]) }) }
        if FileUi.isZip(item) && isDrive {
            m.append(MenuEntry(title: "Extract to Drive", symbol: "archivebox") { [weak self] in self?.extract(item) })
        }
        if isLocal {
            if !item.isFolder {
                m.append(MenuEntry(title: "Quick Look", symbol: "eye") { [weak self] in self?.quickLook(item) })
            }
            m.append(MenuEntry(title: "Show in Finder", symbol: "finder") { FileUi.showInFinder(item.id) })
        }
        m.append(MenuEntry(title: "Details", symbol: "info.circle") { Task { await FileDialogs.details(item) } })
        m.append(MenuEntry(title: "Select", symbol: "checkmark.circle") { [weak self] in self?.toggle(item) })
        if item.canTrash && movable {
            m.append(.divider)
            m.append(MenuEntry(title: isDrive ? "Move to trash" : "Delete", symbol: "trash", danger: true) { [weak self] in
                self?.trash([item])
            })
        }
        if isDrive && item.canDelete && movable {
            m.append(MenuEntry(title: "Delete permanently", symbol: "trash.slash", danger: true) { [weak self] in
                self?.deleteForever([item])
            })
        }
        return m
    }

    func selectionMenu() -> [MenuEntry] {
        let sel = selectedItems
        var m: [MenuEntry] = []
        if movable { m.append(MenuEntry(title: "Move", symbol: "folder.badge.gearshape") { [weak self] in self?.moveSelection() }) }
        if isLocal {
            m.append(MenuEntry(title: "Show in Finder", symbol: "finder") {
                NSWorkspace.shared.activateFileViewerSelecting(sel.map { URL(fileURLWithPath: $0.id) })
            })
        }
        m.append(MenuEntry(title: "Cancel selection", symbol: "xmark") { [weak self] in self?.selection = [] })
        if movable {
            m.append(.divider)
            m.append(MenuEntry(title: isDrive ? "Move to trash" : "Delete", symbol: "trash", danger: true) { [weak self] in
                self?.trashSelection()
            })
            if isDrive && !sel.isEmpty && sel.allSatisfy(\.canDelete) {
                m.append(MenuEntry(title: "Delete permanently", symbol: "trash.slash", danger: true) { [weak self] in
                    self?.deleteSelectionForever()
                })
            }
        }
        return m
    }

    func sortMenu() -> [MenuEntry] {
        [("Name", FileSort.name), ("Last modified", .modified), ("Size", .size)].map { title, s in
            MenuEntry(title: title, checked: sort == s) { [weak self] in self?.sort = s; self?.reversed = false }
        }
    }

    func accountMenu() -> [MenuEntry] {
        var m = accounts.map { a in
            MenuEntry(title: FileUi.accountName(a), symbol: FileUi.accountSymbol(a.email), checked: a.email == account,
                      subtitle: FileUi.accountSubtitle(a)) { [weak self] in
                guard let self, a.email != self.account else { return }
                self.selectAccount(a.email)
            }
        }
        if !hasDeviceAccount {
            m.append(MenuEntry(title: "Files on this Mac", symbol: "desktopcomputer") { [weak self] in self?.showThisMac() })
        }
        return m
    }

    func addMenu() -> [MenuEntry] {
        var m: [MenuEntry] = []
        if isLocal && stack.count == 1 {
            m.append(MenuEntry(title: "Add a folder from this Mac", symbol: "folder.badge.plus") { [weak self] in self?.addLocalFolder() })
        } else {
            m.append(MenuEntry(title: "New folder", symbol: "folder.badge.plus") { [weak self] in self?.newFolder() })
        }
        if isDrive { m.append(MenuEntry(title: "Upload files", symbol: "icloud.and.arrow.up") { [weak self] in self?.pickUploads() }) }
        return m
    }

    // MARK: - actions

    func play(_ item: StorageItem) {
        guard let account else { return }
        Task { await AppServices.playback?.playItem(account: account, fileId: item.id, name: item.name) }
    }

    func extract(_ item: StorageItem) {
        guard let account, let current else { return }
        let parent = item.parents.first ?? current.id
        Task { [weak self] in
            if await ExtractDialog.show(account: account, zipId: item.id, zipName: item.name, size: item.sizeBytes, parentId: parent) {
                self?.refreshTransfers()
            }
        }
    }

    func quickLook(_ item: StorageItem) {
        guard isLocal, !item.isFolder else { return }
        quickLookURL = URL(fileURLWithPath: item.id)
    }

    /// Space bar: Quick Look the selected (or only) file on This Mac.
    func toggleQuickLook() -> Bool {
        if quickLookURL != nil { quickLookURL = nil; return true }
        guard isLocal else { return false }
        let files = selectedItems.filter { !$0.isFolder }
        guard let first = files.first else { return false }
        quickLookURL = URL(fileURLWithPath: first.id)
        return true
    }

    var quickLookURLs: [URL] {
        guard isLocal else { return [] }
        let sel = selectedItems.filter { !$0.isFolder }
        return (sel.isEmpty ? sorted.filter { !$0.isFolder } : sel).map { URL(fileURLWithPath: $0.id) }
    }

    func showThisMac() {
        Task { [weak self] in
            await self?.run {
                try AppServices.library.ensureDeviceAccount()
                self?.loadAccounts(initial: false)
                self?.selectAccount(Accounts.device)
            }
        }
    }

    /// Folder on this Mac → "What's in …?" → add to the library and scan it.
    func addLocalFolder() {
        Task { [weak self] in
            guard let picked = await FolderPicker.pickLocal() else { return }
            await self?.addDeviceFolder(path: picked.id, name: picked.name)
        }
    }

    func addDeviceFolder(path: String, name: String) async {
        let type = await FileDialogs.libraryType(folder: name)
        await run {
            try AppServices.library.ensureDeviceAccount()
            if let type { try Self.addToLibrary(account: Accounts.device, folderId: path, name: name, type: type) }
            if self.account != Accounts.device {
                self.loadAccounts(initial: false)
                self.selectAccount(Accounts.device)
            }
        }
    }

    private static func addToLibrary(account: String, folderId: String, name: String, type: LibraryType) throws {
        let id = try AppServices.library.addFolder(account: account, folderId: folderId, name: name, type: type)
        Toast.show("\(name) added to your \(type == .MOVIES ? "Movies" : "TV Shows") library")
        if let id, let scans = AppServices.scans { Task.detached { await scans.runNow([id]) } }
    }

    func setLibrary(_ folder: StorageItem, _ type: LibraryType) {
        guard let account else { return }
        Task { [weak self] in
            await self?.run {
                try Self.addToLibrary(account: account, folderId: folder.id, name: folder.name, type: type)
                self?.loadLibraryFolders()
            }
        }
    }

    func rename(_ item: StorageItem) {
        guard let account else { return }
        Task { [weak self] in
            guard let name = await FileDialogs.rename(item), name != item.name else { return }
            await self?.mutate {
                let newId = try await AppServices.storage.rename(account, id: item.id, newName: name)
                if newId == item.id {
                    try await AppServices.scanner?.onFileRenamed(oldId: item.id, newId: newId, newName: name)
                    if item.isFolder { AppServices.scans?.requestAutomatic() }
                } else {
                    try await AppServices.scanner?.onFilesRemoved([item.id])
                    AppServices.scans?.requestAutomatic()
                }
            }
        }
    }

    func renameSelection() {
        guard selection.count == 1, let item = selectedItems.first, item.canRename else { return }
        rename(item)
    }

    func newFolder() {
        guard let account, let current else { return }
        let parent = current.id
        Task { [weak self] in
            guard let name = await FileDialogs.newFolder() else { return }
            await self?.mutate {
                try await AppServices.storage.createFolder(account, parentId: parent, name: name)
                Toast.show("Folder created")
            }
        }
    }

    func reconnect() {
        guard let account else { return }
        Task { [weak self] in
            if await ConnectGoogle.run(reconnectEmail: account) != nil { self?.load() }
        }
    }

    func trashSelection() { trash(selectedItems) }
    func deleteSelectionForever() { deleteForever(selectedItems) }
    func moveSelection() { move(selectedItems) }

    private static func label(_ items: [StorageItem]) -> String { items.count == 1 ? items[0].name : "\(items.count) items" }

    func trash(_ items: [StorageItem]) {
        guard !items.isEmpty, let account, movable else { return }
        let server = serverName
        Task { [weak self] in
            guard await FileDialogs.trash(account: account, label: Self.label(items), serverName: server) else { return }
            await self?.mutate {
                for i in items { try await AppServices.storage.remove(account, id: i.id) }
                await self?.afterRemoved(items)
                Toast.show(FileDialogs.deletedMessage(account: account, count: items.count, permanent: false))
            }
        }
    }

    func deleteForever(_ items: [StorageItem]) {
        guard !items.isEmpty, let account, Accounts.isDrive(account), movable, items.allSatisfy(\.canDelete) else { return }
        Task { [weak self] in
            guard await FileDialogs.deleteForever(label: Self.label(items), hasFolder: items.contains(where: \.isFolder)) else { return }
            await self?.mutate {
                for i in items { try await AppServices.storage.deletePermanently(account, id: i.id) }
                await self?.afterRemoved(items)
                Toast.show(FileDialogs.deletedMessage(account: account, count: items.count, permanent: true))
            }
        }
    }

    private func afterRemoved(_ items: [StorageItem]) async {
        try? await AppServices.scanner?.onFilesRemoved(items.map(\.id))
        selection = []
        if items.contains(where: \.isFolder) { AppServices.scans?.requestAutomatic() }
    }

    func move(_ items: [StorageItem]) {
        guard !items.isEmpty, let account, let current, movable else { return }
        let from = current.id
        let disabled = Set(items.filter(\.isFolder).map(\.id))
        let startShared = atSharedRoot
        Task { [weak self] in
            guard let target = await MovePicker.pick(account: account, disabled: disabled, startShared: startShared) else { return }
            await self?.mutate {
                for i in items {
                    try await AppServices.storage.move(account, id: i.id, fromParent: i.parents.first ?? from, toParent: target.id)
                }
                if !Accounts.isDrive(account) { try await AppServices.scanner?.onFilesRemoved(items.map(\.id)) }
                self?.selection = []
                AppServices.scans?.requestAutomatic()
                Toast.show("Moved to \(target.name)")
            }
        }
    }

    // MARK: - uploads

    func pickUploads() {
        guard let account, let current else { return }
        if atSharedRoot { Toast.show("Open a folder first to upload into it"); return }
        let panel = NSOpenPanel()
        panel.title = "Upload to Google Drive"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let parent = current.id
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let w = DialogHost.shared.shellWindow, w.isVisible { response = await panel.beginSheetModal(for: w) }
            else { response = panel.runModal() }
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.upload(account: account, parentId: parent, urls: panel.urls)
        }
    }

    private func upload(account: String, parentId: String, urls: [URL]) {
        guard let t = AppServices.transfers else { return }
        t.upload(account: account, parentId: parentId, urls: urls)
        Toast.show(urls.count == 1 ? "Uploading 1 file" : "Uploading \(urls.count) files")
        refreshTransfers()
    }

    /// Files dropped from Finder: Drive uploads them into the open folder; on This Mac a dropped folder can be
    /// added to the library.
    func handleDrop(_ urls: [URL]) {
        guard let account, let current else { return }
        let fm = FileManager.default
        func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        if Accounts.isDrive(account) {
            if atSharedRoot { Toast.show("Open a folder first to upload into it"); return }
            if offlineHere { return }
            let files = urls.filter { !isDir($0) }
            if files.isEmpty { Toast.show("Only files can be uploaded, not folders"); return }
            upload(account: account, parentId: current.id, urls: files)
            if files.count < urls.count { Toast.show("Folders were skipped: only files can be uploaded") }
        } else if Accounts.isLocal(account) {
            guard let folder = urls.first(where: isDir) else {
                Toast.show("Drop a folder to add it to your library")
                return
            }
            let name = fm.displayName(atPath: folder.path)
            Task { [weak self] in await self?.addDeviceFolder(path: folder.path, name: name.isEmpty ? folder.lastPathComponent : name) }
        } else {
            Toast.show("Files can't be copied to a network server from here")
        }
    }

    // MARK: - helpers

    /// Runs a change, then refreshes the folder. Errors → toast.
    private func mutate(_ change: () async throws -> Void) async {
        do { try await change() } catch { Toast.show(FileUi.message(error)) }
        load(refresh: true)
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { Toast.show(FileUi.message(error)) }
    }

    // MARK: - the page that gets the keyboard

    private static var live: [WeakModel] = []
    private struct WeakModel { weak var model: FilesModel? }

    private static func register(_ m: FilesModel) {
        live.removeAll { $0.model == nil }
        live.append(WeakModel(model: m))
        FilesKeys.install()
    }

    /// The Files page on screen (the newest live one while a Files route is shown).
    static var shown: FilesModel? {
        guard Navigator.shared.currentRoute?.kind == .files else { return nil }
        live.removeAll { $0.model == nil }
        return live.last?.model
    }
}
