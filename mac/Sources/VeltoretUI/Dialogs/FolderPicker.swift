import AppKit
import SwiftUI
import VeltoretKit

/// Picks a folder from any source (Windows `FolderPickerDialog`). This Mac uses NSOpenPanel; Google Drive and network
/// servers are browsed through `AppServices.storage` in a dialog. A network server's top level (its list of shares)
/// can't be chosen — only a shared folder or something inside it.
@MainActor
public enum FolderPicker {
    /// Picks a folder; returns its id (a POSIX path on This Mac) and display name, or nil when cancelled.
    public static func pick(account: String) async -> (id: String, name: String)? {
        if Accounts.isLocal(account) { return await pickLocal() }
        let r = await browse(account: account, title: "Choose a folder", choices: ["Choose this folder"])
        return r.map { ($0.id, $0.name) }
    }

    /// Picks a library folder and its kind. Drive / network: the picker's actions are "Movies" / "TV Shows";
    /// This Mac: NSOpenPanel, then `askLibraryType`.
    public static func pickLibraryFolder(account: String) async -> (id: String, name: String, type: LibraryType)? {
        if Accounts.isLocal(account) {
            guard let picked = await pickLocal() else { return nil }
            guard let type = await askLibraryType(folderName: picked.name) else { return nil }
            return (picked.id, picked.name, type)
        }
        guard let r = await browse(account: account, title: "Choose a folder", choices: ["Movies", "TV Shows"]) else { return nil }
        return (r.id, r.name, r.choice == 0 ? .MOVIES : .SHOWS)
    }

    /// "What's in {name}?" — Movies / TV Shows (nil = Cancel).
    public static func askLibraryType(folderName: String) async -> LibraryType? {
        await Dialogs.choose(title: "What's in \(folderName)?",
                             message: "Tell Veltoret whether this folder holds movies or TV shows.",
                             options: [("Movies", LibraryType.MOVIES), ("TV Shows", LibraryType.SHOWS)])
    }

    /// NSOpenPanel for a directory on this Mac (sheet on the key window when there is one).
    public static func pickLocal(title: String = "Choose a folder", prompt: String = "Choose") async -> (id: String, name: String)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? DialogHost.shared.shellWindow, window.isVisible {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        let path = url.path
        var name = FileManager.default.displayName(atPath: path)
        if name.isEmpty { name = url.lastPathComponent }
        if name.isEmpty { name = path }
        return (path, name)
    }

    /// Browses `account` in a dialog; returns the folder shown and the index of the choice button clicked.
    public static func browse(account: String, title: String, choices: [String]) async -> (id: String, name: String, choice: Int)? {
        let storage = AppServices.storage!
        let rootId = (try? storage.rootId(account)) ?? "root"
        let rootName = (try? storage.rootName(account)) ?? account
        return await Dialogs.present { ctl in
            FolderBrowser(account: account, title: title, choices: choices, root: (rootId, rootName), controller: ctl)
        }
    }
}

private struct FolderBrowser: View {
    let account: String
    let title: String
    let choices: [String]
    let root: (String, String)
    let controller: DialogController<(id: String, name: String, choice: Int)>

    @State private var path: [(id: String, name: String)] = []
    @State private var items: [StorageItem] = []
    @State private var loading = true
    @State private var status: String?
    @State private var loadTask: Task<Void, Never>?

    private var current: (id: String, name: String) { path.last ?? (root.0, root.1) }
    private var atSmbServerTop: Bool { Accounts.isSmb(account) && path.count <= 1 }

    var body: some View {
        VDialog(title: title, width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                crumbs
                ZStack {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                Button { open(item) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(Theme.amber)
                                            .frame(width: 20)
                                        Text(item.name).vBodyLarge().lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(VRowButtonStyle(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)))
                            }
                        }
                        .padding(6)
                    }
                    if loading { VSpinner(size: 32, lineWidth: 2.5) }
                    if let status, !loading {
                        Text(status).vBodyMedium(Theme.textMuted).multilineTextAlignment(.center).padding(24)
                    }
                }
                .frame(height: 360)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                .vHairline(Theme.Radius.card)
            }
        } actions: {
            Button("Cancel") { controller.close(nil) }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            ForEach(Array(choices.enumerated()), id: \.offset) { index, label in
                Button(label) { controller.close((current.id, current.name, index)) }
                    .buttonStyle(.vText)
                    .disabled(atSmbServerTop)
            }
        }
        .onAppear { if path.isEmpty { path = [(root.0, root.1)]; reload() } }
        .onDisappear { loadTask?.cancel() }
    }

    private var crumbs: some View {
        let shown = Array(path.enumerated()).suffix(4)
        return HStack(spacing: 0) {
            ForEach(Array(shown), id: \.offset) { index, crumb in
                if index > shown.first!.offset {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                }
                let last = index == path.count - 1
                Button { goTo(index) } label: {
                    Text(crumb.name).lineLimit(1).frame(maxWidth: 160)
                }
                .buttonStyle(VButtonStyle(last ? .text : .textMuted))
                .foregroundStyle(last ? Theme.text : Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private func open(_ folder: StorageItem) {
        path.append((folder.id, folder.name))
        reload()
    }

    private func goTo(_ index: Int) {
        guard index < path.count - 1 else { return }
        path.removeSubrange((index + 1)...)
        reload()
    }

    private func reload() {
        loadTask?.cancel()
        let folder = current.id
        let smbTop = atSmbServerTop
        items = []
        status = nil
        loading = true
        loadTask = Task {
            do {
                let list = try await AppServices.storage.list(account, folderId: folder)
                if Task.isCancelled { return }
                items = list.filter(\.isFolder).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if items.isEmpty { status = smbTop ? "No shared folders on this server." : "No folders here" }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                status = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            loading = false
        }
    }
}
