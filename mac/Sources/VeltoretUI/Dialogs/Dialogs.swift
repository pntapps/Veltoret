import AppKit
import SwiftUI
import VeltoretKit

/// Closes a custom dialog with a result. Passed to the content builder of `Dialogs.present`.
@MainActor
public final class DialogController<Result> {
    fileprivate var finish: ((Result?) -> Void)?
    fileprivate init() {}

    /// Closes the dialog; `present` returns `result` (nil = dismissed).
    public func close(_ result: Result?) {
        let f = finish
        finish = nil
        f?(result)
    }

    /// Closes with nil (same as Esc).
    public func dismiss() { close(nil) }
}

/// Modal dialogs (Windows `DialogWindow`, Material AlertDialog look). They appear as an overlay over the main
/// window (dimmed) when it is the active window, else in a floating panel over the active window (player, menu bar).
/// Esc dismisses. All functions are async and return when the dialog closes.
@MainActor
public enum Dialogs {
    /// Yes/no confirmation. `danger` paints the confirm action red (and it isn't the Return default).
    /// Returns true when `confirm` was clicked.
    public static func confirm(title: String, message: String, confirm: String, danger: Bool = false,
                               cancel: String = "Cancel") async -> Bool {
        let r: Bool? = await present { ctl in
            VDialog(title: title) {
                VDialogMessage(message)
            } actions: {
                Button(cancel) { ctl.close(false) }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
                if danger {
                    Button(confirm) { ctl.close(true) }.buttonStyle(VButtonStyle(.textDanger))
                } else {
                    Button(confirm) { ctl.close(true) }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
                }
            }
        }
        return r ?? false
    }

    /// One-line text input ("Rename", "New folder"). `validate` returns an error message to keep the dialog open.
    /// Returns the trimmed text, or nil when cancelled.
    public static func textInput(title: String, message: String? = nil, placeholder: String = "", initial: String = "",
                                 confirm: String = "OK", cancel: String = "Cancel", secure: Bool = false,
                                 validate: ((String) -> String?)? = nil) async -> String? {
        await present { ctl in
            TextInputDialog(title: title, message: message, placeholder: placeholder, initial: initial, confirm: confirm,
                            cancel: cancel, secure: secure, validate: validate, controller: ctl)
        }
    }

    /// A message with a list of choice buttons (and Cancel). Returns the chosen value, nil when cancelled.
    /// `Dialogs.choose(title: "What's in Films?", message: "…", options: [("Movies", .MOVIES), ("TV Shows", .SHOWS)])`
    public static func choose<T>(title: String, message: String?, options: [(String, T)], cancel: String = "Cancel") async -> T? {
        await present { (ctl: DialogController<T>) in
            VDialog(title: title) {
                if let message { VDialogMessage(message) }
            } actions: {
                Button(cancel) { ctl.close(nil) }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Button(o.0) { ctl.close(o.1) }.buttonStyle(.vText)
                }
            }
        }
    }

    /// A simple message with one "OK" button.
    public static func alert(title: String, message: String, ok: String = "OK") async {
        let _: Bool? = await present { ctl in
            VDialog(title: title) { VDialogMessage(message) } actions: {
                Button(ok) { ctl.close(true) }.buttonStyle(.vText).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Presents any SwiftUI content as a modal dialog and waits for `controller.close(result)` (nil when dismissed
    /// with Esc). Wrap your content in `VDialog` for the standard frame:
    ///
    /// ```swift
    /// let name: String? = await Dialogs.present { ctl in RenameDialog(controller: ctl) }
    /// struct RenameDialog: View {
    ///     let controller: DialogController<String>
    ///     @State var text = ""
    ///     var body: some View {
    ///         VDialog(title: "Rename") { VTextField("Name", text: $text) } actions: {
    ///             Button("Cancel") { controller.dismiss() }.buttonStyle(.vTextMuted)
    ///             Button("Rename") { controller.close(text) }.buttonStyle(.vText)
    ///         }
    ///     }
    /// }
    /// ```
    public static func present<Result, Content: View>(
        dismissOnEscape: Bool = true,
        @ViewBuilder _ content: @escaping (DialogController<Result>) -> Content
    ) async -> Result? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result?, Never>) in
            let ctl = DialogController<Result>()
            let id = UUID()
            ctl.finish = { result in
                DialogHost.shared.remove(id)
                cont.resume(returning: result)
            }
            DialogHost.shared.add(DialogHost.Item(id: id, view: AnyView(content(ctl)),
                                                  onEscape: dismissOnEscape ? { ctl.dismiss() } : nil))
        }
    }

    /// Presents content without waiting; returns a handle to close it (progress dialogs). `onEscape` nil = Esc ignored.
    @discardableResult
    public static func show<Content: View>(onEscape: (() -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> DialogHandle {
        let id = UUID()
        DialogHost.shared.add(DialogHost.Item(id: id, view: AnyView(content()), onEscape: onEscape))
        return DialogHandle(id: id)
    }
}

/// Closes a dialog shown with `Dialogs.show`.
@MainActor
public struct DialogHandle {
    let id: UUID
    public func close() { DialogHost.shared.remove(id) }
}

/// The standard dialog frame: SurfaceHigh, corner 20, hairline, padding 24/22/24/20, headlineSmall serif title,
/// body (optionally scrolling), right-aligned actions (8 apart). Width: the content's, between 360 and 720 (or `width`).
public struct VDialog<Body: View, Actions: View>: View {
    let title: String?
    let width: CGFloat?
    let scrollable: Bool
    let content: Body
    let actions: Actions

    /// - Parameters:
    ///   - width: fixed content width (default: the content's own, 360…720).
    ///   - scrollable: wraps the body in a vertical ScrollView up to 560 pt tall (long content).
    public init(title: String?, width: CGFloat? = nil, scrollable: Bool = false, @ViewBuilder content: () -> Body,
                @ViewBuilder actions: () -> Actions) {
        self.title = title; self.width = width; self.scrollable = scrollable; self.content = content(); self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title).vHeadlineSmall().padding(.bottom, 16).fixedSize(horizontal: false, vertical: true)
            }
            if scrollable {
                ScrollView(.vertical) {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: 120, maxHeight: 560)
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 24)
            .padding(.trailing, -8)
            .padding(.bottom, -8)
        }
        .frame(width: width)
        .frame(minWidth: width == nil ? 360 : nil, maxWidth: width == nil ? 720 : nil)
        .fixedSize(horizontal: width == nil, vertical: false)
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous).fill(Theme.surfaceHigh))
        .vHairline(Theme.Radius.dialog)
    }
}

