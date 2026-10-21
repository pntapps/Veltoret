import SwiftUI
import VeltoretKit
import VeltoretPlayerKit
import VeltoretUI

// MARK: - Player button styles (PlayerStyles.xaml: round chrome buttons, chips)

private let white10 = Color.white.opacity(0.10)
private let white18 = Color.white.opacity(0.18)
private let surfaceHigh85 = Theme.surfaceHigh.opacity(0.85)

/// Round chrome button: white 10 % fill (amber when accent), icon ~52 % of the size.
struct PlayerRoundStyle: ButtonStyle {
    var size: CGFloat = 44
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerRoundBody(configuration: configuration, size: size, accent: accent)
    }

    private struct PlayerRoundBody: View {
        let configuration: Configuration
        let size: CGFloat
        let accent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: size * (accent ? 0.36 : 0.4), weight: .semibold))
                .foregroundStyle(accent ? Theme.onAmber : Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(accent ? (hover ? Theme.amberSoft : Theme.amber) : (hover ? white18 : white10)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Chip: 40 high, radius 12, 18 pt icon; plain (white 10 %), accent (amber) or outline.
struct PlayerChipStyle: ButtonStyle {
    enum Kind { case plain, accent, outline }
    var kind: Kind = .plain
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        PlayerChipBody(configuration: configuration, kind: kind, height: height)
    }

    private struct PlayerChipBody: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @State private var hover = false

        var body: some View {
            let fill: Color = switch kind {
            case .accent: hover ? Theme.amberSoft : Theme.amber
            case .plain: hover ? white18 : white10
            case .outline: hover ? white10 : Color.clear
            }
            configuration.label
                .font(Theme.sans(13.5, .semibold))
                .foregroundStyle(kind == .accent ? Theme.onAmber : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(kind == .outline ? Theme.outlineStrong : Color.clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hover = $0 }
        }
    }
}

struct ChipLabel: View {
    let title: String
    let icon: String?
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
            Text(title).lineLimit(1)
        }
    }
}

// MARK: - Overlay

