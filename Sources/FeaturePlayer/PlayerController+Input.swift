import AppKit
import Foundation
import VeltoretKit
import VeltoretPlayerKit

private enum KeyCode {
    static let space: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let home: UInt16 = 115
}

extension PlayerController {
    // ---------------------------------------------------------------------------------------------
    // Keyboard
    // ---------------------------------------------------------------------------------------------

    /// The player's shortcuts (Windows notes): returns true when the key was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if closing { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = mods.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode
        keyRepeat = event.isARepeat ? keyRepeat + 1 : 0

        if code == KeyCode.escape {
            if panelOpen { closePanel() }
            else if isMini { host?.exitMini() }
            else if isFullscreen { host?.toggleFullscreen() }
            else if !locked { host?.close() }
            return true
        }
        if locked {
            // While locked only the unlock shortcut works (a key press shows the Unlock button).
            if command && chars == "l" { unlock() }
            else if !command {
                controlsVisible = true
                host?.chromeVisibilityChanged()
                bumpInteraction()
                changed()
            } else { return false }
            return true
        }
        if command {
            if chars == "l" { lock(); return true }
            return false // other ⌘ shortcuts belong to the menus
        }
        if mods.contains(.control) || mods.contains(.option) { return false }

        let seekStep = settings.seekSeconds * (keyRepeat > 20 ? 6 : keyRepeat > 6 ? 3 : 1)
        var handled = true
        switch code {
        case KeyCode.space:
            togglePlay()
            if !playWhenReady { showControls() }
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if panelOpen { handled = false } else {
                togglePlay()
                if !playWhenReady { showControls() }
            }
        case KeyCode.left: seekWithRipple(false, seekStep)
        case KeyCode.right: seekWithRipple(true, seekStep)
        case KeyCode.up: changeVolume(5)
        case KeyCode.down: changeVolume(-5)
        case KeyCode.home: startOver()
        case KeyCode.tab:
            if isEpisode && PlayerMath.skipIntroVisible(isEpisode, introSkipped, false, false, positionMs) { skipIntro() }
            else { handled = false }
        default:
            switch chars {
            case "k":
                togglePlay()
                if !playWhenReady { showControls() }
            case "j": seekWithRipple(false, seekStep)
            case "l": seekWithRipple(true, seekStep)
            case "m": toggleMute()
            case "n": playNext()
            case "p": playPrevious()
            case "f": host?.toggleFullscreen()
            case "[":
                setSpeed(PlayerMath.stepSpeed(speed, -1))
                showHud(PlayerFormat.speedOption(speed), "speedometer")
            case "]":
                setSpeed(PlayerMath.stepSpeed(speed, 1))
                showHud(PlayerFormat.speedOption(speed), "speedometer")
            case "s", "c", "v": cycleSubtitles()
            case "a": cycleAudio()
            case "g": nudgeSync(-100)
            case "h": nudgeSync(100)
            case "z":
                cycleAspect()
                showHud(resize, "aspectratio")
            case "i":
                if panel == .info { closePanel() } else { openPanel(.info) }
            default:
                handled = false
            }
        }
        if handled { bumpInteraction() }
        return handled
    }

    func handleKeyUp(_ event: NSEvent) {
        if !event.isARepeat { keyRepeat = 0 }
    }

    /// Seek with the double-click style feedback; same direction within 1.2 s adds up ("30 seconds").
    func seekWithRipple(_ forward: Bool, _ stepSeconds: Int) {
        let now = Date()
        let since = ripple.map { Int64(now.timeIntervalSince($0.at) * 1000) } ?? Int64.max
        let total = PlayerMath.accumulateSeek(ripple?.total, ripple?.forward == forward, since, stepSeconds)
        ripple = RippleState(forward: forward, total: total, at: now)
        seekBy(Int64(forward ? 1 : -1) * Int64(stepSeconds) * 1000)
        if isMini { return }
        rippleVisible = true
        rippleTimer.start()
        changed()
    }

    func cycleAudio() {
        let tracks = audioTracks()
        if tracks.isEmpty {
            showHud("No audio tracks", "waveform")
            return
        }
        let titles = MediaFormats.trackTitles(tracks.map { (language: $0.language, label: $0.label) }, fallback: "Track")
        let i = tracks.firstIndex { $0.id == currentAudio } ?? -1
        let next = (i + 1) % tracks.count
        selectAudio(tracks[next])
        showHud("Audio: " + titles[next], "waveform")
        refreshPanelIfOpen()
    }

    func cycleSubtitles() {
        let embedded = embeddedSubtitleTracks()
        let titles = MediaFormats.trackTitles(embedded.map { (language: $0.language, label: $0.label) }, fallback: "Subtitle")
        // Off, then the video's tracks, then files.
        var options: [(title: String, select: () -> Void, current: Bool)] = [("Off", { [weak self] in self?.disableSubtitles() }, false)]
        let spu = currentSpu
        for (n, t) in embedded.enumerated() {
            options.append((titles[n], { [weak self] in self?.selectEmbeddedSubtitle(t) }, selectedExternal == nil && t.id == spu))
        }
        for x in externals {
            let id = x.id
            options.append((x.label, { [weak self] in self?.selectExternal(id) }, selectedExternal == id))
        }
        let current = options.firstIndex { $0.current } ?? 0
        let next = options[(current + 1) % options.count]
        next.select()
        showHud(next.title == "Off" ? "Subtitles off" : "Subtitles: " + next.title, "captions.bubble")
        refreshPanelIfOpen()
    }

    func nudgeSync(_ delta: Int64) {
        guard selectedExternal != nil else {
            showHud("Sync works with subtitle files", "captions.bubble")
            return
        }
        setSubtitleOffset(subtitleOffsetMs + delta)
        showHud("Sync: " + PlayerFormat.syncLabel(subtitleOffsetMs), "captions.bubble")
        refreshPanelIfOpen()
    }

    // ---------------------------------------------------------------------------------------------
    // Seek bar: click seeks, drag previews and seeks on release
    // ---------------------------------------------------------------------------------------------

    func scrub(to fraction: Double) {
        guard durationMs > 0 else { return }
        if !scrubbing {
            scrubbing = true
            bumpInteraction()
        }
        scrubFraction = min(1, max(0, fraction))
        changed()
    }

    func finishScrub(at fraction: Double) {
        guard scrubbing else { return }
        scrubFraction = min(1, max(0, fraction))
        scrubbing = false
        let duration = durationMs
        if duration > 0 { seekTo(Int64(scrubFraction * Double(duration))) }
        bumpInteraction()
        changed()
    }

    // ---------------------------------------------------------------------------------------------
    // Mouse on the video (VideoGestureView)
    // ---------------------------------------------------------------------------------------------

    func mouseMovedInWindow() {
        if isMini {
            miniControlsVisible = true
            bumpInteraction()
            changed()
            return
        }
        showControls()
    }

    func videoMouseDown(x: CGFloat, width: CGFloat, clickCount: Int) {
        pressOnVideo = true
        panning = false
        if clickCount == 1 {
            if !locked && playWhenReady && player.isPlaying { holdTimer.start() }
            return
        }
        // Double-click (and each further click): left third back, right third forward, middle full screen.
        clickTimer.stop()
        holdTimer.stop()
        if locked { return }
        let third = width / 3
        if x < third { seekWithRipple(false, settings.seekSeconds) }
        else if x > 2 * third { seekWithRipple(true, settings.seekSeconds) }
        else if clickCount == 2 { host?.toggleFullscreen() }
        pressOnVideo = false
    }

    /// `moved` = distance since the press; `dx/dy` = this drag step (points, y down).
    func videoMouseDragged(moved: CGFloat, dx: CGFloat, dy: CGFloat, size: CGSize) {
        guard pressOnVideo else { return }
        if !panning && moved > 6 {
            holdTimer.stop()
            if zoom > 1.001 && !locked { panning = true }
        }
        guard panning else { return }
        panX = PlayerMath.pan(panX, delta: Double(dx), size: Double(max(1, size.width)), zoom: zoom)
        panY = PlayerMath.pan(panY, delta: Double(dy), size: Double(max(1, size.height)), zoom: zoom)
        applyAspect()
    }

    func videoMouseUp() {
        holdTimer.stop()
        if holding {
            endHold()
            pressOnVideo = false
            return
        }
        if panning {
            panning = false
            pressOnVideo = false
            return
        }
        if pressOnVideo && !isMini {
            // Wait for a possible double-click before toggling the controls.
            clickTimer.start()
        }
        pressOnVideo = false
    }

    func startHold() {
        guard !locked, pressOnVideo, !panning, player.isPlaying else { return }
        holding = true
        speedBeforeHold = speed
        player.rate = 2
        showHud("2× speed", "forward.fill", sticky: true)
    }

    func endHold() {
        holding = false
        setSpeed(abs(speedBeforeHold - 2) < 0.001 ? 1 : speedBeforeHold)
        hideHud()
    }

    /// Wheel / trackpad scroll: volume ±5 per notch; ⌘-scroll zooms.
    func videoScroll(notches: Double, command: Bool) {
        if command {
            if locked || isMini { return }
            setZoom(PlayerMath.wheelZoom(zoom, notches: notches))
        } else {
            let step = Int((5 * notches).rounded())
            if step != 0 { changeVolume(step) }
        }
        bumpInteraction()
    }

    /// Trackpad pinch: zoom 1–5×.
    func videoMagnify(_ magnification: CGFloat) {
        if locked || isMini { return }
        setZoom(zoom * (1 + Double(magnification)))
        bumpInteraction()
    }
}
