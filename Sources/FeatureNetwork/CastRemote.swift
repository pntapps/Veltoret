import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// The remote while casting (Android CastingScreen, Windows CastRemote): artwork, what's playing on which TV, a seek
/// bar, ±10 s, play/pause, next episode, volume (Chromecast), audio and subtitle choice, and "Stop casting".
public struct CastRemote: View {
    @ObservedObject private var model = CastStateModel.shared
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var changingVolume = false
    @State private var volumeValue: Double = 0

    public init() {}

    private var cast: CastController? { AppServices.cast }

    public var body: some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 0) {
            header(s)
            if let m = messageText(s) {
                Text(m).vBodyMedium(s.error != nil ? Theme.danger : Theme.amberSoft).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            seekBar(s).padding(.top, 18)
            transport(s).padding(.top, 12)
            if s.link == nil, s.volume != nil {
                volumeRow(s).padding(.top, 14)
            }
            tracks(s).padding(.top, 18)
        }
        .frame(width: 460)
        .onAppear { model.bind() }
    }

    // MARK: Header

    private func header(_ s: CastState) -> some View {
        let media = s.media
        let title = media?.title ?? CastPlayerBridge.currentTitle ?? ""
        return HStack(alignment: .center, spacing: 16) {
            ArtworkImage(url: media?.posterUrl ?? media?.backdropUrl, fallbackText: media?.title, cornerRadius: 10,
                         outlined: true, maxPixel: 300)
                .frame(width: 96, height: 144)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    CastIcon(connected: true, size: 16, color: Theme.amber)
                    Text("Playing on \(s.deviceName ?? "TV")").vLabelLarge(Theme.amber).lineLimit(1)
                }
                .padding(.bottom, 6)
                Text(title).vTitleLarge().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let sub = media?.subtitle, !sub.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(sub).vBodyMedium(Theme.textMuted).lineLimit(1).padding(.top, 4)
                }
                if let source = sourceText(s) {
                    Text(source).vBodySmall(Theme.textMuted).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceText(_ s: CastState) -> String? {
        guard s.link != nil, let source = s.linkSource else { return nil }
        return source == LinkStatus.sourcePhone ? "Streaming from this Mac · keep it on the network" : "Playing the TV's own copy"
    }

    private func messageText(_ s: CastState) -> String? {
        let warning = s.link == nil ? s.media?.audioWarning : nil
        let text = s.error ?? warning ?? (s.finished ? "Finished" : "")
        return text.isEmpty ? nil : text
    }

    // MARK: Seek bar

    private func seekBar(_ s: CastState) -> some View {
        let duration = Double(max(1, s.durationMs))
        let position = scrubbing ? scrubValue : min(max(Double(s.positionMs), 0), duration)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { position }, set: { scrubValue = $0 }), in: 0...duration) { editing in
                if editing {
                    scrubValue = position
                    scrubbing = true
                } else if scrubbing {
                    scrubbing = false
                    cast?.seek(to: Int64(scrubValue))
                }
            }
            .controlSize(.small)
            .tint(Theme.amber)
            HStack {
                Text(NetworkUI.clock(Int64(position))).vLabelMedium(Theme.textMuted).monospacedDigit()
                Spacer()
                Text(s.durationMs > 0 ? NetworkUI.clock(s.durationMs) : "").vLabelMedium(Theme.textMuted).monospacedDigit()
            }
        }
    }

    // MARK: Transport

    private func transport(_ s: CastState) -> some View {
        HStack(spacing: 20) {
            VIconButton("gobackward.10", help: "Back 10 seconds", size: 48) { cast?.seek(by: -10_000) }
            Button { cast?.togglePlay() } label: {
                ZStack {
                    Circle().fill(Theme.amber)
                    if s.buffering {
                        VSpinner(size: 30, lineWidth: 3, color: Theme.onAmber)
                    } else {
                        Image(systemName: s.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.onAmber)
                    }
                }
                .frame(width: 68, height: 68)
                .contentShape(Circle())
            }
            .buttonStyle(VPlainButtonStyle(pressScale: 0.94))
            .help(s.playing ? "Pause" : "Play")
            .accessibilityLabel(s.playing ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
            VIconButton("goforward.10", help: "Forward 10 seconds", size: 48) { cast?.seek(by: 10_000) }
            if s.hasNext {
                VIconButton("forward.end.fill", help: "Next episode", size: 44) {
                    Task { await AppServices.cast?.playNext() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Volume (Chromecast)

    private func volumeRow(_ s: CastState) -> some View {
        let level = changingVolume ? volumeValue : (s.volume ?? 0)
        return HStack(spacing: 10) {
            VIconButton(s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: s.muted ? "Unmute" : "Mute", size: 36) {
                cast?.setMuted(!(AppServices.cast?.state.muted ?? false))
            }
            Slider(value: Binding(get: { level }, set: { v in
                volumeValue = v
                cast?.setVolume(v)
            }), in: 0...1) { editing in
                if editing { volumeValue = level }
                changingVolume = editing
            }
            .controlSize(.small)
            .tint(Theme.amber)
            .frame(width: 180)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tracks + stop

    private func tracks(_ s: CastState) -> some View {
        HStack(spacing: 8) {
            if audioOptionsCount(s) > 1 {
                VButton(audioLabel(s), icon: "waveform", kind: .ghost, compact: true) { showAudioMenu() }
            }
            if subtitleCount(s) > 0 {
                VButton(subtitleLabel(s), icon: "captions.bubble", kind: .ghost, compact: true) { showSubtitleMenu() }
            }
            VButton("Stop casting", icon: "rectangle.on.rectangle.slash", kind: .ghost, compact: true) {
                Task { _ = await AppServices.cast?.disconnect() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func audioOptionsCount(_ s: CastState) -> Int { s.link != nil ? s.linkAudio.count : (s.media?.audioOptions.count ?? 0) }
    private func subtitleCount(_ s: CastState) -> Int { s.link != nil ? s.linkSubtitles.count : (s.media?.subtitles.count ?? 0) }

    private func audioLabel(_ s: CastState) -> String {
        if s.link != nil { return s.linkAudio.first { $0.id == s.linkAudioSelected }?.label ?? "Audio" }
        return s.media?.audioOptions.first { $0.track == s.media?.audioTrack }?.label ?? "Audio"
    }

    private func subtitleLabel(_ s: CastState) -> String {
        if s.link != nil { return s.linkSubtitles.first { $0.id == s.linkSubtitleSelected }?.label ?? "Subtitles off" }
        return s.media?.subtitles.first { $0.id == s.activeSubtitle }?.label ?? "Subtitles off"
    }

    private func showAudioMenu() {
        guard let cast else { return }
        let s = cast.state
        var items: [PopupMenuItem] = []
        if s.link != nil {
            for t in s.linkAudio {
                let id = t.id
                items.append(PopupMenuItem(title: t.label, detail: t.detail, checked: t.id == s.linkAudioSelected) {
                    AppServices.cast?.selectLinkAudio(id)
                })
            }
        } else if let media = s.media {
            for o in media.audioOptions {
                let track = o.track
                items.append(PopupMenuItem(title: o.label, detail: o.detail, checked: o.track == media.audioTrack) {
                    Task { await AppServices.cast?.switchAudio(track) }
                })
            }
        }
        PopupMenu.show(items)
    }

    private func showSubtitleMenu() {
        guard let cast else { return }
        let s = cast.state
        var items: [PopupMenuItem] = []
        if s.link != nil {
            items.append(PopupMenuItem(title: "Off", detail: nil, checked: s.linkSubtitleSelected == nil) {
                AppServices.cast?.selectLinkSubtitle(nil)
            })
            for t in s.linkSubtitles {
                let id = t.id
                items.append(PopupMenuItem(title: t.label, detail: t.detail, checked: t.id == s.linkSubtitleSelected) {
                    AppServices.cast?.selectLinkSubtitle(id)
                })
            }
        } else if let media = s.media {
            items.append(PopupMenuItem(title: "Off", detail: nil, checked: s.activeSubtitle == nil) {
                AppServices.cast?.selectSubtitle(nil)
            })
            for sub in media.subtitles {
                let id = sub.id
                items.append(PopupMenuItem(title: sub.label, detail: nil, checked: sub.id == s.activeSubtitle) {
                    AppServices.cast?.selectSubtitle(id)
                })
            }
        }
        PopupMenu.show(items)
    }
}
