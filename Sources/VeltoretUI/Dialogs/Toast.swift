import SwiftUI
import VeltoretKit

/// In-app snackbar at the bottom of the main window (Android Snackbar, Windows `Toast`). Safe from any thread.
///
/// `Toast.show("Removed from your Watchlist")`, `Toast.show("Folder removed", actionTitle: "Undo") { … }`.
/// Shows 3.5 s (6 s with an action); a new toast replaces the current one. `AppServices.toast` routes here.
public enum Toast {
    public static func show(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in ToastCenter.shared.show(message, actionTitle: actionTitle, action: action) }
    }
}

/// The toast state the hosts render. One toast at a time.
@MainActor
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()

    public struct Item: Identifiable {
        public let id = UUID()
        public let message: String
        public let actionTitle: String?
        public let action: (@MainActor () -> Void)?
    }

    @Published public private(set) var current: Item?
    private var hideTask: Task<Void, Never>?

    public func show(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let hasAction = actionTitle != nil && action != nil
        let item = Item(message: message, actionTitle: hasAction ? actionTitle : nil, action: hasAction ? action : nil)
        withAnimation(.easeOut(duration: 0.2)) { current = item }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((hasAction ? 6 : 3.5) * 1_000_000_000))
            if Task.isCancelled { return }
            self?.hide(item.id)
        }
    }

    public func hide(_ id: UUID? = nil) {
        guard let c = current, id == nil || c.id == id else { return }
        withAnimation(.easeIn(duration: 0.18)) { current = nil }
    }
}

/// Renders `ToastCenter` at the bottom center. The shell includes one; other windows (the player) may add their own.
public struct ToastHostView: View {
    @ObservedObject private var center = ToastCenter.shared
    public init() {}

    public var body: some View {
        VStack {
            Spacer()
            if let t = center.current {
                HStack(spacing: 16) {
                    Text(t.message).vBodyMedium().frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let title = t.actionTitle, let action = t.action {
                        Button(title) { center.hide(t.id); action() }
                            .buttonStyle(.vText)
                            .padding(.vertical, -4)
                            .padding(.trailing, -8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minWidth: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceHighest))
                .vHairline(12, color: Theme.outlineStrong)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .offset(y: 12)))
                .id(t.id)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(center.current != nil)
    }
}
