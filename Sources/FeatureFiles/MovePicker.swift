import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// Folder picker for "Move to" (Android: DriveFolderPicker): folders only, Drive's "My Drive" / "Shared with me"
/// chips, breadcrumbs, and the items being moved greyed out (they can't be entered or picked). "Move here" is
/// disabled at "Shared with me", at the top of This Mac or a network server, and inside a disabled folder.
@MainActor
enum MovePicker {
    struct Folder: Hashable { let id: String; let name: String }

    /// Returns the folder to move into, or nil when cancelled.
    static func pick(account: String, disabled: Set<String>, startShared: Bool = false) async -> Folder? {
        await Dialogs.present { ctl in
            MovePickerView(account: account, disabled: disabled, startShared: startShared && Accounts.isDrive(account),
                           controller: ctl)
        }
    }
}

private struct MovePickerView: View {
    let account: String
    let disabled: Set<String>
    let startShared: Bool
    let controller: DialogController<MovePicker.Folder>

    @State private var stack: [MovePicker.Folder] = []
    @State private var shared = false
    @State private var folders: [StorageItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var generation = 0

    private var isDrive: Bool { Accounts.isDrive(account) }
    private var current: MovePicker.Folder? { stack.last }
    private var atSharedRoot: Bool { shared && stack.count == 1 }
    private var atPermanentRoot: Bool { !isDrive && stack.count == 1 }
    private var canMove: Bool {
        guard let c = current else { return false }
        return !atSharedRoot && !atPermanentRoot && !disabled.contains(c.id)
    }

    var body: some View {
        VDialog(title: "Move to", width: 540) {
            VStack(alignment: .leading, spacing: 10) {
                Text(isDrive ? account : rootName).vBodySmall(Theme.textMuted).lineLimit(1).padding(.top, -10)
                if isDrive {
                    HStack(spacing: 8) {
                        VChip("My Drive", selected: !shared) { setShared(false) }
                        VChip("Shared with me", selected: shared) { setShared(true) }
                    }
                }
                crumbs
                ZStack {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(folders) { f in row(f) }
                        }
                        .padding(6)
                    }
                    if loading {
                        VSpinner(size: 30, lineWidth: 2.5)
                    } else if let error {
                        message("Couldn't load folders", error)
                    } else if folders.isEmpty {
                        message("No subfolders", "You can pick this folder, or go back up.")
                    }
                }
                .frame(height: 360)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                .vHairline(Theme.Radius.card)
                Text("Current folder: \(current?.name ?? "")").vBodySmall(Theme.textMuted).lineLimit(1).padding(.top, 2)
            }
        } actions: {
            Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            VButton("Move here", kind: .primary, compact: true) { if let c = current { controller.close(c) } }
                .disabled(!canMove)
                .opacity(canMove ? 1 : 0.5)
        }
        .onAppear {
            if stack.isEmpty {
                if startShared {
                    shared = true
                    stack = [.init(id: DriveFileSource.sharedRoot, name: "Shared with me")]
                } else {
                    let s = AppServices.storage!
                    stack = [.init(id: (try? s.rootId(account)) ?? DriveFileSource.rootFolder, name: rootName)]
                }
                load()
            }
        }
    }

    private var rootName: String { (try? AppServices.storage.rootName(account)) ?? account }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(stack.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textFaint) }
                    let last = i == stack.count - 1
                    Button {
                        if !last { stack.removeSubrange((i + 1)...); load() }
                    } label: {
                        Text(c.name).vLabelLarge(last ? Theme.text : Theme.textMuted).lineLimit(1).frame(maxWidth: 180)
                    }
                    .buttonStyle(VPlainButtonStyle())
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ f: StorageItem) -> some View {
        let off = disabled.contains(f.id)
        return Button {
            stack.append(.init(id: f.id, name: f.name))
            load()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").foregroundStyle(off ? Theme.textFaint : Theme.amber).frame(width: 20)
                Text(f.name).vBodyLarge(off ? Theme.textFaint : Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(VRowButtonStyle())
        .disabled(off)
    }

    private func message(_ title: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Text(title).vTitleSmall()
            Text(text).vBodySmall(Theme.textMuted).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func setShared(_ s: Bool) {
        if shared == s { return }
        shared = s
        stack = [s ? .init(id: DriveFileSource.sharedRoot, name: "Shared with me")
                   : .init(id: DriveFileSource.rootFolder, name: "My Drive")]
        load()
    }

    private func load() {
        guard let c = current else { return }
        generation += 1
        let gen = generation
        loading = true
        error = nil
        folders = []
        let account = account
        Task {
            do {
                let items = try await AppServices.storage.list(account, folderId: c.id)
                guard gen == generation else { return }
                folders = items.filter(\.isFolder)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                guard gen == generation else { return }
                self.error = FileUi.message(error)
            }
            loading = false
        }
    }
}
