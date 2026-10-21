import AppKit
import SwiftUI
import VeltoretKit
import VeltoretSmb
import VeltoretUI

/// A folder on the server: one of the "breadcrumbs" the typed address pointed into.
public struct SmbCrumb: Hashable, Sendable {
    public var id: String
    public var name: String
}

/// "Add network server" (port of Windows AddServerViewModel / Android AddServerViewModel): finds servers on the
/// network, checks the details by signing in, then saves the server (password in the Keychain) and adds it as a
/// library source. The dialog only holds the text fields.
@MainActor
public final class AddServerModel: ObservableObject {
    public static let guestRefused = SmbErrors.noGuests

    /// Servers found on the network, routers and named ones first.
    @Published public private(set) var found: [FoundServer] = []
    @Published public private(set) var scanning = false
    /// The found server the user chose; its name becomes the saved server's name.
    @Published public var picked: FoundServer?
    @Published public private(set) var busy = false
    @Published public var error: String?

    /// Set once signed in and saved: the server and the folders the typed address pointed into.
    @Published public private(set) var addedServer: SmbServer?
    public private(set) var addedCrumbs: [SmbCrumb] = []

    private let bag = MainBag()
    private var listening = false

    public init() {}

    /// Starts (or restarts) the network scan: "Scan again".
    public func scan() {
        guard let discovery = AppServices.smbDiscovery else { return }
        if !listening {
            listening = true
            bag.on(discovery.changed) { [weak self] _ in self?.syncDiscovery() }
        }
        discovery.start()
        syncDiscovery()
    }

    public func cancelScan() {
        AppServices.smbDiscovery?.stop()
        bag.cancelAll()
        listening = false
    }

    private func syncDiscovery() {
        guard let discovery = AppServices.smbDiscovery else { return }
        found = discovery.servers
        scanning = discovery.isScanning
    }

    public func pick(_ server: FoundServer) {
        picked = server
        error = nil
    }

    /// Signs in and, on success, saves the server and sets `addedServer`. Returns nil on success or the sentence shown
    /// on screen. `name` is the server's name when the caller already knows it.
    @discardableResult
    public func attempt(address: String, guest: Bool, username: String, password: String, name: String? = nil) async -> String? {
        if busy { return nil }
        guard let path = SmbPath.fromUserInput(address) else {
            return fail("Enter the server's address, like 192.168.0.10 or \\\\192.168.0.10\\Movies")
        }
        if !guest && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fail("Enter the username, or choose Guest if the server has no password")
        }

        // "WORKGROUP\user" signs in to a Windows domain or workgroup.
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain: String, user: String
        if let slash = trimmed.firstIndex(of: "\\") {
            domain = String(trimmed[..<slash]); user = String(trimmed[trimmed.index(after: slash)...])
        } else {
            domain = ""; user = trimmed
        }
        let knownName = name ?? (picked.flatMap { $0.address.caseInsensitiveCompare(path.host) == .orderedSame ? $0.name : nil })
        var server = SmbServer(host: path.host, username: guest ? "" : user, domain: guest ? "" : domain,
                               name: knownName ?? path.host)
        let secret = guest ? "" : password
        busy = true
        error = nil
        do {
            let shares = try await AppServices.smbFiles.test(server: server, password: secret)
            // Match the typed share to the server's spelling ("movies" → "Movies").
            var share: String?
            if let typed = path.share {
                guard let match = shares.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else {
                    throw SmbError("There's no shared folder called \"\(typed)\" on \(server.host)."
                        + (shares.isEmpty ? "" : " It shares: \(shares.joined(separator: ", "))"))
                }
                share = match
            }
            // A typed address gets the server's own name ("MYNAS") instead of its number, like a found one.
            if knownName == nil && path.host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
                if let netbios = await AppServices.smbDiscovery?.nameOf(path.host) { server.name = netbios }
            }
            AppServices.smbFiles.disconnect(server.account)
            AppServices.smbServers.save(server, password: secret)
            try SmbAccounts.addServerAccount(AppServices.accountDao, server)

