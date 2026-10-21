import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// "Extract to Google Drive?" (Android/Windows `ExtractDialog`). Checks free space first and won't start when the
/// files can't fit — unless an earlier attempt's folder is already there (those files are skipped). Starts a
/// background extraction job (`AppServices.transfers.extract`) and says so in a toast.
public enum ExtractDialog {
    /// Shows the dialog; true when an extraction was started.
    @MainActor
    @discardableResult
    public static func show(account: String, zipId: String, zipName: String, size: Int64, parentId: String) async -> Bool {
        let name = zipName.isEmpty ? "Archive.zip" : zipName
        let choice: ExtractChoice? = await Dialogs.present { ctl in
            ExtractDialogView(account: account, zipName: name, size: size, parentId: parentId, controller: ctl)
        }
        guard let choice, let transfers = AppServices.transfers else { return false }
        transfers.extract(account: account, zipId: zipId, zipName: name, zipSize: size, parentId: parentId,
                          after: choice.after, wifiOnly: choice.wifiOnly)
        Toast.show("Extracting \(name) in the background")
        return true
    }
}

struct ExtractChoice { let after: ZipAfterExtract; let wifiOnly: Bool }

private struct ExtractDialogView: View {
    let account: String
    let zipName: String
    let size: Int64
    let parentId: String
    let controller: DialogController<ExtractChoice>

    @State private var check: ExtractCheck?
    @State private var wifiOnly = true
    @State private var after: ZipAfterExtract = .keep

    var body: some View {
        VDialog(title: "Extract to Google Drive?", width: 500) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "archivebox").font(.system(size: 24)).foregroundStyle(Theme.amber).padding(.bottom, 12)
                Text("The videos in \"\(zipName)\" will be unpacked into a new folder named \"\(DriveFormat.baseName(zipName))\" " +
                     "right next to it, then added to your library.")
                    .vBodyMedium().fixedSize(horizontal: false, vertical: true)
                Text("Nothing is saved on this Mac — the archive streams through it. It does use about \(DriveFormat.bytes(size * 2)) " +
                     "of data (downloading and uploading once), and runs in the background.")
                    .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                spaceLine
                Toggle("Only on Wi-Fi", isOn: $wifiOnly)
                    .toggleStyle(.vCheckbox)
                    .help("Waits for a network that isn't metered (not a phone hotspot or a low-data connection).")
                    .padding(.top, 16)
                Text("When it's done").vLabelLarge(Theme.amber).padding(.top, 18).padding(.bottom, 6)
                radio(.keep, "Keep the ZIP", nil)
                radio(.trash, "Move the ZIP to trash", "Recoverable for 30 days. It keeps using space until Drive's trash is emptied.")
                radio(.delete, "Delete the ZIP permanently", "Frees the space now. This can't be undone.")
                Text("The ZIP is only removed after every file inside it has been extracted successfully, so it can't make room during extraction.")
                    .vBodySmall(Theme.textFaint).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            let enabled = check.map { !$0.tooBig } ?? false
            VButton(after == .delete ? "Extract & delete ZIP" : "Extract", kind: .primary, compact: true) {
                controller.close(ExtractChoice(after: after, wifiOnly: wifiOnly))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .task {
            guard check == nil else { return }
            if let t = AppServices.transfers {
                check = await t.checkExtract(account: account, zipName: zipName, zipSize: size, parentId: parentId)
            } else {
                check = ExtractCheck(free: nil, resuming: false, size: size)
            }
        }
    }

    @ViewBuilder private var spaceLine: some View {
        if let c = check {
            if let free = c.free {
                let line = "Needs about \(DriveFormat.bytes(size)) of free space in Google Drive. You have \(DriveFormat.bytes(free)) free." +
                    (c.tooBig ? " Free up space first (Gmail and Google Photos share it), or the extraction would stop part-way."
                        : (c.resuming && free < size ? " Files from an earlier attempt are already there and are skipped, so it may fit." : ""))
                Text(line).vBodySmall(c.tooBig ? Theme.danger : Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        } else {
            HStack(spacing: 8) {
                VSpinner(size: 12, lineWidth: 1.5)
                Text("Checking free space in Google Drive…").vBodySmall(Theme.textMuted)
            }
            .padding(.top, 10)
        }
    }

    private func radio(_ value: ZipAfterExtract, _ title: String, _ text: String?) -> some View {
        Button { after = value } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(after == value ? Theme.amber : Theme.outlineStrong, lineWidth: 1.5)
                    if after == value { Circle().fill(Theme.amber).padding(4) }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).vBodyMedium()
                    if let text { Text(text).vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(VPlainButtonStyle())
        .accessibilityAddTraits(after == value ? .isSelected : [])
    }
}