/// Everything drawn over the video: controls, prompts, HUD, panels, the mini player's controls.
struct PlayerOverlay: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        GeometryReader { geo in
            let c = controller
            let narrow = geo.size.width < 600
            ZStack {
                VideoGestureLayer(controller: c)

                if !c.isMini {
                    RippleView(controller: c, size: geo.size)

                    ChromeView(controller: c, narrow: narrow)
                        .opacity(c.chromeShown ? 1 : 0)
                        .allowsHitTesting(c.chromeShown)
                        .animation(.easeOut(duration: c.chromeShown ? 0.18 : 0.22), value: c.chromeShown)

                    if c.locked && c.controlsVisible {
                        HStack {
                            Button { c.unlock() } label: { Image(systemName: "lock.fill") }
                                .buttonStyle(PlayerRoundStyle(size: 52))
                                .help("Unlock")
                                .padding(.leading, 32)
                            Spacer()
                        }
                        .transition(.opacity)
                    }

                    if c.isLoading && !c.chromeShown {
                        VSpinner(size: 52, lineWidth: 3, color: Theme.amber).allowsHitTesting(false)
                    }
                    if let hint = c.loadingHint {
                        Text(hint)
                            .font(Theme.sans(14))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(surfaceHigh85))
                            .offset(y: 150)
                            .allowsHitTesting(false)
                    }

                    PromptsView(controller: c)
                    HudView(controller: c)

                    if let error = c.error {
                        ErrorCard(controller: c, message: error).padding(24)
                    }

                    if c.panelOpen, let content = c.panelContent {
                        PanelLayer(controller: c, content: content, width: min(400, max(280, geo.size.width * 0.9)))
                            .transition(.opacity)
                    }
                } else {
                    MiniControls(controller: c)
                    if c.isLoading { VSpinner(size: 32, lineWidth: 3, color: Theme.amber).allowsHitTesting(false) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .font(Theme.sans(14))
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

// MARK: - Chrome (scrim + top bar + transport + timeline)

private struct ChromeView: View {
    @ObservedObject var controller: PlayerController
    let narrow: Bool

    var body: some View {
        let c = controller
        ZStack {
            Theme.playerChrome.allowsHitTesting(false)
            VStack(spacing: 0) {
                TopBar(controller: c, narrow: narrow)
                Spacer(minLength: 0)
                Transport(controller: c, narrow: narrow)
                Spacer(minLength: 0)
                BottomBar(controller: c)
            }
        }
    }
}

private struct TopBar: View {
    @ObservedObject var controller: PlayerController
    let narrow: Bool

    var body: some View {
        let c = controller
        HStack(spacing: 8) {
            Button { c.host?.close() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(PlayerRoundStyle()).help("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(Theme.serif(19)).lineLimit(1).truncationMode(.tail)
                if let s = c.subtitle, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(s).font(Theme.sans(13)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            if let cast = PlayerHooks.castButton { cast() }
            if HdrProbe.isHdr(c.hdrFormat) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.tv").font(.system(size: 12, weight: .semibold))
                    Text(HdrProbe.label(c.hdrFormat)).font(Theme.sans(12, .semibold))
                }
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Capsule().fill(white10))
                .help("This video is \(HdrProbe.label(c.hdrFormat))")
            }
            if c.isEpisode {
                Button { c.openPanel(.episodes) } label: { Image(systemName: "list.bullet.rectangle") }
                    .buttonStyle(PlayerRoundStyle()).help("Episodes")
            }
            if !narrow {
                Button { c.host?.enterMini() } label: { Image(systemName: "pip.enter") }
                    .buttonStyle(PlayerRoundStyle()).help("Picture in picture")
            }
            Button { c.lock() } label: { Image(systemName: "lock.open") }
                .buttonStyle(PlayerRoundStyle()).help("Lock controls")
            Button { c.panel == .info ? c.closePanel() : c.openPanel(.info) } label: { Image(systemName: "info.circle") }
                .buttonStyle(PlayerRoundStyle()).help("Video info")
            Button { c.openPanel(.more) } label: { Image(systemName: "ellipsis") }
                .buttonStyle(PlayerRoundStyle()).help("More")
        }
        // Room for the traffic lights outside full screen.
        .padding(.leading, c.isFullscreen ? 16 : 80)
        .padding(.trailing, 16)
        .padding(.top, 14)
    }
}

private struct Transport: View {
    @ObservedObject var controller: PlayerController
    let narrow: Bool

    private func seekIcon(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    var body: some View {
        let c = controller
        let small: CGFloat = narrow ? 44 : 50
        let seekSize: CGFloat = narrow ? 50 : 58
        let playSize: CGFloat = narrow ? 68 : 78
        let seek = c.settings.seekSeconds
        HStack(spacing: narrow ? 18 : 32) {
            if c.previous != nil {
                Button { c.playPrevious() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(PlayerRoundStyle(size: small)).help("Previous episode")
            } else if c.next != nil {
                Color.clear.frame(width: small, height: small).allowsHitTesting(false)
            }
            Button { c.seekBy(-Int64(seek) * 1000); c.bumpInteraction() } label: { Image(systemName: seekIcon("gobackward", seek)) }
                .buttonStyle(PlayerRoundStyle(size: seekSize)).help("Back \(seek)s")
            Button { c.togglePlay(); c.bumpInteraction() } label: {
                ZStack {
                    if c.isLoading {
                        VSpinner(size: 34, lineWidth: 3, color: Theme.onAmber)
                    } else {
                        Image(systemName: c.ended ? "arrow.counterclockwise" : c.playWhenReady ? "pause.fill" : "play.fill")
                            .font(.system(size: playSize * 0.34, weight: .bold))
                    }
                }
            }
            .buttonStyle(PlayerRoundStyle(size: playSize, accent: true))
            .help(c.isLoading ? (c.playWhenReady ? "Loading, tap to pause" : "Loading") : c.playWhenReady ? "Pause" : "Play")
            Button { c.seekBy(Int64(seek) * 1000); c.bumpInteraction() } label: { Image(systemName: seekIcon("goforward", seek)) }
                .buttonStyle(PlayerRoundStyle(size: seekSize)).help("Forward \(seek)s")
            if c.next != nil {
                Button { c.playNext() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(PlayerRoundStyle(size: small)).help("Next episode")
            } else if c.previous != nil {
                Color.clear.frame(width: small, height: small).allowsHitTesting(false)
            }
        }
    }
}

private struct BottomBar: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        let c = controller
        let duration = c.durationMs
        let shown = c.shownPositionMs
        VStack(spacing: 2) {
            HStack {
                Spacer()
                if let ends = PlayerMath.endsAt(durationMs: duration, positionMs: shown, speed: c.speed) {
                    Text(PlayerFormat.endsAt(ends)).font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(height: 16)
            HStack(spacing: 12) {
                Text(PlayerFormat.clock(shown)).font(Theme.sans(13)).monospacedDigit()
                    .frame(minWidth: 56, alignment: .leading)
                SeekBar(controller: c, fraction: duration > 0 ? min(1, max(0, Double(shown) / Double(duration))) : 0)
                Text(duration > 0 ? "−" + PlayerFormat.clock(duration - shown) : "--:--").font(Theme.sans(13)).monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { c.openPanel(.audio) } label: { ChipLabel(title: "Audio", icon: "waveform") }
                            .buttonStyle(PlayerChipStyle())
                        Button { c.openPanel(.subtitles) } label: { ChipLabel(title: "Subtitles", icon: "captions.bubble") }
                            .buttonStyle(PlayerChipStyle())
                        Button { c.openPanel(.speed) } label: { ChipLabel(title: PlayerFormat.speedChip(c.speed), icon: "speedometer") }
                            .buttonStyle(PlayerChipStyle())
                        Button { c.cycleAspect(); c.bumpInteraction() } label: { ChipLabel(title: c.aspectChipText, icon: "aspectratio") }
                            .buttonStyle(PlayerChipStyle())
                        Button { c.host?.toggleFullscreen() } label: {
                            ChipLabel(title: c.isFullscreen ? "Exit full screen" : "Full screen",
                                      icon: c.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(PlayerChipStyle())
                        if c.isEpisode {
                            Button { c.skipIntro(); c.bumpInteraction() } label: {
                                ChipLabel(title: "+\(c.settings.skipSeconds)s", icon: "forward.fill")
                            }
                            .buttonStyle(PlayerChipStyle())
                        }
                    }
                }
                if c.next != nil {
                    Button { c.playNext() } label: { ChipLabel(title: "Next episode", icon: "forward.end.fill") }
                        .buttonStyle(PlayerChipStyle(kind: .accent))
                }
                Button { c.host?.close() } label: { ChipLabel(title: "Exit", icon: "xmark") }
                    .buttonStyle(PlayerChipStyle(kind: .outline)).help("Close the player")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

/// Click seeks; drag previews (the clock shows the scrub position) and seeks on release.
private struct SeekBar: View {
    @ObservedObject var controller: PlayerController
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let dragging = controller.scrubbing
            let thumb: CGFloat = dragging ? 22 : 16
            let track: CGFloat = dragging ? 6 : 4
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(white18).frame(height: track)
                RoundedRectangle(cornerRadius: 3).fill(Theme.amber).frame(width: w * fraction, height: track)
                Circle().fill(Theme.amber).frame(width: thumb, height: thumb)
                    .offset(x: min(max(0, w * fraction - thumb / 2), max(0, w - thumb)))
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in controller.scrub(to: Double(v.location.x / w)) }
                .onEnded { v in controller.finishScrub(at: Double(v.location.x / w)) })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 36)
    }
}

// MARK: - Ripple, HUD, prompts, error

private struct RippleView: View {
    @ObservedObject var controller: PlayerController
    let size: CGSize

    var body: some View {
        let r = controller.ripple
        let visible = controller.rippleVisible && r != nil
        HStack {
            if let r, visible, !r.forward { pill(r, leading: true) }
            Spacer()
            if let r, visible, r.forward { pill(r, leading: false) }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: visible)
    }

    private func pill(_ r: RippleState, leading: Bool) -> some View {
        let radius = size.height * 0.4
        let shape = leading
            ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius)
            : UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0)
        return VStack(spacing: 6) {
            Image(systemName: leading ? "backward.fill" : "forward.fill").font(.system(size: 30, weight: .semibold))
            Text("\(r.total) seconds").font(Theme.sans(14, .semibold))
        }
        .frame(width: size.width * 0.3, height: size.height * 0.8)
        .background(shape.fill(white10))
        .transition(.opacity)
    }
}

private struct HudView: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        VStack {
            if let hud = controller.hud {
                HStack(spacing: 10) {
                    Image(systemName: hud.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
                    Text(hud.text).font(Theme.sans(14, .semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(Theme.playerChrome))
                .padding(.top, 48)
                .transition(.opacity)
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: controller.hud?.text)
    }
}

private struct PromptsView: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        let c = controller
        let raised = c.chromeShown
        ZStack {
            if c.resumeVisible, let from = c.resumedFrom {
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 12) {
                            Text("Resumed at " + PlayerFormat.clock(from))
                            Button { c.startOver() } label: { ChipLabel(title: "Start over", icon: "arrow.counterclockwise") }
                                .buttonStyle(PlayerChipStyle(kind: .outline, height: 34))
                        }
                        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surfaceHigh85))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.outline))
                        Spacer()
                    }
                }
                .padding(.leading, 24).padding(.bottom, raised ? 132 : 28)
                .transition(.opacity)
            }
            if c.skipIntroVisible {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { c.skipIntro() } label: { ChipLabel(title: "Skip intro", icon: "forward.fill") }
                            .buttonStyle(PlayerChipStyle(kind: .accent, height: 44))
                    }
                }
                .padding(28)
                .transition(.opacity)
            }
            if c.upNextVisible {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpNextCard(controller: c)
                    }
                }
                .padding(.trailing, 24).padding(.bottom, raised ? 132 : 24)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: c.resumeVisible)
        .animation(.easeOut(duration: 0.2), value: c.skipIntroVisible)
        .animation(.easeOut(duration: 0.2), value: c.upNextVisible)
    }
}

