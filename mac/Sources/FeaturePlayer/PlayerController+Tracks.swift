import AppKit
import Foundation
import UniformTypeIdentifiers
import VLCKit
import VeltoretKit
import VeltoretPlayerKit

extension PlayerController {
    // ---------------------------------------------------------------------------------------------
    // Track lists
    // ---------------------------------------------------------------------------------------------

    /// `VLCMedia.tracksInformation` entries of one type (audio / video / text).
    func trackInfos(_ type: String) -> [[String: Any]] {
        guard let media else { return [] }
        let all = media.tracksInformation as? [[String: Any]] ?? []
        return all.filter { ($0[VLCMediaTracksInformationType] as? String) == type }
    }

    private func buildTracks(ids: [Any], names: [Any], type: String, include: ((Int) -> Bool)? = nil) -> [TrackItem] {
        let meta = trackInfos(type)
        var list: [TrackItem] = []
        for (i, raw) in ids.enumerated() {
            guard let id = (raw as? NSNumber)?.intValue, id != -1, include?(id) ?? true else { continue }
            let name = i < names.count ? (names[i] as? String ?? "") : ""
            if let m = meta.first(where: { ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == id }) {
                let codec = (m[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0
                let isAudio = type == VLCMediaTracksInformationTypeAudio
                list.append(TrackItem(
                    id: id, ordinal: list.count,
                    language: MediaFormats.normalizeLanguage(m[VLCMediaTracksInformationLanguage] as? String),
                    label: (m[VLCMediaTracksInformationDescription] as? String) ?? (name.isEmpty ? nil : name),
                    fourCC: codec != 0 ? MediaFormats.fourCC(codec) : nil,
                    channels: isAudio ? (m[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0 : 0,
                    rate: isAudio ? (m[VLCMediaTracksInformationAudioRate] as? NSNumber)?.intValue ?? 0 : 0,
                    name: name))
            } else {
                list.append(TrackItem(id: id, ordinal: list.count, language: nil, label: name.isEmpty ? nil : name,
                                      fourCC: nil, channels: 0, rate: 0, name: name))
            }
        }
        return list
    }

    func audioTracks() -> [TrackItem] {
        guard media != nil else { return [] }
        return buildTracks(ids: player.audioTrackIndexes, names: player.audioTrackNames, type: VLCMediaTracksInformationTypeAudio)
    }

    /// Text tracks in the video (subtitle files Veltoret added are listed separately).
    func embeddedSubtitleTracks() -> [TrackItem] {
        guard media != nil else { return [] }
        let slaves = slaveSpuIds
        return buildTracks(ids: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames,
                           type: VLCMediaTracksInformationTypeText, include: { !slaves.contains($0) })
    }

    private func pick(_ tracks: [TrackItem], _ ordinal: Int?, _ language: String?) -> TrackItem? {
        let lang = MediaFormats.normalizeLanguage(language)
        if let o = ordinal, o >= 0, o < tracks.count, lang == nil || tracks[o].language == lang { return tracks[o] }
        guard let lang else { return nil }
        return tracks.first { $0.language == lang }
    }

    var currentSpu: Int { Int(player.currentVideoSubTitleIndex) }
    var currentAudio: Int { Int(player.currentAudioTrackIndex) }

    var embeddedSubtitleSelected: Bool {
        selectedExternal == nil && currentSpu != -1 && !slaveSpuIds.contains(currentSpu)
    }

    // ---------------------------------------------------------------------------------------------
    // Restoring choices once the tracks are known (once per video)
    // ---------------------------------------------------------------------------------------------

    func applyTracksOnce() {
        tracksApplied = true
        let memory = restore
        restore = nil

        let audio = audioTracks()
        var a = memory.flatMap { pick(audio, $0.audioIndex, $0.audioLanguage) }
        if a == nil, let wanted = wantedAudio { a = audio.first { $0.language == wanted } }
        if let a, currentAudio != a.id { player.currentAudioTrackIndex = Int32(a.id) }

        let subs = embeddedSubtitleTracks()
        switch memory?.subtitleMode {
        case TrackMemory.subOff?:
            subtitlesOffKeepForced(subs)
        case TrackMemory.subEmbedded?:
            if let chosen = pick(subs, memory?.subtitleIndex, memory?.subtitleLanguage) { setSpu(chosen.id) }
            else { subtitlesOffKeepForced(subs) }
        case TrackMemory.subExternal?:
            subtitlesOffKeepForced(subs)
            if let source = memory?.externalSource {
                let name = memory?.externalName ?? "Subtitles"
                Task { @MainActor [weak self] in await self?.restoreExternal(source, name) }
            }
        default:
            let wanted = wantedSubtitle
            let match: TrackItem? = wanted == nil || wanted == PlayerPrefsStore.off ? nil
                : subs.first { $0.language == wanted && !$0.forced } ?? subs.first { $0.language == wanted }
            if let match { setSpu(match.id) } else { subtitlesOffKeepForced(subs) }
        }
        applyPendingSubtitleChoice()
        changed()
    }

    func setSpu(_ id: Int) {
        player.currentVideoSubTitleIndex = Int32(id)
        player.currentVideoSubTitleDelay = 0
    }

    /// "Off" means off: the file's default subtitle track is ignored, but forced subtitles (signs, foreign-language
    /// lines) in the audio's language still show. libVLC 3 has no forced flag, so a track titled "Forced" counts.
    func subtitlesOffKeepForced(_ subs: [TrackItem]) {
        let audioLanguage = audioTracks().first { $0.id == currentAudio }?.language
        let forced = subs.first { $0.forced && ($0.language == nil || audioLanguage == nil || $0.language == audioLanguage) }
        player.currentVideoSubTitleIndex = Int32(forced?.id ?? -1)
    }

    /// The preferred subtitle language isn't in the video but a sidecar file has it: use the file.
    func applyPendingSubtitleChoice() {
        guard let wanted = autoSubtitlePending, tracksApplied else { return }
        if embeddedSubtitleSelected {
            autoSubtitlePending = nil
            return
        }
        if let ext = externals.first(where: { $0.language == wanted }) {
            autoSubtitlePending = nil
            selectExternal(ext.id, remember: false)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // User choices (remembered)
    // ---------------------------------------------------------------------------------------------

    func selectAudio(_ track: TrackItem) {
        player.currentAudioTrackIndex = Int32(track.id)
        if isEpisode { prefs.setAudioLanguage(showId, track.language) }
        prefs.updateTrackMemory(fileId) { m in m.with { $0.audioIndex = track.ordinal; $0.audioLanguage = track.language } }
        changed()
    }

    func selectEmbeddedSubtitle(_ track: TrackItem) {
        selectedExternal = nil
        autoSubtitlePending = nil
        setSpu(track.id)
        if let language = track.language { prefs.setSubtitleLanguage(showId, language) }
        prefs.updateTrackMemory(fileId) { m in
            m.with {
                $0.subtitleMode = TrackMemory.subEmbedded
                $0.subtitleIndex = track.ordinal
                $0.subtitleLanguage = track.language
                $0.externalSource = nil
                $0.externalName = nil
            }
        }
        changed()
    }

    func disableSubtitles() {
        autoSubtitlePending = nil
        selectedExternal = nil
        player.currentVideoSubTitleIndex = -1
        prefs.setSubtitleLanguage(showId, nil)
        prefs.updateTrackMemory(fileId) { m in
            m.with { $0.subtitleMode = TrackMemory.subOff; $0.externalSource = nil; $0.externalName = nil }
        }
        changed()
    }

    func selectExternal(_ id: String, remember: Bool = true) {
        guard let sub = externals.first(where: { $0.id == id }) else { return }
        selectedExternal = id
        if let spu = sub.spuId {
            player.currentVideoSubTitleIndex = Int32(spu)
            player.currentVideoSubTitleDelay = Int(subtitleOffsetMs * 1000)
        } else if pendingSlave == nil {
            addSlave(sub)
        } else {
            queuedSlave = sub
        }
        if remember {
            if let language = sub.language { prefs.setSubtitleLanguage(showId, language) }
            prefs.updateTrackMemory(fileId) { m in
                m.with {
                    $0.subtitleMode = TrackMemory.subExternal
                    $0.externalSource = id
                    $0.externalName = sub.label
                    $0.subtitleIndex = nil
                }
            }
        }
        changed()
    }

    private func addSlave(_ sub: ExternalSub) {
        spuBeforeSlave = Set((player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue))
        pendingSlave = sub
        pendingSlaveSince = Date()
        player.addPlaybackSlave(sub.path, type: .subtitle, enforce: true)
    }

    /// Finds the SPU id libVLC gave a subtitle file just added.
    func pollSlaves() {
        guard let pending = pendingSlave else { return }
        let ids = (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue)
        if let fresh = ids.first(where: { $0 != -1 && !spuBeforeSlave.contains($0) && !slaveSpuIds.contains($0) }) {
            pending.spuId = fresh
            slaveSpuIds.insert(fresh)
            pendingSlave = nil
            if selectedExternal == pending.id {
                player.currentVideoSubTitleIndex = Int32(fresh)
                player.currentVideoSubTitleDelay = Int(subtitleOffsetMs * 1000)
            } else if selectedExternal == nil && !embeddedSubtitleSelected {
                player.currentVideoSubTitleIndex = -1
            }
            if let q = queuedSlave {
                queuedSlave = nil
                if q.spuId == nil && selectedExternal == q.id { addSlave(q) }
            }
            refreshPanelIfOpen()
        } else if Date().timeIntervalSince(pendingSlaveSince) > 8 {
            pendingSlave = nil
        }
    }

    func setSubtitleOffset(_ ms: Int64) {
        subtitleOffsetMs = ms
        if selectedExternal != nil { player.currentVideoSubTitleDelay = Int(ms * 1000) }
        prefs.updateTrackMemory(fileId) { m in m.with { $0.subtitleOffsetMs = ms } }
        changed()
    }

    // ---------------------------------------------------------------------------------------------
    // Loading files
    // ---------------------------------------------------------------------------------------------

    func resetExternals() {
        externals.removeAll()
        slaveSpuIds.removeAll()
        selectedExternal = nil
        pendingSlave = nil
        queuedSlave = nil
        subtitleError = nil
        subtitleBusy = false
    }

    private func writeTemp(_ bytes: Data, name: String) throws -> URL {
        let dir = AppPaths.ensure(AppPaths.temp.appendingPathComponent("subtitles", isDirectory: true))
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty || !Sidecars.isSubtitle(name) { ext = "srt" }
        let url = dir.appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "") + "." + ext)
        try SubtitleEngine.toUtf8WithBom(bytes).write(to: url)
        tempFiles.append(url)
        return url
    }

    func cleanupTempSubtitles() {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles.removeAll()
    }

    /// Reads a subtitle file (8 MiB limit) from This Mac by path, or from any source.
    static func readSubtitleBytes(account: String, id: String) async throws -> Data {
        if Accounts.isLocal(account) {
            let attrs = try FileManager.default.attributesOfItem(atPath: id)
            if let size = attrs[.size] as? NSNumber, size.int64Value > Int64(SubtitleEngine.maxBytes) {
                throw SubtitleError(SubtitleEngine.tooLarge)
            }
            return try await Task.detached { try Data(contentsOf: URL(fileURLWithPath: id)) }.value
        }
        return try await SubtitleEngine.readLimited(account: account, id: id)
    }

    /// Parses in the background and writes the UTF-8 copy; nil when the file has no cues.
    private func prepareSubtitle(_ bytes: Data, name: String) async throws -> URL? {
        let cues = try await Task.detached { try SubtitleEngine.parse(bytes, fileName: name) }.value
        return cues.isEmpty ? nil : try writeTemp(bytes, name: name)
    }

    private func addExternal(_ sub: ExternalSub, select: Bool, remember: Bool) {
        externals.removeAll { $0.id == sub.id }
        externals.append(sub)
        if select { selectExternal(sub.id, remember: remember) }
        refreshPanelIfOpen()
    }

    /// Subtitle files beside the video with the same base name (library index, plus the folder on disk for This Mac).
    func loadSidecars(_ generation: Int) async {
        guard let account else { return }
        let local = Accounts.isLocal(account)
        guard let videoName = file?.name ?? (local ? (fileId as NSString).lastPathComponent : nil) else { return }

        struct Candidate { let account: String; let id: String; let name: String }
        var candidates: [Candidate] = []
        if let file, !file.parentId.isEmpty {
            do {
                candidates += try AppServices.mediaFileDao.subtitlesIn(file.parentId)
                    .map { Candidate(account: $0.accountEmail, id: $0.driveId, name: $0.name) }
            } catch { Log.error(error, "sidecars") }
        }
        if local {
            let dir = (fileId as NSString).deletingLastPathComponent
            if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                candidates += names.map { Candidate(account: Accounts.device, id: (dir as NSString).appendingPathComponent($0), name: $0) }
            }
        }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id.lowercased()).inserted }
        for match in Sidecars.match(videoName, unique, name: { $0.name }) {
            guard isCurrentGeneration(generation) else { return }
            do {
                let bytes = try await Self.readSubtitleBytes(account: match.file.account, id: match.file.id)
                guard let path = try await prepareSubtitle(bytes, name: match.name) else { continue }
                guard isCurrentGeneration(generation) else { return }
                let language = MediaFormats.normalizeLanguage(match.language)
                let label = match.language.flatMap { MediaFormats.languageName($0) } ?? match.name
                addExternal(ExternalSub(id: "side:" + match.file.id, label: label, language: language, path: path),
                            select: false, remember: false)
            } catch {
                // Files that fail to read or parse are skipped.
            }
        }
        applyPendingSubtitleChoice()
    }

    /// Reloads a previously chosen file ("drive:…", "file:…" or a sidecar "side:…").
    func restoreExternal(_ source: String, _ name: String) async {
        if externals.contains(where: { $0.id == source }) {
            selectExternal(source, remember: false)
            return
        }
        guard let account else { return }
        let id = fileId
        do {
            var bytes: Data?
            if source.hasPrefix("drive:") || source.hasPrefix("side:") {
                let sub = String(source[source.index(after: source.firstIndex(of: ":")!)...])
                let fromDisk = Accounts.isLocal(account) || FileManager.default.fileExists(atPath: sub)
                bytes = try await Self.readSubtitleBytes(account: fromDisk ? Accounts.device : account, id: sub)
            } else if source.hasPrefix("file:") {
                bytes = try await Self.readSubtitleBytes(account: Accounts.device, id: String(source.dropFirst(5)))
            }
            guard let bytes, id == fileId else { return }
            guard let path = try await prepareSubtitle(bytes, name: name), id == fileId else { return }
            addExternal(ExternalSub(id: source, label: name, language: nil, path: path), select: true, remember: false)
        } catch {}
    }

    /// Adds a subtitle file the user picked. Returns an error message, or nil on success.
    func addUserSubtitle(source: String, name: String, read: () async throws -> Data) async -> String? {
        do {
            let bytes = try await read()
            guard let path = try await prepareSubtitle(bytes, name: name) else { return "No subtitles found in \(name)" }
            addExternal(ExternalSub(id: source, label: name, language: nil, path: path), select: true, remember: true)
            return nil
        } catch let e as SubtitleError {
            return e.message
        } catch let e as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission].contains(e.code) {
            return "Couldn't open the file"
        } catch {
            let m = PlayerErrors.message(error).trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "Couldn't read \(name)" : m
        }
    }

