import AppKit
import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// The cast panel (Android CastDialog + CastingScreen, Windows CastPanel): lists TVs on the network, Veltoret TVs first
/// ("Play on TV": every audio track and subtitle, pairs with a code once), then Chromecasts. A TV that has both shows
/// once, as Veltoret, with "Use Chromecast instead". While connected it is the remote. Modeless (a floating panel),
/// one at a time.
@MainActor
public enum CastPanel {
    private static var panel: CastPanelWindow?

    /// Opens the panel (or brings the open one to the front).
    public static func open() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let cast = AppServices.cast else { return }
        CastStateModel.shared.bind()
        cast.startDiscovery()
        let window = CastPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                     styleMask: [.titled, .closable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.surfaceHigh)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: CastPanelView(close: { CastPanel.close() })
            .environment(\.colorScheme, .dark))
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.onClose = {
            AppServices.cast?.stopDiscovery()
            CastPanel.panel = nil
        }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible {
            let f = parent.frame, size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        } else {
            window.center()
        }
        panel = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public static func close() { panel?.close() }

    public static var isOpen: Bool { panel != nil }
}

final class CastPanelWindow: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() {
        let c = onClose
        onClose = nil
        super.close()
        c?()
    }
}

private struct CastPanelView: View {
    let close: () -> Void
    @ObservedObject private var model = CastStateModel.shared
    @State private var pairing: CastDevice?
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showAllChromecasts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).vHeadlineSmall().padding(.bottom, 16)
            Group {
                if model.state.connected {
                    CastRemote()
                } else if let tv = pairing {
                    pairingView(tv)
                } else {
                    picker
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 24)
            .padding(.trailing, -8)
            .padding(.bottom, -8)
        }
        .frame(width: model.state.connected ? 460 : 420, alignment: .leading)
        .padding(EdgeInsets(top: 30, leading: 24, bottom: 20, trailing: 24))
        .background(Theme.surfaceHigh)
    }

    private var title: String {
        if model.state.connected { return "Casting" }
        if let tv = pairing { return "Pair with \(tv.name)" }
        return "Cast to"
    }

    @ViewBuilder private var actions: some View {
        if model.state.connected {
            Button("Close", action: close).buttonStyle(.vText).keyboardShortcut(.defaultAction)
        } else if let tv = pairing {
            Button("Back") {
                pairing = nil
                message = nil
                code = ""
            }
            .buttonStyle(.vTextMuted)
            Button("Pair") { Task { await pair(tv) } }
                .buttonStyle(.vText)
                .keyboardShortcut(.defaultAction)
                .disabled(code.count != 6 || busy)
        } else {
            Button("Cancel", action: close).buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Device list

    private var picker: some View {
        let s = model.state
        let devices = model.devices
        let tvs = devices.filter { $0.kind == .veltoret }
        let chromecasts = devices.filter { $0.kind == .chromecast }
        let linkNames = Set(tvs.map { $0.name.lowercased() })
        let hidden = chromecasts.filter { linkNames.contains($0.name.lowercased()) }
        let shown = showAllChromecasts ? chromecasts : chromecasts.filter { !linkNames.contains($0.name.lowercased()) }
        return VStack(alignment: .leading, spacing: 0) {
            if s.connecting {
                BusyRow(text: "Connecting to \(s.deviceName ?? "the TV")…")
            } else if devices.isEmpty {
                BusyRow(text: "Looking for TVs…")
                Text("This Mac and the TV or Chromecast must be on the same network.")
                    .vBodySmall(Theme.textMuted).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(tvs) { tv in
                    deviceRow(icon: AnyView(Image(systemName: "tv").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.amber)), name: tv.name, detail: tv.detail) { Task { await choose(tv) } }
                }
                ForEach(shown) { c in
                    deviceRow(icon: AnyView(CastIcon(size: 22, color: Theme.amber)), name: c.name, detail: "Chromecast") {
                        Task { await choose(c) }
                    }
                }
                if !hidden.isEmpty && !showAllChromecasts {
                    Button("Use Chromecast instead") { showAllChromecasts = true }.buttonStyle(.vTextMuted)
                }
            }
            if busy && !s.connecting {
                VSpinner(size: 20, lineWidth: 2).padding(EdgeInsets(top: 10, leading: 6, bottom: 0, trailing: 0))
            }
            if let error = message ?? s.error {
                Text(error).vBodySmall(Theme.danger).padding(.top, 10).frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceRow(icon: AnyView, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon.frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).vTitleMedium().lineLimit(1)
                    Text(detail).vBodySmall(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(VRowButtonStyle(padding: EdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)))
        .disabled(busy)
    }

    private func choose(_ device: CastDevice) async {
        if busy { return }
        message = nil
        guard let cast = AppServices.cast else { return }
        if device.kind == .chromecast || cast.tvLink.store.secret(device.id) != nil {
            do { try await cast.connect(device) } catch { message = Self.text(error) }
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await cast.tvLink.startPairing(device.asLinkTv())
            code = ""
            pairing = device
        } catch let e as LinkError {
            message = e.message
        } catch {
            Log.error(error, "Starting to pair with a TV")
            message = "Couldn't reach \(device.name). Check it's on and on the same Wi-Fi."
        }
    }

    // MARK: Pairing

    private func pairingView(_ tv: CastDevice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter the 6-digit code shown on \(tv.name). You only do this once.")
                .vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            PairCodeField(code: $code, enabled: !busy) { Task { await pair(tv) } }
                .padding(.top, 14)
            if let message {
                Text(message).vBodySmall(Theme.danger).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pair(_ tv: CastDevice) async {
        let typed = code
        guard !busy, typed.count == 6, let cast = AppServices.cast else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await cast.tvLink.pair(tv.asLinkTv(), code: typed)
            pairing = nil
            cast.refreshPairing()
            var paired = tv
            paired.paired = true
            try await cast.connect(paired)
        } catch let e as LinkError {
            // A wrong code: the TV shows a new one, so start over with an empty field.
            message = e.message
            code = ""
        } catch {
            Log.error(error, "Pairing with a TV")
            message = "Couldn't pair with \(tv.name)"
            code = ""
        }
    }

    static func text(_ error: Error) -> String {
        if let e = error as? LinkError { return e.message }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// The 6-digit pairing code: digits only (pasted text keeps its digits), auto-submits at 6.
struct PairCodeField: View {
    @Binding var code: String
    let enabled: Bool
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $code, prompt: Text("Code").foregroundStyle(Theme.textFaint))
            .textFieldStyle(.plain)
            .font(Fonts.sans(22, .semibold))
            .monospacedDigit()
            .tracking(4)
            .foregroundStyle(Theme.text)
            .tint(Theme.amber)
            .focused($focused)
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(focused ? Theme.amber : Theme.outline, lineWidth: 1))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)
            .onChange(of: code) { _, value in
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                if digits != value { code = digits; return }
                if digits.count == 6 && enabled { submit() }
            }
            .onSubmit { if code.count == 6 { submit() } }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: enabled) { _, on in if on { focused = true } }
    }
}