            var crumbs: [SmbCrumb] = []
            if let share {
                var crumb = SmbPath(host: server.host, share: nil).child(share)
                crumbs.append(SmbCrumb(id: crumb.id, name: share))
                for segment in path.segments {
                    crumb = crumb.child(segment)
                    crumbs.append(SmbCrumb(id: crumb.id, name: segment))
                }
            }
            addedCrumbs = crumbs
            addedServer = server
            busy = false
            return nil
        } catch is CancellationError {
            busy = false
            return nil
        } catch {
            let message = (error as? SmbError)?.message ?? SmbErrors.describe(error)
            // Servers refuse guests as a wrong login, or (Windows, whose Guest account is off) a disabled account.
            return fail(guest && (message == SmbErrors.wrongLogin || message == SmbErrors.accountDisabled)
                        ? Self.guestRefused : message)
        }
    }

    private func fail(_ message: String) -> String {
        busy = false
        error = message
        return message
    }
}

/// "Add network server": servers found on the network (live), or an address typed or pasted the way Finder's
/// "Connect to Server" or File Explorer takes it (`\\192.168.0.10\Movies`, `smb://192.168.0.10/Movies`); a username
/// and password or guest access. The details are checked by signing in before anything is saved. Then the dialog
/// offers the Movies / TV Shows folders on the server.
@MainActor
public enum AddServerDialog {
    /// Shows the dialog; returns the server's account id ("smb://host") once it's saved, else nil.
    /// With `editing`, signs in to a saved server again (new password or user), keeping its library folders.
    public static func show(editing: SmbServer? = nil) async -> String? {
        let model = AddServerModel()
        let _: Bool? = await Dialogs.present { ctl in AddServerView(model: model, editing: editing, controller: ctl) }
        model.cancelScan()
        return model.addedServer?.account
    }
}

private struct FolderOffer: Identifiable, Hashable {
    let id = UUID()
    var folderId: String
    var name: String
}

private struct Note: Identifiable {
    let id = UUID()
    var text: String
    var color: Color
}

private struct AddServerView: View {
    @ObservedObject var model: AddServerModel
    let editing: SmbServer?
    let controller: DialogController<Bool>

    @State private var address = ""
    @State private var guest = false
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var loaded = false
    // Step 2
    @State private var offers: [FolderOffer] = []
    @State private var notes: [Note] = []

