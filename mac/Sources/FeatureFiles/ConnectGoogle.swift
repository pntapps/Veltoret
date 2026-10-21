import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// "Add Google account" (Android: rememberAccountConnector, Windows `ConnectGoogle`): makes sure an OAuth client is
/// imported, then runs the browser sign-in behind a "Continue in your browser…" dialog that can be cancelled.
/// Failures show a dialog with the `ConnectError` title and message; setup problems add what to check in Google
/// Cloud and a link to the setup guide.
public enum ConnectGoogle {
    /// The setup guide (docs/SETUP.md, "Google Drive").
    public static let setupUrl = "https://github.com/pntapps/Veltoret/blob/main/mac/docs/SETUP.md#google-drive"

    private final class Flag { var value = false }

    /// Connects a new account (or reconnects `reconnectEmail`). Nil when it didn't happen.
    @MainActor
    public static func run(reconnectEmail: String? = nil) async -> AccountEntity? {
        guard let auth = AppServices.googleAuth else {
            Toast.show("Google Drive isn't available in this build")
            return nil
        }
        if !auth.hasClient {
            guard await importClient(firstTime: true) else { return nil }
        }

        let userCancelled = Flag()
        let task = Task<AccountEntity, Error> { try await auth.signIn(loginHint: reconnectEmail) }
        let cancel = {
            userCancelled.value = true
            task.cancel()
        }
        let handle = Dialogs.show(onEscape: cancel) {
            WaitingView(reconnectEmail: reconnectEmail, onCancel: cancel)
        }
        let result = await task.result
        handle.close()

        switch result {
        case .success(let account):
            Toast.show("Connected \(account.email)")
            if reconnectEmail != nil { AppServices.scans?.requestAutomatic() }
            return account
        case .failure(let error):
            if let e = error as? ConnectError {
                if userCancelled.value { Toast.show("\(e.title). \(e.message)"); return nil }
                if e.setupProblem { await showSetupProblem(e) } else { await Dialogs.alert(title: e.title, message: e.message) }
            } else if error is CancellationError || userCancelled.value {
                let e = ConnectError.cancelled()
                Toast.show("\(e.title). \(e.message)")
            } else {
                await Dialogs.alert(title: "Couldn't connect", message: FileUi.message(error, "Google sign-in failed."))
            }
            return nil
        }
    }

    /// Explains the Desktop OAuth client and imports its JSON file (NSOpenPanel). True when a client was imported.
    @MainActor
    @discardableResult
    public static func importClient(firstTime: Bool = false) async -> Bool {
        let r: Bool? = await Dialogs.present { ctl in ImportClientView(firstTime: firstTime, controller: ctl) }
        return r ?? false
    }

    /// Opens the setup guide in the browser.
    @MainActor
    public static func openGuide() {
        guard let url = URL(string: setupUrl), NSWorkspace.shared.open(url) else {
            Toast.show("Couldn't open your web browser")
            return
        }
    }

    /// "Google sign-in isn't set up for this build" and friends, with what to check in Google Cloud.
    @MainActor
    static func showSetupProblem(_ e: ConnectError) async {
        let importIt: Bool? = await Dialogs.present { ctl in
            VDialog(title: e.title, width: 500) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.message).vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    Text("Setup details for this Mac").vLabelLarge(Theme.amber).padding(.top, 12).padding(.bottom, 2)
                    let client = AppServices.googleAuth?.client
                    DetailRow(label: "Client ID", value: client?.maskedId ?? "None imported", copy: client?.clientId)
                    DetailRow(label: "Application type", value: "Desktop app", copy: "Desktop app")
                    DetailRow(label: "Redirect", value: "http://127.0.0.1:<port>/ (any port, nothing to enter)", copy: nil)
                    VButton("Open the setup guide", icon: "arrow.up.right.square", kind: .text, compact: true) { openGuide() }
                        .padding(.leading, -8).padding(.top, 6)
                }
            } actions: {
                Button("Close") { ctl.close(false) }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
                Button("Import client file") { ctl.close(true) }.buttonStyle(.vText)
            }
        }
        if importIt == true { await importClient() }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    let copy: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).vBodySmall(Theme.textMuted).frame(width: 130, alignment: .leading)
            Text(value).vBodySmall().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let copy {
                VIconButton("doc.on.doc", help: "Copy", size: 26, kind: .flat) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                    Toast.show("Copied")
                }
            }
        }
    }
}

/// "Continue in your browser…" while `GoogleAuthService.signIn` waits for the loopback redirect.
private struct WaitingView: View {
    let reconnectEmail: String?
    let onCancel: () -> Void

    var body: some View {
        VDialog(title: reconnectEmail == nil ? "Connecting to Google" : "Reconnecting \(reconnectEmail!)", width: 440) {
            HStack(alignment: .top, spacing: 16) {
                VSpinner(size: 26, lineWidth: 2.5)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue in your browser…").vBodyLarge()
                    Text("Pick your Google account, click Continue on \"Google hasn't verified this app\", make sure Google Drive " +
                         "access is ticked, then come back here. Veltoret waits up to 5 minutes.")
                        .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel", action: onCancel).buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
        }
    }
}

/// Imports the "Desktop app" client JSON (Windows `ConnectGoogle.ImportClient`).
private struct ImportClientView: View {
    let firstTime: Bool
    let controller: DialogController<Bool>
    @State private var error: String?

    private static let steps = [
        "1.  In Google Cloud, create a project and enable the Google Drive API.",
        "2.  Set up Google Auth Platform (Audience: External) and add your Google account as a test user.",
        "3.  Create a client: Application type Desktop app, then Download JSON.",
        "4.  Import that file here.",
    ]

    var body: some View {
        VDialog(title: firstTime ? "Set up Google sign-in" : "Import client file", width: 500) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Veltoret signs in to Google Drive through your own Google Cloud OAuth client of type \"Desktop app\" — " +
                     "nothing goes through anyone else's server. Creating one is free and takes about ten minutes:")
                    .vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.steps, id: \.self) { Text($0).vBodyMedium().fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 12)
                VButton("Open the setup guide", icon: "arrow.up.right.square", kind: .text, compact: true) { ConnectGoogle.openGuide() }
                    .padding(.leading, -8).padding(.top, 10)
                if let error { Text(error).vBodySmall(Theme.danger).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
            }
        } actions: {
            Button("Cancel") { controller.close(false) }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            VButton("Import client file", kind: .primary, compact: true) { Task { await pick() } }
        }
    }

    @MainActor
    private func pick() async {
        let panel = NSOpenPanel()
        panel.title = "Import Google OAuth client"
        panel.message = "Choose the client_secret_….json file you downloaded from Google Cloud."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        let response: NSApplication.ModalResponse
        if let w = NSApp.keyWindow ?? DialogHost.shared.shellWindow, w.isVisible {
            response = await panel.beginSheetModal(for: w)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try AppServices.googleAuth.importClientJson(url)
            Toast.show("Google sign-in is set up")
            controller.close(true)
        } catch {
            self.error = FileUi.message(error, "That isn't a Google OAuth client file.")
        }
    }
}
