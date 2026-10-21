import Foundation
import VLCKit
import VeltoretKit
import VeltoretPlayerKit

/// One line of a side panel. Built by `refreshPanel()` (so the 100 ms clock doesn't ask libVLC for tracks every frame).
enum PanelRow: Identifiable {
    case row(id: String, title: String, detail: String?, icon: String?, check: Bool, enabled: Bool, action: () -> Void)
    case note(id: String, text: String, danger: Bool)
    case header(id: String, text: String)
    case busy(id: String)
    case divider(id: String)
    case sync(id: String, label: String)
    case info(id: String, key: String, value: String)
    case softwareToggle(id: String, on: Bool)
    case episode(EpisodeRowItem)

    var id: String {
        switch self {
        case .row(let id, _, _, _, _, _, _), .note(let id, _, _), .header(let id, _), .busy(let id), .divider(let id),
             .sync(let id, _), .info(let id, _, _), .softwareToggle(let id, _):
            return id
        case .episode(let e): return "ep:" + e.fileId
        }
    }
}

/// What the side panel shows.
struct PanelContent {
    var title: String
    var showsBack: Bool
    var rows: [PanelRow]
    /// Episodes panel: the row to scroll to.
    var scrollTo: String?
}

extension PlayerController {
    func openPanel(_ kind: PanelKind) {
        if isMini { return }
        panel = kind
        panelVersion += 1
        if kind == .folderSubtitles { loadFolderSubtitles() }
        if kind == .episodes {
            episodeRows = nil
            loadEpisodes(panelVersion)
        }
        refreshPanel()
        bumpInteraction()
    }

    func closePanel() {
        guard panelOpen else { return }
        panel = .none
        panelContent = nil
        subtitleError = nil
        bumpInteraction()
        changed()
    }

    func refreshPanelIfOpen() {
        if panelOpen { refreshPanel() }
    }

    func panelBack() {
        openPanel(panel == .folderSubtitles ? .subtitles : .more)
    }

    func refreshPanel() {
        switch panel {
        case .none: panelContent = nil
        case .more: panelContent = buildMore()
        case .sleep: panelContent = buildSleep()
        case .speed: panelContent = buildSpeed()
        case .audio: panelContent = buildAudio()
        case .subtitles: panelContent = buildSubtitles()
        case .folderSubtitles: panelContent = buildFolderSubtitles()
        case .info: panelContent = buildInfo()
        case .episodes: panelContent = buildEpisodes()
        }
        changed()
    }

    // ---- More, Sleep, Speed -------------------------------------------------------------------

    private func buildMore() -> PanelContent {
        PanelContent(title: "More", showsBack: false, rows: [
            .row(id: "sleep", title: "Sleep timer", detail: PlayerFormat.sleepDetail(sleepEndsAt, sleepEndOfVideo),
                 icon: "moon.zzz", check: false, enabled: true, action: { [weak self] in self?.openPanel(.sleep) }),
            .row(id: "info", title: "Video info & decoder", detail: software ? "Software decoding" : "Hardware decoding",
                 icon: "cpu", check: false, enabled: true, action: { [weak self] in self?.openPanel(.info) }),
            .row(id: "mini", title: "Picture in picture", detail: nil, icon: "pip.enter", check: false, enabled: true,
                 action: { [weak self] in self?.closePanel(); self?.host?.enterMini() }),
        ])
    }

    private func buildSleep() -> PanelContent {
        let none = sleepEndsAt == nil && !sleepEndOfVideo
        var rows: [PanelRow] = [
            .row(id: "off", title: "Off", detail: nil, icon: nil, check: none, enabled: true,
                 action: { [weak self] in self?.setSleepTimer(nil); self?.closePanel() }),
        ]
        for m in [15, 30, 45, 60, 90] {
            rows.append(.row(id: "m\(m)", title: "\(m) minutes", detail: nil, icon: nil, check: false, enabled: true,
                             action: { [weak self] in self?.setSleepTimer(m); self?.closePanel() }))
        }
        rows.append(.row(id: "end", title: "End of this video", detail: nil, icon: nil, check: sleepEndOfVideo, enabled: true,
                         action: { [weak self] in self?.setSleepAtEndOfVideo(); self?.closePanel() }))
        return PanelContent(title: "Sleep timer", showsBack: true, rows: rows)
    }