    var body: some View {
        Group {
            if let server = model.addedServer {
                folderStep(server)
            } else {
                loginStep
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing {
                address = editing.host
                username = editing.domain.isEmpty ? editing.username : "\(editing.domain)\\\(editing.username)"
                guest = editing.guest
            } else {
                model.scan()
            }
        }
        .onDisappear { model.cancelScan() }
    }

    // MARK: Step 1: find or type the server, sign in

    private var loginStep: some View {
        VDialog(title: editing == nil ? "Add network server" : "Sign in to \(editing!.displayName)", width: 560) {
            VStack(alignment: .leading, spacing: 0) {
                if editing == nil { discovered }

                fieldLabel("Server address")
                VTextField("\\\\192.168.0.10\\Movies", text: $address, icon: "server.rack", onSubmit: connect)
                    .disabled(editing != nil || model.busy)
                    .onChange(of: address) { _, _ in model.error = nil }

                HStack(spacing: 8) {
                    VChip("Username and password", selected: !guest) { setGuest(false) }
                    VChip("Guest", selected: guest) { setGuest(true) }
                }
                .disabled(model.busy)
                .padding(.vertical, 14)

                if !guest {
                    fieldLabel("Username")
                    VTextField("Username (or WORKGROUP\\username)", text: $username, icon: "person", onSubmit: connect)
                        .disabled(model.busy)
                        .onChange(of: username) { _, _ in model.error = nil }
                    fieldLabel("Password").padding(.top, 12)
                    VTextField("Password", text: $password, icon: "lock", secure: !showPassword, onSubmit: connect) {
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help(showPassword ? "Hide password" : "Show password")
                    }
                    .disabled(model.busy)
                    .onChange(of: password) { _, _ in model.error = nil }
                    Text("The password is stored in your Keychain on this Mac and is only sent to this server.")
                        .vBodySmall(Theme.textFaint).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.error, !error.isEmpty {
                    Text(error).vBodyMedium(Theme.danger).padding(.top, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            VButton(model.busy ? "Connecting…" : "Connect", kind: .primary, loading: model.busy, compact: true, action: connect)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var discovered: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shared folders on a router, NAS or computer.").vBodyMedium(Theme.textMuted).padding(.bottom, 6)
            Text("Pick a server found on your network, or enter the address you'd use in Finder's \"Connect to Server\". "
                 + "You can paste the full path to your movies folder, or just the server's address and pick the folder next.")
                .vBodyMedium(Theme.textMuted).padding(.bottom, 16).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("On your network").vTitleSmall()
                Spacer(minLength: 0)
                if model.scanning {
                    VSpinner(size: 16, lineWidth: 2)
                    Text("Searching…").vBodySmall(Theme.textMuted)
                } else {
                    VButton("Scan again", icon: "arrow.clockwise", kind: .text, compact: true) { model.scan() }
                }
            }
            .frame(minHeight: 32)
            .padding(.bottom, 8)

            if model.found.isEmpty && !model.scanning {
                Text("No servers found. Check that this Mac is on the same network as the server, or type its address below.")
                    .vBodySmall(Theme.textMuted).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
            if !model.found.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(model.found) { server in foundRow(server) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: model.found.count < 4)
                .padding(.bottom, 16)
            }
        }
    }

    private func foundRow(_ server: FoundServer) -> some View {
        let selected = model.picked?.address == server.address
        return Button {
            model.pick(server)
            address = server.address
            model.error = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: server.isRouter ? "wifi.router" : "server.rack")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.amberSoft).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.label).vBodyLarge().lineLimit(1)
                    Text(server.subtitle).vBodySmall(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.amber)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.amberDim : Theme.surface))
            .vHairline(12, color: selected ? Theme.amber : Theme.outline)
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.98))
        .disabled(model.busy)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).vLabelMedium(Theme.textMuted).padding(.bottom, 6)
    }

    private func setGuest(_ value: Bool) {
        guest = value
        model.error = nil
    }

    private func connect() {
        guard !model.busy else { return }
        let a = address, g = guest, u = username, p = password, name = editing?.name
        Task {
            let error = await model.attempt(address: a, guest: g, username: u, password: p, name: name)
            if error == nil, let server = model.addedServer {
                model.cancelScan()
                if let target = model.addedCrumbs.last {
                    offers = [FolderOffer(folderId: target.id, name: target.name)]
                }
                _ = server
            }
        }
    }

    // MARK: Step 2: choose Movies / TV Shows folders on the server

    private func folderStep(_ server: SmbServer) -> some View {
        VDialog(title: "Connected to \(server.displayName)", width: 560) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose a Movies or TV Shows folder. Veltoret scans it and keeps your library up to date.")
                    .vBodyMedium(Theme.textMuted).padding(.bottom, 16).fixedSize(horizontal: false, vertical: true)
                ForEach(offers) { offer in
                    FolderOfferRow(account: server.account, offer: offer) { note in notes.append(note) }
                        .padding(.bottom, 8)
                }
                VButton("Choose a folder…", icon: "folder", kind: .secondary, compact: true) {
                    Task {
                        if let p = await FolderPicker.pick(account: server.account) {
                            offers.append(FolderOffer(folderId: p.id, name: p.name))
                        }
                    }
                }
                .padding(.top, 4)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes) { note in
                            Text(note.text).vBodyMedium(note.color).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 14)
                }
            }
        } actions: {
            Button("Done") { controller.close(true) }.buttonStyle(VButtonStyle(.primary, compact: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A folder with "Movies" and "TV Shows" buttons that add it to the library.
private struct FolderOfferRow: View {
    let account: String
    let offer: FolderOffer
    let note: (Note) -> Void
    @State private var loading: LibraryType?
    @State private var done = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Theme.amberSoft).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name).vBodyLarge().lineLimit(1)
                Text(NetworkUI.unc(offer.folderId)).vBodySmall(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            ForEach([(label: "Movies", type: LibraryType.MOVIES), (label: "TV Shows", type: LibraryType.SHOWS)], id: \.label) { b in
                VButton(b.label, kind: .text, loading: loading == b.type, compact: true) { add(b.type) }
                    .disabled(done || (loading != nil && loading != b.type))
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .vHairline(12)
    }

    private func add(_ type: LibraryType) {
        guard loading == nil else { return }
        loading = type
        Task {
            defer { loading = nil }
            do {
                if let id = try AppServices.library.addFolder(account: account, folderId: offer.folderId, name: offer.name, type: type) {
                    note(Note(text: "Added \"\(offer.name)\" — scanning now", color: Theme.success))
                    Task { await AppServices.scans.runNow([id]) }
                } else {
                    note(Note(text: "\"\(offer.name)\" is already in your library", color: Theme.textMuted))
                }
                done = true
            } catch {
                Log.error(error, "Adding a network library folder")
                note(Note(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", color: Theme.danger))
            }
        }
    }
}
