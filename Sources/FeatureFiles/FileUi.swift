import AppKit
import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// Small helpers shared by the Files, Archives and account screens (Windows `FileUi`).
enum FileUi {
    // MARK: Items

    static func isVideo(_ f: StorageItem) -> Bool {
        !f.isFolder && (FilenameParser.isVideo(f.name, mimeType: f.mimeType) || f.mimeType.hasPrefix("video/"))
    }

    static func isZip(_ f: StorageItem) -> Bool { !f.isFolder && FilenameParser.isArchive(f.name) }

    static func isImage(_ f: StorageItem) -> Bool { f.mimeType.hasPrefix("image/") }

    static func isSubtitle(_ f: StorageItem) -> Bool { !f.isFolder && FilenameParser.isSubtitle(f.name) }

    /// The Files screen lists folders, videos, subtitles and ZIPs only.
    static func isUseful(_ f: StorageItem) -> Bool { f.isFolder || isVideo(f) || isSubtitle(f) || isZip(f) }

    /// SF Symbol and colour of an item's tile.
    static func look(_ f: StorageItem) -> (icon: String, color: Color) {
        if f.isFolder { return ("folder.fill", Theme.amber) }
        if isVideo(f) { return ("film", Theme.text) }
        if isSubtitle(f) { return ("captions.bubble", Theme.textMuted) }
        if isZip(f) { return ("doc.zipper", Theme.amberSoft) }
        if isImage(f) { return ("photo", Theme.textMuted) }
        return ("doc", Theme.textMuted)
    }

    // MARK: Accounts

    static func accountName(_ a: AccountEntity) -> String {
        if Accounts.isLocal(a.email) { return Accounts.deviceDisplayName }
        let n = a.displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? a.email : n
    }

    /// The switcher's text: "This Mac" / server name / email.
    static func switcherName(_ a: AccountEntity) -> String {
        if Accounts.isLocal(a.email) { return Accounts.deviceDisplayName }
        if Accounts.isSmb(a.email) { return accountName(a) }
        return a.email
    }

    static func accountSubtitle(_ a: AccountEntity) -> String {
        if Accounts.isLocal(a.email) { return "Folders on this Mac, external drives and USB" }
        if Accounts.isSmb(a.email) { return "Network server · " + String(a.email.dropFirst("smb://".count)) }
        return a.email
    }

    static func accountSymbol(_ email: String) -> String {
        if Accounts.isLocal(email) { return "desktopcomputer" }
        if Accounts.isSmb(email) { return "server.rack" }
        return "person.crop.circle"
    }

    /// Exception text for a toast (`error.message ?? fallback`).
    static func message(_ error: Error, _ fallback: String = "Something went wrong") -> String {
        if let e = error as? ConnectError { return e.message }
        let text: String
        if let l = error as? LocalizedError, let d = l.errorDescription { text = d } else {
            let ns = error as NSError
            text = ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain ? ns.localizedDescription : "\(error)"
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    static func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Google = profile photo (or first letter in a circle); This Mac = computer; network server = server.
struct AccountAvatar: View {
    let account: AccountEntity
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.surfaceHighest)
            if Accounts.isDrive(account.email) {
                let name = FileUi.accountName(account)
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(Theme.sans(size * 0.42, .semibold))
                    .foregroundStyle(Theme.amber)
                if let photo = account.photoUrl, !photo.isEmpty {
                    ArtworkImage(url: photo, cornerRadius: size / 2, maxPixel: Int(size * 2))
                        .clipShape(Circle())
                }
            } else {
                Image(systemName: FileUi.accountSymbol(account.email))
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Theme.amber)
            }
            Circle().strokeBorder(Theme.outline, lineWidth: 1)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Menus

/// One menu command, rendered both as an AppKit pop-up menu (buttons) and a SwiftUI context menu (right-click).
struct MenuEntry: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String?
    var danger = false
    var checked = false
    var enabled = true
    var subtitle: String?
    /// A separator line (title ignored).
    var separator = false
    var action: @MainActor () -> Void = {}

    static var divider: MenuEntry { MenuEntry(title: "", separator: true) }
}

/// Pops an NSMenu at the mouse pointer (Windows `ShowMenu`).
@MainActor
enum PopupMenu {
    private final class Target: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { MainActor.assumeIsolated { action() } }
    }

    static func show(_ entries: [MenuEntry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        var targets: [Target] = []
        for e in entries {
            if e.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: #selector(Target.run), keyEquivalent: "")
            let t = Target(e.action)
            targets.append(t)
            item.target = t
            item.isEnabled = e.enabled
            item.state = e.checked ? .on : .off
            if let s = e.symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
                item.image = img
            }
            let color: NSColor = e.danger ? NSColor(Theme.danger) : .labelColor
            let title = NSMutableAttributedString(string: e.title, attributes: [.foregroundColor: color,
                                                                                 .font: NSFont.menuFont(ofSize: 0)])
            if let sub = e.subtitle {
                title.append(NSAttributedString(string: "\n" + sub, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)]))
            }
            item.attributedTitle = title
            item.representedObject = t
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}

/// SwiftUI rendering of the same entries (for `.contextMenu`).
struct MenuEntriesView: View {
    let entries: [MenuEntry]
    var body: some View {
        ForEach(entries) { e in
            if e.separator {
                Divider()
            } else if e.danger {
                Button(role: .destructive) { e.action() } label: { label(e) }.disabled(!e.enabled)
            } else {
                Button { e.action() } label: { label(e) }.disabled(!e.enabled)
            }
        }
    }

    @ViewBuilder private func label(_ e: MenuEntry) -> some View {
        if let s = e.symbol { Label(e.title, systemImage: e.checked ? "checkmark" : s) } else { Text(e.title) }
    }
}

/// 44×44 rounded tile with the item's icon (a check when selected).
struct FileTile: View {
    let icon: String
    let color: Color
    var selected = false
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.amber : Theme.surfaceHigh)
            Image(systemName: selected ? "checkmark.circle.fill" : icon)
                .font(.system(size: size * 0.42))
                .foregroundStyle(selected ? Theme.onAmber : color)
        }
        .frame(width: size, height: size)
    }
}

/// Storage summary + a 4 pt bar (amber, danger from 90 %).
struct StorageSpaceView: View {
    let space: StorageSpace
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DriveFormat.storageSummary(space)).vBodySmall(Theme.textMuted).lineLimit(1)
            if let fraction = DriveFormat.storageFraction(space) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.outline)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DriveFormat.storageAlmostFull(space) ? Theme.danger : Theme.amber)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}