    private func buildSpeed() -> PanelContent {
        var rows: [PanelRow] = [.note(id: "tip", text: "Tip: press and hold the video for 2× speed.", danger: false)]
        for s in PlayerMath.speeds {
            rows.append(.row(id: "s\(s)", title: PlayerFormat.speedOption(s), detail: nil, icon: nil,
                             check: abs(s - speed) < 0.001, enabled: true,
                             action: { [weak self] in self?.setSpeed(s); self?.closePanel() }))
        }
        return PanelContent(title: "Playback speed", showsBack: false, rows: rows)
    }

    // ---- Audio ----------------------------------------------------------------------------------

    private func buildAudio() -> PanelContent {
        let tracks = audioTracks()
        if tracks.isEmpty {
            return PanelContent(title: "Audio", showsBack: false, rows: [.note(id: "none", text: "No audio tracks", danger: false)])
        }
        let titles = MediaFormats.trackTitles(tracks.map { (language: $0.language, label: $0.label) }, fallback: "Track")
        let selected = currentAudio
        var rows: [PanelRow] = []
        for (i, t) in tracks.enumerated() {
            let label = MediaFormats.cleanLabel(t.label)
            let detail = [label != nil && label != MediaFormats.languageName(t.language) ? label : nil,
                          MediaFormats.audioCodec(t.fourCC), MediaFormats.channels(t.channels)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            rows.append(.row(id: "a\(t.id)", title: titles[i], detail: detail.isEmpty ? nil : detail, icon: nil,
                             check: t.id == selected, enabled: true,
                             action: { [weak self] in self?.selectAudio(t); self?.closePanel() }))
        }
        return PanelContent(title: "Audio", showsBack: false, rows: rows)
    }

    // ---- Subtitles ------------------------------------------------------------------------------

    private func buildSubtitles() -> PanelContent {
        let embedded = embeddedSubtitleTracks()
        let spu = currentSpu
        let noneSelected = selectedExternal == nil && !embedded.contains { $0.id == spu }
        var rows: [PanelRow] = [
            .row(id: "off", title: "Off", detail: nil, icon: nil, check: noneSelected, enabled: true,
                 action: { [weak self] in self?.disableSubtitles(); self?.closePanel() }),
        ]
        let titles = MediaFormats.trackTitles(embedded.map { (language: $0.language, label: $0.label) }, fallback: "Subtitle")
        for (i, t) in embedded.enumerated() {
            let label = MediaFormats.cleanLabel(t.label)
            var parts: [String] = []
            for p in [label != nil && label != MediaFormats.languageName(t.language) ? label : nil,
                      t.forced ? "Forced" : nil, MediaFormats.subtitleFormat(t.fourCC), "In video"] {
                if let p, !p.isEmpty, !parts.contains(p) { parts.append(p) }
            }
            rows.append(.row(id: "e\(t.id)", title: titles[i], detail: parts.joined(separator: " · "), icon: nil,
                             check: selectedExternal == nil && t.id == spu, enabled: true,
                             action: { [weak self] in self?.selectEmbeddedSubtitle(t); self?.closePanel() }))
        }
        for x in externals {
            let languageName = MediaFormats.languageName(x.language)
            let detail = [languageName != nil && languageName != x.label ? languageName : nil, "File"]
                .compactMap { $0 }.joined(separator: " · ")
            let id = x.id
            // Choosing a file keeps the panel open so the sync can be adjusted.
            rows.append(.row(id: "x" + id, title: x.label, detail: detail, icon: nil, check: selectedExternal == id,
                             enabled: true, action: { [weak self] in self?.selectExternal(id); self?.refreshPanel() }))
        }
        if selectedExternal != nil { rows.append(.sync(id: "sync", label: PlayerFormat.syncLabel(subtitleOffsetMs))) }
        if subtitleBusy { rows.append(.busy(id: "busy")) }
        if let subtitleError { rows.append(.note(id: "err", text: subtitleError, danger: true)) }
        rows.append(.divider(id: "div"))
        rows.append(.row(id: "folder", title: "From the video's folder", detail: nil, icon: "folder", check: false, enabled: true,
                         action: { [weak self] in self?.openPanel(.folderSubtitles) }))
        rows.append(.row(id: "choose", title: "Choose a file…", detail: nil, icon: "desktopcomputer", check: false,
                         enabled: !subtitleBusy, action: { [weak self] in self?.chooseSubtitleFile() }))
        return PanelContent(title: "Subtitles", showsBack: false, rows: rows)
    }

    private func buildFolderSubtitles() -> PanelContent {
        var rows: [PanelRow] = []
        if folderLoading || subtitleBusy { rows.append(.busy(id: "busy")) }
        if !folderLoading, let list = folderSubtitles, list.isEmpty {
            rows.append(.note(id: "empty",
                              text: "No .srt, .vtt or .ass files next to this video. Put one next to the video, or use “Choose a file…”.",
                              danger: false))
        }
        for item in folderSubtitles ?? [] {
            rows.append(.row(id: "f" + item.id, title: item.name, detail: PlayerFormat.bytes(item.sizeBytes), icon: nil,
                             check: false, enabled: !subtitleBusy,
                             action: { [weak self] in self?.addFolderSubtitle(item) }))
        }
        if let subtitleError { rows.append(.note(id: "err", text: subtitleError, danger: true)) }
        return PanelContent(title: "Subtitles in this folder", showsBack: true, rows: rows)
    }

    // ---- Episodes -----------------------------------------------------------------------------

    private func buildEpisodes() -> PanelContent {
        guard let list = episodeRows else {
            return PanelContent(title: "Episodes", showsBack: false, rows: [.busy(id: "busy")])
        }
        return PanelContent(title: "Episodes", showsBack: false, rows: list.map { .episode($0) },
                            scrollTo: list.first { $0.isCurrent }.map { "ep:" + $0.fileId })
    }

    func playEpisodeRow(_ item: EpisodeRowItem) {
        closePanel()
        open(PlayerArgs(fileId: item.fileId, account: item.account, fromStart: item.watched))
    }

    // ---- Video info ---------------------------------------------------------------------------

    private func buildInfo() -> PanelContent {
        var rows: [PanelRow] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            rows.append(.info(id: "i\(rows.count)", key: key, value: value))
        }
        let local = account.map(Accounts.isLocal) == true
        let name = file?.name ?? (local ? (fileId as NSString).lastPathComponent : title)
        var size = file?.sizeBytes ?? 0
        if size <= 0 && local { size = (try? FileManager.default.attributesOfItem(atPath: fileId)[.size] as? NSNumber)?.int64Value ?? 0 }
        if size <= 0 { size = streamLength }
        rows.append(.header(id: "hfile", text: "FILE"))
        add("Name", name)
        add("Size", PlayerFormat.bytes(size))
        add("Container", (name as NSString).pathExtension.uppercased())

        let decoder = software ? "Software" : "Hardware (VideoToolbox)"
        let videoId = Int(player.currentVideoTrackIndex)
        let videos = trackInfos(VLCMediaTracksInformationTypeVideo)
        let video = videos.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == videoId } ?? videos.first
        let audios = trackInfos(VLCMediaTracksInformationTypeAudio)
        let audio = audios.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == currentAudio } ?? audios.first
        let stats: VLCMedia.Stats? = media?.statistics
        if let v = video {
            let codecValue = (v[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0
            let codec = MediaFormats.videoCodec(MediaFormats.fourCC(codecValue))
            rows.append(.header(id: "hvideo", text: "VIDEO"))
            add("Codec", codec)
            var w = (v[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
            var h = (v[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
            if w <= 0 || h <= 0 { (w, h) = videoSize() }
            add("Resolution", MediaFormats.resolution(w, h))
            let num = (v[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
            let den = (v[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
            add("Frame rate", MediaFormats.frameRate(den > 0 ? num / den : 0))
            add("HDR", codec == "Dolby Vision" ? "Dolby Vision" : HdrProbe.label(hdrFormat))
            let trackBitrate = (v[VLCMediaTracksInformationBitrate] as? NSNumber)?.int64Value ?? 0
            let bitrate = trackBitrate > 0 ? trackBitrate : Int64(Double(stats?.inputBitrate ?? 0) * 8_000_000)
            add("Bitrate", MediaFormats.bitrate(bitrate))
            add("Decoder", decoder)
            add("Dropped frames", String(stats?.lostPictures ?? 0))
        }
        if let a = audio {
            let codecValue = (a[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0
            rows.append(.header(id: "haudio", text: "AUDIO"))
            add("Codec", MediaFormats.audioCodec(MediaFormats.fourCC(codecValue)))
            add("Channels", MediaFormats.channels((a[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0))
            add("Sample rate", MediaFormats.sampleRate((a[VLCMediaTracksInformationAudioRate] as? NSNumber)?.intValue ?? 0))
            add("Language", MediaFormats.languageName(MediaFormats.normalizeLanguage(a[VLCMediaTracksInformationLanguage] as? String)))
            add("Decoder", "Software")
        }
        rows.append(.softwareToggle(id: "sw", on: software))
        return PanelContent(title: "Video info", showsBack: true, rows: rows)
    }
}
