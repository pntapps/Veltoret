import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// The file manager (Android FilesScreen, Windows FilesPage) for every source: Google Drive (My Drive / Shared with
/// me), This Mac and network servers. Browse with breadcrumbs, search, sortable columns, multi-select (⌘-click,
/// ⇧-click, ⌘A), rename, move, new folder, delete (Drive: trash or permanently; This Mac: to the Trash), uploads to
/// Drive (button or drag and drop from Finder), play videos, extract ZIPs, set library folders, Quick Look.
struct FilesPage: View {
    @StateObject private var model: FilesModel
    @State private var dropTargeted = false

    init(account: String?, folderId: String?) {
        _model = StateObject(wrappedValue: FilesModel(account: account, folderId: folderId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.searchQuery != nil && model.account != nil {
                FilesSearchField(model: model).padding(.top, 14)
            }
            if model.searchQuery == nil && model.isDrive && model.online {
                HStack(spacing: 8) {
                    VChip("My Drive", selected: !model.sharedRoot) { model.setSharedRoot(false) }
                    VChip("Shared with me", selected: model.sharedRoot) { model.setSharedRoot(true) }
                }
                .padding(.top, 14)
            }
            if model.searchQuery == nil && model.account != nil && !model.offlineHere {
                crumbs.padding(.top, 10)
            }
            if let space = model.space, model.searchQuery == nil, !model.offlineHere, model.account != nil {
                StorageSpaceView(space: space).padding(.top, 8).padding(.bottom, 4)
            }
            content.padding(.top, 10)
        }
        .padding(.leading, 32)
        .padding(.trailing, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) { overlay }
        .overlay { if dropTargeted && dropAllowed { dropHint } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: drop)
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        .vPageBackground()
        .onAppear { model.start() }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if model.selecting {
            HStack(spacing: 14) {
                VIconButton("xmark", help: "Cancel selection") { model.selection = [] }
                Text("\(model.selection.count) selected").vHeadlineSmall().lineLimit(1)
                Spacer(minLength: 8)
                let sel = model.selectedItems
                VIconButton("folder.badge.gearshape", help: "Move") { model.moveSelection() }
                    .disabled(!model.movable).opacity(model.movable ? 1 : 0.4)
                VIconButton("trash", help: model.isDrive ? "Move to trash" : "Delete", tint: Theme.danger) { model.trashSelection() }
                    .disabled(!model.movable).opacity(model.movable ? 1 : 0.4)
                if model.isDrive && !sel.isEmpty && sel.allSatisfy(\.canDelete) {
                    VIconButton("trash.slash", help: "Delete permanently", tint: Theme.danger) { model.deleteSelectionForever() }
                        .disabled(!model.movable).opacity(model.movable ? 1 : 0.4)
                }
            }
            .frame(minHeight: 76)
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files").vDisplaySmall().lineLimit(1)
                    if let acc = model.currentAccount {
                        Button { PopupMenu.show(model.accountMenu()) } label: {
                            Text(FileUi.switcherName(acc) + "  ▾").vLabelLarge(Theme.textMuted).lineLimit(1)
                                .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(VPlainButtonStyle())
                        .help("Switch source")
                    }
                }
                Spacer(minLength: 8)
                if model.account != nil {
                    HStack(spacing: 8) {
                        VIconButton("magnifyingglass", help: model.isDrive ? "Search Drive (⌘F)" : "Search this folder (⌘F)",
                                    tint: model.searchQuery != nil ? Theme.amber : nil) { model.toggleSearch() }
                        VIconButton("arrow.up.arrow.down", help: "Sort") { PopupMenu.show(model.sortMenu()) }
                        if model.refreshing {
                            VSpinner(size: 18).frame(width: 42, height: 42)
                        } else {
                            VIconButton("arrow.clockwise", help: "Refresh") { model.load(refresh: true) }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(minHeight: 76, alignment: .top)
        }
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.stack.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint) }
                    let last = i == model.stack.count - 1
                    Button { model.goTo(i) } label: {
                        Text(c.name).vLabelLarge(last ? Theme.text : Theme.textMuted).lineLimit(1).frame(maxWidth: 220)
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(VPlainButtonStyle())
                    .disabled(last)
                }
            }
        }
        .padding(.leading, -8)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.account == nil {
            VEmptyState(icon: "folder", title: "Nothing connected yet",
                        message: "Add a folder from this Mac or an external drive. To browse Google Drive, connect an account in Settings.",
                        actionTitle: "Add a folder from this Mac") { model.addLocalFolder() }
        } else if model.offlineHere {
            VEmptyState(icon: "wifi.slash", title: "You're offline",
                        message: model.isSmb ? "Network servers need this Mac to be on their network. Folders on this Mac still work."
                            : "Google Drive needs an internet connection. Folders on this Mac still work.",
                        actionTitle: "Show This Mac") { model.showThisMac() }
        } else if model.loading {
            VLoadingBox()
        } else if let error = model.error {
            let title = model.isLocal ? "Couldn't open this folder"
                : model.isSmb ? "Couldn't reach \(model.serverName ?? "the server")" : "Couldn't reach Drive"
            if model.errorNeedsSignIn && model.isDrive {
                VEmptyState(icon: "exclamationmark.triangle", title: title, message: error, actionTitle: "Reconnect") { model.reconnect() }
            } else {
                VEmptyState(icon: "exclamationmark.triangle", title: title, message: error, actionTitle: "Retry") { model.load() }
            }
        } else if model.items.isEmpty {
            emptyState
        } else {
            FileList(model: model)
        }
    }

