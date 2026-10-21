import AppKit
import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// Settings section for Google Drive (Windows `AccountsSection`): connected Google accounts (photo, name, email;
/// "Reconnect" when Google refused the stored sign-in; "Remove"), "Add Google account", and the "Google sign-in"
/// panel that imports the user's own Desktop OAuth client file.
public struct AccountsSection: View {
    /// List every Google account (default). A host that already shows account panels can turn this off; accounts
    /// that need reconnecting are listed either way.
    let showAccounts: Bool
    @StateObject private var model = AccountsModel()

    public init(showAccounts: Bool = true) { self.showAccounts = showAccounts }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.accounts.filter { showAccounts || model.needsReconnect($0.email) }, id: \.email) { a in
                accountRow(a)
            }
            VButton("Add Google account", icon: "person.crop.circle.badge.plus", kind: .secondary, loading: model.connecting) {
                Task { await model.connect(nil) }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            clientPanel
        }
        .onAppear { model.reload() }
    }

    private func accountRow(_ a: AccountEntity) -> some View {
        let reconnect = model.needsReconnect(a.email)
        return HStack(spacing: 14) {
            AccountAvatar(account: a, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(FileUi.accountName(a)).vTitleSmall().lineLimit(1)
                Text(a.email).vBodySmall(Theme.textMuted).lineLimit(1)
                if reconnect {
                    Text("Needs reconnecting: Google asked to sign in again.").vBodySmall(Theme.danger)
                }
            }
            Spacer(minLength: 8)
            if reconnect {
                VButton("Reconnect", kind: .text, compact: true) { Task { await model.connect(a.email) } }
            }
            VButton("Remove", kind: .textMuted, compact: true) {
                Task {
                    _ = await AccountsSection.confirmAndRemove(a)
                    model.reload()
                }
            }
        }
        .vPanel(padding: 14)
        .contextMenu {
            if reconnect { Button("Reconnect") { Task { await model.connect(a.email) } } }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(a.email, forType: .string)
            }
            Button("Remove…", role: .destructive) { Task { _ = await AccountsSection.confirmAndRemove(a); model.reload() } }
        }
    }

    private var clientPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Google sign-in").vTitleSmall()
            if let client = model.client {
                Text("OAuth client \(client.maskedId) · Desktop app").vBodySmall(Theme.textMuted).padding(.top, 4).padding(.bottom, 10)
                HStack(spacing: 8) {
                    VButton("Change client file", kind: .ghost, compact: true) {
                        Task { await ConnectGoogle.importClient(); model.reload() }
                    }
                    VButton("Setup guide", icon: "arrow.up.right.square", kind: .text, compact: true) { ConnectGoogle.openGuide() }
                }
            } else {
                Text("To connect Google Drive, Veltoret uses your own Google Cloud OAuth client (type \"Desktop app\"). " +
                     "Create one, download its JSON file, and import it here.")
                    .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 10)
                HStack(spacing: 8) {
                    VButton("Import client file", kind: .secondary, compact: true) {
                        Task { await ConnectGoogle.importClient(); model.reload() }
                    }
                    VButton("How to create one", icon: "arrow.up.right.square", kind: .text, compact: true) { ConnectGoogle.openGuide() }
                }
            }
        }
        .vPanel()
    }

    /// Asks "Remove {email}?" and removes the account: its library rows and, for Google, this Mac's stored sign-in.
    /// Settings should call this (not just `library.removeAccount`) so the refresh token is deleted too.
    @MainActor
    public static func confirmAndRemove(_ a: AccountEntity) async -> Bool {
        guard await removeDialog(a) else { return false }
        do {
            try AppServices.library.removeAccount(a.email)
            if Accounts.isDrive(a.email) { await AppServices.googleAuth?.signOut(a.email) }
            return true
        } catch {
            Toast.show(FileUi.message(error))
            return false
        }
    }

    /// The Remove account dialog for any source (texts per source, as on Android).
    @MainActor
    public static func removeDialog(_ a: AccountEntity) async -> Bool {
        let title: String, text: String
        if Accounts.isLocal(a.email) {
            title = "Remove \(Accounts.deviceDisplayName)?"
            text = "Its folders will be removed from your library. Nothing is deleted from this Mac."
        } else if Accounts.isSmb(a.email) {
            title = "Remove \(FileUi.accountName(a))?"
            text = "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server."
        } else {
            title = "Remove \(a.email)?"
            text = "Its folders will be removed from your library. Nothing is deleted from Google Drive."
        }
        return await Dialogs.confirm(title: title, message: text, confirm: "Remove", danger: true)
    }
}

@MainActor
private final class AccountsModel: ObservableObject {
    @Published var accounts: [AccountEntity] = []
    @Published var client: OAuthClient?
    @Published var connecting = false
    @Published private var reconnect: Set<String> = []
    private let subs = SubscriptionBag()

    init() {
        if let db = AppServices.db {
            subs.add(db.changed.subscribe { [weak self] tables in
                guard tables.contains("accounts") else { return }
                DispatchQueue.main.async { self?.reload() }
            })
        }
        if let auth = AppServices.googleAuth {
            subs.add(auth.changed.subscribe { [weak self] _ in DispatchQueue.main.async { self?.reload() } })
            subs.add(auth.reconnectNeeded.subscribe { [weak self] _ in DispatchQueue.main.async { self?.reload() } })
        }
        reload()
    }

    deinit { subs.cancelAll() }

    func needsReconnect(_ email: String) -> Bool { reconnect.contains(email) }

    func reload() {
        let all = (try? AppServices.library?.accountList()) ?? (try? AppServices.accountDao?.accounts()) ?? []
        accounts = all.filter { Accounts.isDrive($0.email) }
        let auth = AppServices.googleAuth
        client = auth?.client
        reconnect = Set(accounts.map(\.email).filter { auth?.needsReconnect($0) ?? false })
    }

    func connect(_ email: String?) async {
        if connecting { return }
        connecting = true
        _ = await ConnectGoogle.run(reconnectEmail: email)
        connecting = false
        reload()
    }
}
