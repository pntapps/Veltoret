import AppKit
import SwiftUI
import VeltoretKit
import VeltoretSmb
import VeltoretUI

/// Settings → Network servers: one panel per saved SMB server (name, address, who signs in, its library folders),
/// "Sign in again", "Add library folder", "Remove", and an "Add network server" button. The Settings page therefore
/// doesn't render a second generic panel for `smb://` accounts.
public struct NetworkServersSection: View {
    @StateObject private var model = NetworkServersModel()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.servers, id: \.account) { server in
                ServerPanel(server: server, folders: model.folders[server.account] ?? [],
                            needsSignIn: model.needsSignIn.contains(server.account), refresh: model.refresh)
            }
            VButton("Add network server", icon: "server.rack", kind: .secondary) {
                Task {
                    if await AddServerDialog.show() != nil { model.refresh() }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// Asks, then removes a server: its library folders and files, the account row, the saved password and the open
    /// connection. Nothing is deleted from the server. Returns true when removed.
    @MainActor
    public static func confirmAndRemove(_ account: String) async -> Bool {
        let server = AppServices.smbServers.server(account)
        let name = server?.displayName ?? ((try? SmbPath.parse(account).host) ?? account)
        guard await Dialogs.confirm(
            title: "Remove \(name)?",
            message: "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server.",
            confirm: "Remove", danger: true) else { return false }
        do {
            try removeServer(account)
        } catch {
            Log.error(error, "Removing a network server")
            await Dialogs.alert(title: "Couldn't remove the server", message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return false
        }
        return true
    }

    /// Forgets a server without asking (library rows, password, connection).
    public static func removeServer(_ account: String) throws {
        try AppServices.library.removeAccount(account)
        AppServices.smbFiles.disconnect(account)
        AppServices.smbServers.remove(account)
    }
}

@MainActor
final class NetworkServersModel: ObservableObject {
    @Published var servers: [SmbServer] = []
    @Published var folders: [String: [LibraryFolderEntity]] = [:]
    @Published var needsSignIn: Set<String> = []
    private let bag = MainBag()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if let store = AppServices.smbServers { bag.on(store.changed) { [weak self] _ in self?.refresh() } }
        bag.on(AppServices.db.changed) { [weak self] tables in
            if tables.isEmpty || tables.contains("library_folders") || tables.contains("accounts") { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        started = false
        bag.cancelAll()
    }

    func refresh() {
        guard let store = AppServices.smbServers else { return }
        let all: [LibraryFolderEntity]
        do { all = try AppServices.accountDao.foldersSorted() } catch { Log.error(error, "Listing library folders"); all = [] }
        servers = store.servers
        folders = Dictionary(grouping: all.filter { Accounts.isSmb($0.accountEmail) }, by: \.accountEmail)
        needsSignIn = Set(servers.filter { store.password($0.account) == nil }.map(\.account))
    }
}

private struct ServerPanel: View {
    let server: SmbServer
    let folders: [LibraryFolderEntity]
    let needsSignIn: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon, name, address · user, Remove.
            HStack(spacing: 12) {
                IconDisc(systemName: "server.rack")
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).vTitleMedium().lineLimit(1)
                    Text("\\\\\(server.host) · \(who)").vBodySmall(Theme.textMuted).lineLimit(1)
                    if needsSignIn {
                        Text("Sign in to \(server.displayName) again").vBodySmall(Theme.danger)
                    }
                }
                Spacer(minLength: 8)
                Button("Remove") {
                    Task { if await NetworkServersSection.confirmAndRemove(server.account) { refresh() } }
                }
                .buttonStyle(.vTextMuted)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 8))

            VDivider()
            if folders.isEmpty {
                Text("No library folders yet.").vBodyMedium(Theme.textMuted)
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            ForEach(folders) { folder in folderRow(folder) }

            VDivider()
            HStack(spacing: 8) {
                VButton("Add library folder", icon: "folder.badge.plus", kind: .ghost, compact: true) { Task { await addFolder() } }
                VButton("Sign in again", icon: "key", kind: .ghost, compact: true) {
                    Task {
                        _ = await AddServerDialog.show(editing: server)
                        refresh()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .vHairline(Theme.Radius.card)
    }

    private var who: String {
        server.guest ? "Guest" : server.domain.isEmpty ? server.username : "\(server.domain)\\\(server.username)"
    }

    private func folderRow(_ folder: LibraryFolderEntity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.type == .MOVIES ? "film" : "tv")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.amber).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).vBodyLarge().lineLimit(1)
                Text(NetworkUI.unc(folder.driveFolderId)).vBodySmall(Theme.textFaint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VPill(folder.type == .MOVIES ? "Movies" : "TV")
            VIconButton("xmark", help: "Remove folder", size: 32, kind: .flat) {
                do {
                    try AppServices.library.removeFolder(folder.id)
                    refresh()
                } catch {
                    Log.error(error, "Removing a library folder")
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8))
    }

    private func addFolder() async {
        guard let picked = await FolderPicker.pickLibraryFolder(account: server.account) else { return }
        do {
            if let id = try AppServices.library.addFolder(account: server.account, folderId: picked.id, name: picked.name, type: picked.type) {
                Task { await AppServices.scans.runNow([id]) }
            }
            refresh()
        } catch {
            Log.error(error, "Adding a network library folder")
            await Dialogs.alert(title: "Couldn't open the server", message: SmbErrors.describe(error))
        }
    }
}