    @ViewBuilder private var emptyState: some View {
        let q = (model.searchQuery ?? "").trimmingCharacters(in: .whitespaces)
        if q.count >= 2 {
            VEmptyState(icon: "magnifyingglass", title: "Nothing found",
                        message: "No folders, videos, subtitles or ZIPs match \"\(q)\".")
        } else if model.isLocal && model.stack.count == 1 {
            VEmptyState(icon: "folder", title: "No folders yet",
                        message: "Pick a folder on this Mac or an external drive. Veltoret only scans the folders you choose.",
                        actionTitle: "Add a folder") { model.addLocalFolder() }
        } else if model.searchQuery == nil {
            VEmptyState(icon: "folder", title: "This folder is empty",
                        message: model.isDrive ? "Upload files or create a folder with the + button." : "Create a folder with the + button.")
        } else {
            Color.clear
        }
    }

    // MARK: Overlay (transfers + add button)

    private var overlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.transfers) { job in
                TransferCard(job: job).frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if model.showsAddButton {
                Button { PopupMenu.show(model.addMenu()) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.onAmber)
                        .frame(width: 58, height: 58)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.amber))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(VPlainButtonStyle(pressScale: 0.94))
                .help("Add")
                .accessibilityLabel("Add")
                .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.transfers.map(\.id))
        .padding(.trailing, 32)
        .padding(.bottom, 28)
    }

    // MARK: Drag and drop

    private var dropAllowed: Bool {
        guard model.account != nil, !model.offlineHere else { return false }
        return (model.isDrive && !model.atSharedRoot) || model.isLocal
    }

    private var dropHint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.amberDim.opacity(0.35))
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.amber, lineWidth: 2)
            VStack(spacing: 8) {
                Image(systemName: model.isDrive ? "icloud.and.arrow.up" : "folder.badge.plus").font(.system(size: 30)).foregroundStyle(Theme.amber)
                Text(model.isDrive ? "Drop files to upload them to \(model.current?.name ?? "this folder")"
                                   : "Drop a folder to add it to your library")
                    .vTitleMedium()
            }
            .padding(24)
            .vCard(fill: Theme.surfaceHigh)
        }
        .padding(16)
        .allowsHitTesting(false)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard dropAllowed else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let list = lock.withLock { urls }
            if !list.isEmpty { model.handleDrop(list) }
        }
        return true
    }
}

