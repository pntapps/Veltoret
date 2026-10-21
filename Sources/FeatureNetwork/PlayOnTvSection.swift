import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// Settings → Play on TV: the TVs this Mac is paired with (Forget), and "Pair with a TV" (find Veltoret TVs on the
/// network, then enter the 6-digit code the TV shows).
public struct PlayOnTvSection: View {
    @StateObject private var model = PairedTvsModel()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send what you watch to Veltoret on an Android TV, with every audio track and subtitle. The TV plays its own copy when it has one, or streams from this Mac.")
                .vBodyMedium(Theme.textMuted).frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            if !model.peers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.peers.enumerated()), id: \.element.id) { index, peer in
                        if index > 0 { VDivider() }
                        row(peer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                .vHairline(Theme.Radius.card)
                .padding(.bottom, 12)
            }
            VButton("Pair with a TV", icon: "tv", kind: .secondary) {
                Task {
                    await PlayOnTvPairDialog.run()
                    model.refresh()
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func row(_ peer: LinkPeer) -> some View {
        HStack(spacing: 12) {
            IconDisc(systemName: "tv")
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).vTitleMedium().lineLimit(1)
                Text("Paired · all audio tracks and subtitles").vBodySmall(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Forget") { Task { await forget(peer) } }.buttonStyle(.vTextMuted)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 8))
    }

    private func forget(_ peer: LinkPeer) async {
        guard await Dialogs.confirm(title: "Forget \(peer.name)?", message: "To play on it again, you'll pair with the code it shows.",
                                    confirm: "Forget", danger: true) else { return }
        guard let cast = AppServices.cast else { return }
        if cast.state.link?.id == peer.id { _ = await cast.disconnect() }
        cast.tvLink.forget(peer.id)
        cast.refreshPairing()
        model.refresh()
    }
}

@MainActor
final class PairedTvsModel: ObservableObject {
    @Published var peers: [LinkPeer] = []
    private let bag = MainBag()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if let store = AppServices.tvLinks { bag.on(store.changed) { [weak self] _ in self?.refresh() } }
        refresh()
    }

    func stop() {
        started = false
        bag.cancelAll()
    }

    func refresh() { peers = AppServices.tvLinks?.peers ?? [] }
}

/// Finds Veltoret TVs and pairs with one using the code it shows (no casting starts).
@MainActor
public enum PlayOnTvPairDialog {
    public static func run() async {
        guard let cast = AppServices.cast else { return }
        CastStateModel.shared.bind()
        cast.startDiscovery()
        let _: Bool? = await Dialogs.present { ctl in PairDialogView(controller: ctl) }
        cast.stopDiscovery()
    }
}

private struct PairDialogView: View {
    let controller: DialogController<Bool>
    @ObservedObject private var model = CastStateModel.shared
    @State private var target: CastDevice?
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        if let tv = target {
            VDialog(title: "Pair with \(tv.name)", width: 420) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Enter the 6-digit code shown on \(tv.name). You only do this once.")
                        .vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    PairCodeField(code: $code, enabled: !busy) { Task { await pair(tv) } }.padding(.top, 14)
                    messageView
                }
            } actions: {
                Button("Back") {
                    target = nil
                    message = nil
                    code = ""
                }
                .buttonStyle(.vTextMuted)
                Button("Pair") { Task { await pair(tv) } }
                    .buttonStyle(.vText)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6 || busy)
            }
        } else {
            VDialog(title: "Pair with a TV", width: 420) {
                VStack(alignment: .leading, spacing: 0) {
                    let tvs = model.devices.filter { $0.kind == .veltoret }
                    if tvs.isEmpty {
                        BusyRow(text: "Looking for TVs…")
                        Text("Open Veltoret on the TV and turn on \"Play from your phone\" in its settings. This Mac and the TV must be on the same network.")
                            .vBodySmall(Theme.textMuted).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(tvs) { tv in
                        Button { Task { await start(tv) } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "tv").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.amber)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.name).vTitleMedium().lineLimit(1)
                                    Text(tv.paired ? "Paired" : "Veltoret · pair once with a code").vBodySmall(Theme.textMuted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(VRowButtonStyle(padding: EdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)))
                        .disabled(busy)
                    }
                    if busy {
                        VSpinner(size: 20, lineWidth: 2).padding(EdgeInsets(top: 10, leading: 6, bottom: 0, trailing: 0))
                    }
                    messageView
                }
            } actions: {
                Button("Close") { controller.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private var messageView: some View {
        if let message {
            Text(message).vBodySmall(Theme.danger).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start(_ tv: CastDevice) async {
        guard !busy, let cast = AppServices.cast else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await cast.tvLink.startPairing(tv.asLinkTv())
            code = ""
            target = tv
        } catch let e as LinkError {
            message = e.message
        } catch {
            Log.error(error, "Starting to pair with a TV")
            message = "Couldn't reach \(tv.name). Check it's on and on the same Wi-Fi."
        }
    }

    private func pair(_ tv: CastDevice) async {
        let typed = code
        guard !busy, typed.count == 6, let cast = AppServices.cast else { return }
        busy = true
        message = nil
        do {
            try await cast.tvLink.pair(tv.asLinkTv(), code: typed)
            cast.refreshPairing()
            busy = false
            Toast.show("Paired with \(tv.name)")
            controller.close(true)
            return
        } catch let e as LinkError {
            message = e.message
        } catch {
            Log.error(error, "Pairing with a TV")
            message = "Couldn't pair with \(tv.name)"
        }
        code = ""
        busy = false
    }
}