    /// Subtitle files in the video's folder, for "From the video's folder".
    func folderSubtitleCandidates() async throws -> [StorageItem] {
        guard let account else { return [] }
        var parent = file?.parentId ?? ""
        if parent.isEmpty {
            if Accounts.isLocal(account) { parent = (fileId as NSString).deletingLastPathComponent }
            else if Accounts.isSmb(account), let slash = fileId.lastIndex(of: "/"),
                    fileId.distance(from: fileId.startIndex, to: slash) > "smb://".count {
                parent = String(fileId[..<slash])
            }
        }
        if parent.isEmpty { return [] }
        let items = try await AppServices.storage.list(account, folderId: parent)
        return items.filter { !$0.isFolder && Sidecars.isSubtitle($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // ---------------------------------------------------------------------------------------------
    // Panel actions for files
    // ---------------------------------------------------------------------------------------------

    /// "Choose a file…": an open panel over the player (any file; the parser decides).
    func chooseSubtitleFile() {
        guard let window = host?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a subtitle file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Sidecars.subtitleExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]
        if let account, Accounts.isLocal(account) {
            panel.directoryURL = URL(fileURLWithPath: (fileId as NSString).deletingLastPathComponent, isDirectory: true)
        }
        bumpInteraction()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                let path = url.path
                var name = url.lastPathComponent
                if name.isEmpty { name = "subtitle.srt" }
                self.subtitleBusy = true
                self.subtitleError = nil
                self.refreshPanelIfOpen()
                Task { @MainActor in
                    let error = await self.addUserSubtitle(source: "file:" + path, name: name) {
                        try await Self.readSubtitleBytes(account: Accounts.device, id: path)
                    }
                    self.subtitleBusy = false
                    self.subtitleError = error
                    if error == nil { self.closePanel() } else { self.refreshPanelIfOpen() }
                }
            }
        }
    }