public extension VDialog where Actions == EmptyView {
    init(title: String?, width: CGFloat? = nil, scrollable: Bool = false, @ViewBuilder content: () -> Body) {
        self.init(title: title, width: width, scrollable: scrollable, content: content) { EmptyView() }
    }
}

/// A wrapped dialog paragraph (bodyMedium, TextMuted, max width 480).
public struct VDialogMessage: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).vBodyMedium(Theme.textMuted).frame(maxWidth: 480, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TextInputDialog: View {
    let title: String
    let message: String?
    let placeholder: String
    let initial: String
    let confirm: String
    let cancel: String
    let secure: Bool
    let validate: ((String) -> String?)?
    let controller: DialogController<String>
    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VDialog(title: title, width: 420) {
            VStack(alignment: .leading, spacing: 12) {
                if let message { VDialogMessage(message) }
                VTextField(placeholder, text: $text, secure: secure, onSubmit: submit)
                if let error { Text(error).vBodySmall(Theme.danger) }
            }
        } actions: {
            Button(cancel) { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            Button(confirm, action: submit).buttonStyle(.vText)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { if !loaded { loaded = true; text = initial } }
        .onChange(of: text) { _, _ in error = nil }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let e = validate?(t) { error = e; return }
        controller.close(t)
    }
}

// MARK: - Host

/// Holds the open dialogs. The shell's `DialogHostView` shows them over the main window; when the main window isn't
/// the active one, dialogs go to a floating panel over the active window instead.
@MainActor
public final class DialogHost: ObservableObject {
    public static let shared = DialogHost()

    public struct Item: Identifiable {
        public let id: UUID
        let view: AnyView
        let onEscape: (() -> Void)?
    }

    /// Dialogs shown in the main window overlay (last = top).
    @Published public private(set) var items: [Item] = []
    /// The main window (set by `MainShell`).
    public weak var shellWindow: NSWindow?
    private var panels: [UUID: NSPanel] = [:]

    func add(_ item: Item) {
        let key = NSApp.keyWindow
        let shellActive = shellWindow.map { w in w.isVisible && !w.isMiniaturized && (key == nil || key === w || key?.sheetParent === w) } ?? false
        if shellActive {
            withAnimation(.easeOut(duration: 0.16)) { items.append(item) }
        } else {
            showPanel(item, over: key ?? shellWindow)
        }
    }

    func remove(_ id: UUID) {
        if let p = panels.removeValue(forKey: id) {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
            return
        }
        withAnimation(.easeIn(duration: 0.12)) { items.removeAll { $0.id == id } }
    }

    /// Esc on the top dialog.
    func escapeTop() { items.last?.onEscape?() }

    private func showPanel(_ item: Item, over parent: NSWindow?) {
        let panel = DialogPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.onEscape = item.onEscape
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: item.view.padding(12).environment(\.colorScheme, .dark))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        if let parent, parent.isVisible {
            let f = parent.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panels[item.id] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private final class DialogPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Renders `DialogHost.items` over the window: a flat ImageDim scrim and the top dialog centered (fade + 0.96 → 1 scale).
/// The shell includes one.
public struct DialogHostView: View {
    @ObservedObject private var host = DialogHost.shared
    public init() {}

    public var body: some View {
        ZStack {
            if !host.items.isEmpty {
                Theme.imageDim.ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {}
            }
            ForEach(host.items) { item in
                item.view
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(item.id == host.items.last?.id)
            }
        }
        .onExitCommand(perform: host.items.isEmpty ? nil : { host.escapeTop() })
    }
}
