import AppKit
import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// The Files screen's dialogs, with the Android/Windows text (FileDialog.*).
@MainActor
enum FileDialogs {
    /// "Rename": field pre-filled, the base name selected for files. Returns the trimmed new name or nil.
    static func rename(_ item: StorageItem) async -> String? {
        await askName(title: "Rename", initial: item.name, confirm: "Rename", selectBase: !item.isFolder)
    }

    /// "New folder": empty field, "Create".
    static func newFolder() async -> String? {
        await askName(title: "New folder", initial: "", confirm: "Create", selectBase: false)
    }

    private static func askName(title: String, initial: String, confirm: String, selectBase: Bool) async -> String? {
        await Dialogs.present { ctl in
            NameDialog(title: title, initial: initial, confirm: confirm, selectBase: selectBase, controller: ctl)
        }
    }

    /// Drive: "Move to trash?"; This Mac: to the Trash; network server: deleted permanently.
    static func trash(account: String, label: String, serverName: String?) async -> Bool {
        if Accounts.isLocal(account) {
            return await Dialogs.confirm(title: "Delete?",
                                         message: "\"\(label)\" moves to the Trash on this Mac. You can put it back from there.",
                                         confirm: "Delete", danger: true)
        }
        if Accounts.isSmb(account) {
            return await Dialogs.confirm(title: "Delete permanently?",
                                         message: "\"\(label)\" will be deleted permanently from \(serverName ?? "the server"). " +
                                             "Network shares have no trash, so this can't be undone.",
                                         confirm: "Delete", danger: true)
        }
        return await Dialogs.confirm(title: "Move to trash?",
                                     message: "\"\(label)\" will be moved to Google Drive's trash. You can restore it from Drive for 30 days.",
                                     confirm: "Move to trash", danger: true)
    }

    /// Drive only: files.delete, skipping the trash.
    static func deleteForever(label: String, hasFolder: Bool) async -> Bool {
        await Dialogs.confirm(title: "Delete permanently?",
                              message: "\"\(label)\"" + (hasFolder ? " and everything in it" : "") +
                                  " will be deleted from Google Drive right away. It won't go to the trash, so this can't be undone.",
                              confirm: "Delete", danger: true)
    }

    /// "Deleted 1 item" / "Moved to trash" … for the toast after a delete.
    static func deletedMessage(account: String, count n: Int, permanent: Bool) -> String {
        if permanent || !Accounts.isDrive(account) { return n == 1 ? "Deleted 1 item" : "Deleted \(n) items" }
        return n == 1 ? "Moved to trash" : "\(n) items moved to trash"
    }

    /// Details: Type, Size (files), Modified, Resolution, Duration.
    static func details(_ item: StorageItem) async {
        var rows: [(String, String)] = [("Type", item.isFolder ? "Folder" : (item.mimeType.isEmpty ? "—" : item.mimeType))]
        if !item.isFolder { rows.append(("Size", DriveFormat.bytes(item.sizeBytes))) }
        rows.append(("Modified", DriveFormat.driveDate(item.modifiedTime) ?? "—"))
        if let w = item.width, let h = item.height, w > 0, h > 0 { rows.append(("Resolution", "\(w) × \(h)")) }
        if let d = item.durationMs, d > 0 { rows.append(("Duration", DriveFormat.clock(d))) }
        let _: Bool? = await Dialogs.present { ctl in
            VDialog(title: nil, width: 420) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).vHeadlineSmall().lineLimit(3).padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(r.0).vBodyMedium(Theme.textMuted).frame(width: 90, alignment: .leading)
                            Text(r.1).vBodyMedium().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } actions: {
                Button("Close") { ctl.close(true) }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// After picking a folder on this Mac: "What's in "{folder}"?" with Movies / TV Shows (dismiss "Not now").
    static func libraryType(folder: String, dismiss: String = "Not now") async -> LibraryType? {
        await Dialogs.present { (ctl: DialogController<LibraryType>) in
            VDialog(title: "What's in \"\(folder)\"?") {
                VDialogMessage("Veltoret will scan it and match everything with TMDB.")
            } actions: {
                Button(dismiss) { ctl.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
                VButton("TV Shows", icon: "tv", kind: .secondary, compact: true) { ctl.close(.SHOWS) }
                VButton("Movies", icon: "film", kind: .primary, compact: true) { ctl.close(.MOVIES) }
            }
        }
    }
}

/// Rename / New folder: a text field that takes focus and pre-selects the base name of a file.
private struct NameDialog: View {
    let title: String
    let initial: String
    let confirm: String
    let selectBase: Bool
    let controller: DialogController<String>
    @State private var text = ""
    @State private var loaded = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VDialog(title: title, width: 420) {
            SelectingTextField(text: $text, initial: initial, selectBase: selectBase, onSubmit: submit)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(Theme.amber, lineWidth: 1))
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            Button(confirm, action: submit).buttonStyle(.vText).disabled(trimmed.isEmpty)
        }
        .onAppear { if !loaded { loaded = true; text = initial } }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        controller.close(trimmed)
    }
}

/// A plain NSTextField that focuses itself and selects the name before the extension (Finder-style rename).
private struct SelectingTextField: NSViewRepresentable {
    @Binding var text: String
    let initial: String
    let selectBase: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: initial)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Fonts.nsSans(16)
        f.textColor = NSColor(Theme.text)
        f.delegate = context.coordinator
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async {
            guard let window = f.window else { return }
            window.makeFirstResponder(f)
            if let editor = f.currentEditor() {
                let ns = initial as NSString
                let dot = ns.range(of: ".", options: .backwards)
                if selectBase, dot.location != NSNotFound, dot.location > 0 {
                    editor.selectedRange = NSRange(location: 0, length: dot.location)
                } else {
                    editor.selectedRange = NSRange(location: 0, length: ns.length)
                }
            }
        }
        return f
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text, nsView.currentEditor() == nil { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectingTextField
        init(_ parent: SelectingTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