/// The search field ("Search this Drive" / "Search this folder"), focused when opened; Esc closes it.
private struct FilesSearchField: View {
    @ObservedObject var model: FilesModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                .foregroundStyle(focused ? Theme.amber : Theme.textMuted)
            ZStack(alignment: .leading) {
                if model.searchText.isEmpty {
                    Text(model.isDrive ? "Search this Drive" : "Search this folder")
                        .font(Theme.sans(16)).foregroundStyle(Theme.textFaint).allowsHitTesting(false)
                }
                TextField("", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { model.load() }
            }
            if !model.searchText.isEmpty {
                VIconButton("xmark.circle.fill", help: "Clear", size: 24, kind: .flat) { model.searchText = "" }
            }
            VIconButton("xmark", help: "Close search", size: 28, kind: .flat) { model.setSearch(nil) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            .strokeBorder(focused ? Theme.amber : Theme.outline, lineWidth: 1))
        .frame(maxWidth: 720)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.focusSearch) { _, _ in focused = true }
        .onChange(of: model.searchText) { _, t in model.searchTextChanged(t) }
    }
}

// MARK: - The list

/// Column-sortable list: Name (tile, name, library pill), Date Modified, Size, and the "More" button.
private struct FileList: View {
    @ObservedObject var model: FilesModel

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 620
            ScrollView(.vertical) {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.sorted) { item in
                            FileRow(model: model, item: item, wide: wide, selected: model.selection.contains(item.id))
                        }
                    } header: {
                        if wide { columns.background(ThemeState.shared.background) }
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 120) // room for the + button
            }
            .scrollIndicators(.automatic)
        }
    }

    private var columns: some View {
        HStack(spacing: 14) {
            header("Name", .name, ascending: true).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 58)
            header("Date Modified", .modified, ascending: false).frame(width: 130, alignment: .leading)
            header("Size", .size, ascending: false).frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 32, height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { VDivider() }
    }

    private func header(_ title: String, _ sort: FileSort, ascending: Bool) -> some View {
        let active = model.sort == sort
        let up = ascending != model.reversed
        return Button { model.setSort(sort) } label: {
            HStack(spacing: 4) {
                Text(title).vLabelMedium(active ? Theme.amber : Theme.textMuted)
                if active { Image(systemName: up ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.amber) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(VPlainButtonStyle())
        .help("Sort by \(title.lowercased())")
    }
}

private struct FileRow: View {
    @ObservedObject var model: FilesModel
    let item: StorageItem
    let wide: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let look = FileUi.look(item)
        let date = DriveFormat.driveDate(item.modifiedTime)
        HStack(spacing: 14) {
            FileTile(icon: look.icon, color: look.color, selected: selected)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).vTitleSmall().lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if item.isFolder, let type = model.libraryFolders[item.id] {
                        Text(type == .MOVIES ? "Movies library" : "TV library").vLabelSmall(Theme.amberSoft)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pill).strokeBorder(Theme.amberDim, lineWidth: 1))
                    }
                    if !wide {
                        let meta = [item.isFolder ? nil : DriveFormat.bytes(item.sizeBytes), date].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: " · ")).vBodySmall(Theme.textMuted).lineLimit(1) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                Text(date ?? "—").vBodySmall(Theme.textMuted).lineLimit(1).frame(width: 130, alignment: .leading)
                Text(item.isFolder ? "—" : DriveFormat.bytes(item.sizeBytes)).vBodySmall(Theme.textMuted).lineLimit(1)
                    .frame(width: 90, alignment: .trailing)
            }
            if model.selecting {
                Color.clear.frame(width: 32, height: 32)
            } else {
                VIconButton("ellipsis", help: "More", size: 32, kind: .flat) { PopupMenu.show(model.menu(for: item)) }
                    .opacity(hovering ? 1 : 0.6)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 6))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(selected ? Theme.amberDim : hovering ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.click(item) }
        .contextMenu { MenuEntriesView(entries: model.menu(for: item)) }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
