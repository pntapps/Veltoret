import AppKit
import SwiftUI
import VeltoretKit
import VeltoretSmb
import VeltoretUI

/// Small helpers shared by the network / cast screens.
enum NetworkUI {
    /// "1:02:03" or "2:03" (Windows CastRemote.Clock).
    static func clock(_ ms: Int64) -> String {
        let total = Int(max(0, ms) / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
    }

    /// "\\host\share\path" for an SMB folder id, else the id itself.
    static func unc(_ id: String) -> String {
        (try? SmbPath.parse(id).unc) ?? id
    }
}

/// One entry of a pop-up menu (`PopupMenu.show`).
struct PopupMenuItem {
    var title: String
    var detail: String?
    var checked: Bool
    var action: @MainActor () -> Void
}

/// An AppKit pop-up menu at the mouse (the remote's Audio / Subtitles menus; Windows ContextMenu).
@MainActor
enum PopupMenu {
    private final class Target: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { MainActor.assumeIsolated { action() } }
    }

    static func show(_ items: [PopupMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        var targets: [Target] = []
        for item in items {
            let mi = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            let target = Target(item.action)
            targets.append(target)
            mi.target = target
            mi.state = item.checked ? .on : .off
            if let detail = item.detail, !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                let text = NSMutableAttributedString(string: item.title, attributes: [.font: Fonts.nsSans(14, .regular)])
                text.append(NSAttributedString(string: "\n" + detail, attributes: [
                    .font: Fonts.nsSans(11.5, .regular), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                mi.attributedTitle = text
            }
            menu.addItem(mi)
        }
        // Keep the targets alive while the menu tracks (popUp is synchronous).
        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// Keeps an Event subscription and hops its callbacks to the main actor.
@MainActor
final class MainBag {
    private let bag = SubscriptionBag()
    func on<T>(_ event: Event<T>, _ handler: @escaping @MainActor (T) -> Void) {
        event.subscribe { value in
            let box = UncheckedBox(value)
            Task { @MainActor in handler(box.value) }
        }.store(in: bag)
    }
    func cancelAll() { bag.cancelAll() }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A round amber-dim disc with an SF Symbol (server / TV panels).
struct IconDisc: View {
    let systemName: String
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(Theme.amberDim)
            Image(systemName: systemName).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Theme.amber)
        }
        .frame(width: size, height: size)
    }
}

/// "Looking for TVs…": a spinner and a line of text.
struct BusyRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            VSpinner(size: 20, lineWidth: 2)
            Text(text).vBodyLarge().lineLimit(1)
        }
    }
}