private struct UpNextCard: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        let c = controller
        VStack(alignment: .leading, spacing: 0) {
            Text("UP NEXT").font(Theme.sans(11, .bold)).foregroundStyle(Theme.amber)
            Text(c.nextLabel ?? "").font(Theme.sans(15, .semibold)).lineLimit(2)
                .padding(.top, 6).padding(.bottom, 12)
            HStack(spacing: 8) {
                if c.settings.autoPlayNext {
                    Button { c.playNext() } label: {
                        ChipLabel(title: "Play in \(max(0, c.durationMs - c.positionMs) / 1000)s", icon: "play.fill")
                    }
                    .buttonStyle(PlayerChipStyle(kind: .accent))
                    Button { c.autoPlayCancelled = true; c.changed() } label: { ChipLabel(title: "Cancel", icon: "pause.fill") }
                        .buttonStyle(PlayerChipStyle(kind: .outline))
                } else {
                    Button { c.playNext() } label: { ChipLabel(title: "Play now", icon: "play.fill") }
                        .buttonStyle(PlayerChipStyle(kind: .accent))
                }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceHigh))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.outline))
    }
}

private struct ErrorCard: View {
    @ObservedObject var controller: PlayerController
    let message: String

    var body: some View {
        let c = controller
        VStack(alignment: .leading, spacing: 0) {
            Text("Playback stopped").font(Theme.serif(22))
            Text(message).font(Theme.sans(14)).foregroundStyle(Theme.textMuted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                Button { c.host?.close() } label: { ChipLabel(title: "Close", icon: "chevron.left") }
                    .buttonStyle(PlayerChipStyle(kind: .outline))
                if !c.software {
                    Button { c.setSoftwareDecoding(true) } label: { ChipLabel(title: "Try software", icon: nil) }
                        .buttonStyle(PlayerChipStyle(kind: .outline))
                }
                Button { c.retry() } label: { ChipLabel(title: "Retry", icon: "play.fill") }
                    .buttonStyle(PlayerChipStyle(kind: .accent))
            }
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surfaceHigh))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.outline))
    }
}