    func loadFolderSubtitles() {
        folderSubtitles = nil
        folderLoading = true
        subtitleError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { self.folderSubtitles = try await self.folderSubtitleCandidates() }
            catch {
                self.folderSubtitles = []
                let m = PlayerErrors.message(error).trimmingCharacters(in: .whitespacesAndNewlines)
                self.subtitleError = m.isEmpty ? "Couldn't open the file" : m
            }
            self.folderLoading = false
            if self.panel == .folderSubtitles { self.refreshPanel() }
        }
    }

    func addFolderSubtitle(_ item: StorageItem) {
        guard let account else { return }
        subtitleBusy = true
        subtitleError = nil
        refreshPanelIfOpen()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let error = await self.addUserSubtitle(source: "drive:" + item.id, name: item.name) {
                try await Self.readSubtitleBytes(account: account, id: item.id)
            }
            self.subtitleBusy = false
            self.subtitleError = error
            if error == nil { self.closePanel() } else { self.refreshPanelIfOpen() }
        }
    }

    func loadEpisodes(_ version: Int) {
        guard let showId else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let online = AppServices.connectivity?.isOnline ?? true
                let files = try AppServices.mediaFileDao.forShow(showId).filter { online || Accounts.isLocal($0.accountEmail) }
                let list = EpisodeNav.episodeList(files)
                var meta: [String: EpisodeEntity] = [:]
                for e in try AppServices.catalogDao.episodes(showId) { meta["\(e.seasonNumber):\(e.episodeNumber)"] = e }
                var states: [String: WatchStateEntity] = [:]
                for s in try AppServices.watchDao.forShow(showId) { states[s.key] = s }
                guard version == self.panelVersion, self.panel == .episodes else { return }
                self.episodeRows = list.compactMap { f in
                    guard let season = f.season, let episode = f.episode else { return nil }
                    let m = meta["\(season):\(episode)"]
                    let watched = states[WatchKeys.episode(showId, season, episode)]?.watched == true
                    let name = (m?.name ?? "").trimmingCharacters(in: .whitespaces)
                    return EpisodeRowItem(fileId: f.driveId, account: f.accountEmail, season: season, episode: episode,
                                          name: name.isEmpty ? "Episode \(episode)" : name,
                                          stillUrl: TmdbImages.still(m?.stillPath), watched: watched,
                                          isCurrent: f.driveId == self.fileId)
                }
                self.refreshPanel()
            } catch {
                Log.error(error, "episodes panel")
            }
        }
    }
}