// MARK: - Mini player

private struct MiniControls: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        let c = controller
        let visible = c.miniControlsVisible
        GeometryReader { geo in
            ZStack {
                Theme.playerChrome.allowsHitTesting(false)
                VStack {
                    HStack(spacing: 6) {
                        Spacer()
                        Button { c.host?.exitMini() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(PlayerRoundStyle(size: 32)).help("Expand")
                        Button { c.host?.close() } label: { Image(systemName: "xmark") }
                            .buttonStyle(PlayerRoundStyle(size: 32)).help("Close")
                    }
                    .padding(6)
                    Spacer()
                }
                HStack(spacing: 16) {
                    Button { c.seekBy(-10_000) } label: { Image(systemName: "gobackward.10") }
                        .buttonStyle(PlayerRoundStyle()).help("Back 10 seconds")
                    Button { c.togglePlay() } label: {
                        Image(systemName: c.playWhenReady ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(PlayerRoundStyle(size: 52, accent: true)).help(c.playWhenReady ? "Pause" : "Play")
                    Button { c.seekBy(10_000) } label: { Image(systemName: "goforward.10") }
                        .buttonStyle(PlayerRoundStyle()).help("Forward 10 seconds")
                }
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.amber)
                            .frame(width: geo.size.width * (c.durationMs > 0 ? min(1, Double(c.positionMs) / Double(c.durationMs)) : 0),
                                   height: 3)
                        Spacer(minLength: 0)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: visible ? 0.18 : 0.22), value: visible)
    }
}
