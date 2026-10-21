import Foundation
import VeltoretKit

/// Builds `CastMedia` for a file from the library: title and artwork from TMDB data, sidecar subtitles converted
/// to WebVTT, and the MKV audio tracks to choose from. Used when the player doesn't describe what it plays itself,
/// and for the next episode.
public final class CastMediaFactory: @unchecked Sendable {
    private let files: MediaFileDao
    private let catalog: CatalogDao
    private let openRead: CastServer.Opener
    private let preferredSubtitleLanguage: () -> String
    private let preferredAudioLanguage: () -> String

    public init(files: MediaFileDao, catalog: CatalogDao, openRead: @escaping CastServer.Opener,
                preferredSubtitleLanguage: @escaping () -> String, preferredAudioLanguage: @escaping () -> String) {
        self.files = files; self.catalog = catalog; self.openRead = openRead
        self.preferredSubtitleLanguage = preferredSubtitleLanguage; self.preferredAudioLanguage = preferredAudioLanguage
    }

    public func forFile(_ file: MediaFileEntity) async -> CastMedia {
        var media = describe(file)
        let subtitles = await self.subtitles(account: file.accountEmail, parentId: file.parentId, videoName: file.name)
        let preferred = preferredSubtitleLanguage()
        let active = preferred.isEmpty ? nil : subtitles.first {
            ($0.language ?? "").caseInsensitiveCompare(preferred) == .orderedSame
                || (LanguageNames.toTwoLetter($0.language) ?? "").caseInsensitiveCompare(preferred) == .orderedSame
        }?.id
        let audio = await self.audio(account: file.accountEmail, fileId: file.driveId, name: file.name)
        media.subtitles = subtitles
        media.activeSubtitle = active
        media.audioOptions = audio.options
        media.audioTrack = audio.selected
        media.audioWarning = CastFormats.audioWarning(audio.codec, file.name)
        media.audioLanguage = LanguageNames.toTwoLetter(audio.language)
        media.subtitleLanguage = active == nil ? LinkPlay.subtitlesOff : subtitles.first { $0.id == active }?.language
        return media
    }

    /// A file that isn't in the library (Files screen).
    public func forItem(account: String, fileId: String, name: String) async -> CastMedia {
        if let known = try? files.file(fileId) { return await forFile(known) }
        let audio = await self.audio(account: account, fileId: fileId, name: name)
        return CastMedia(fileId: fileId, account: account, fileName: name, title: (name as NSString).deletingPathExtension,
                         audioWarning: CastFormats.audioWarning(audio.codec, name), audioTrack: audio.selected,
                         audioOptions: audio.options, audioLanguage: LanguageNames.toTwoLetter(audio.language))
    }

    /// Title, subtitle and artwork only (no file reads).
    public func describe(_ file: MediaFileEntity) -> CastMedia {
        var media = CastMedia(fileId: file.driveId, account: file.accountEmail, file: file, fileName: file.name,
                              title: file.parsedTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? (file.name as NSString).deletingPathExtension : file.parsedTitle,
                              sizeBytes: file.sizeBytes > 0 ? file.sizeBytes : nil, durationMs: file.durationMs)
        if let movieId = file.movieId, let movie = try? catalog.movie(movieId) {
            media.title = movie.title
            media.subtitle = movie.year.map { String($0) }
            media.posterUrl = TmdbImages.poster(movie.posterPath, "w500")
            media.backdropUrl = TmdbImages.backdrop(movie.backdropPath, "w780")
            return media
        }
        if let showId = file.showId, let show = try? catalog.show(showId) {
            var ep: EpisodeEntity?
            var subtitle: String?
            if let s = file.season, let e = file.episode {
                ep = try? catalog.episode(showId, s, e)
                subtitle = String(format: "S%02dE%02d", s, e)
                if let name = ep?.name, !name.trimmingCharacters(in: .whitespaces).isEmpty { subtitle! += " · " + name }
            }
            media.title = show.name
            media.subtitle = subtitle
            media.isEpisode = true
            media.posterUrl = TmdbImages.poster(show.posterPath, "w500")
            media.backdropUrl = TmdbImages.still(ep?.stillPath, "w780") ?? TmdbImages.backdrop(show.backdropPath, "w780")
            return media
        }
        media.isEpisode = file.kind == .EPISODE
        return media
    }

    /// The episode after `file`'s (best copy: this Mac first, then highest resolution).
    public func nextEpisode(_ file: MediaFileEntity?) -> MediaFileEntity? {
        guard let file, let showId = file.showId, let season = file.season, let episode = file.episode else { return nil }
        let last = file.episodeEnd ?? episode
        guard let all = try? files.forShow(showId) else { return nil }
        let candidates = all.filter { f in
            guard let fs = f.season, let fe = f.episode, f.driveId != file.driveId else { return false }
            return season == 0 ? (fs == 0 && fe > last) : ((fs == season && fe > last) || (fs > season && fs != 0))
        }
        return candidates.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.season! != y.season! { return x.season! < y.season! }
            if x.episode! != y.episode! { return x.episode! < y.episode! }
            let lx = Accounts.isLocal(x.accountEmail), ly = Accounts.isLocal(y.accountEmail)
            if lx != ly { return lx }
            if x.height != y.height { return x.height > y.height }
            return a.offset < b.offset
        }.first?.element
    }

    /// Sidecar subtitles next to the video ("Movie.en.srt" for "Movie.mkv"), converted to WebVTT.
    public func subtitles(account: String, parentId: String, videoName: String, offsetUs: Int64 = 0) async -> [CastSubtitle] {
        var result: [CastSubtitle] = []
        if parentId.isEmpty { return result }
        guard let subs = try? files.subtitlesIn(parentId) else { return result }
        let stem = (videoName as NSString).deletingPathExtension.lowercased()
        for sub in subs where sub.accountEmail == account && (sub.name as NSString).lastPathComponent.lowercased().hasPrefix(stem) {
            if Task.isCancelled { break }
            do {
                let source = try await openRead(account, sub.driveId)
                defer { source.close() }
                let bytes = try await source.readAll(limit: 16 * 1024 * 1024)
                let cues = CastSubtitles.parse(CastSubtitles.decode(bytes), fileName: sub.name)
                if cues.isEmpty { continue }
                let language = CastSubtitles.languageFromName(sub.name)
                let label = language.map { LanguageNames.name($0) } ?? (sub.name as NSString).deletingPathExtension
                result.append(CastSubtitle(id: sub.driveId, label: label, language: LanguageNames.toTwoLetter(language),
                                           vtt: CastSubtitles.toVtt(cues, offsetUs: offsetUs)))
            } catch {
                continue
            }
        }
        return result
    }

    public struct AudioChoice: Sendable {
        public var options: [CastAudioOption]
        public var selected: Int64?
        public var codec: String?
        public var language: String?
    }

    /// The MKV audio tracks (2+), the one matching the preferred language (else the first), and its codec.
    public func audio(account: String, fileId: String, name: String) async -> AudioChoice {
        let none = AudioChoice(options: [], selected: nil, codec: nil, language: nil)
        if CastFormats.mimeFor(name) != "video/x-matroska" || name.lowercased().hasSuffix(".avi") { return none }
        let tracks: [CastAudio.Track]
        do {
            let source = try await openRead(account, fileId)
            defer { source.close() }
            tracks = await CastAudio.audioTracks(CastAudio.reader(source))
        } catch {
            return none
        }
        if tracks.isEmpty { return none }
        let single = tracks.count < 2
        var options: [CastAudioOption] = []
        for (i, t) in tracks.enumerated() {
            let codec = Self.codecName(t.codecId)
            let language = (t.language.map { !$0.isEmpty && $0 != "und" } ?? false) ? LanguageNames.name(t.language!) : nil
            let trackName = t.name?.trimmingCharacters(in: .whitespaces) ?? ""
            let label: String
            if !trackName.isEmpty, let language, t.name!.range(of: language, options: .caseInsensitive) == nil {
                label = "\(language) · \(t.name!)"
            } else if let n = t.name, !n.isEmpty {
                label = n
            } else {
                label = language ?? "Track \(i + 1)"
            }
            options.append(CastAudioOption(track: t.number, label: label, detail: codec ?? "", codec: codec))
        }
        func languageOf(_ o: CastAudioOption) -> String? { tracks.first { $0.number == o.track }?.language }
        let preferred = preferredAudioLanguage()
        let chosen = options.first { (LanguageNames.toTwoLetter(languageOf($0)) ?? "").caseInsensitiveCompare(preferred) == .orderedSame } ?? options[0]
        // With one audio track there's nothing to choose and nothing to hide.
        return single ? AudioChoice(options: [], selected: nil, codec: chosen.codec, language: languageOf(chosen))
            : AudioChoice(options: options, selected: chosen.track, codec: chosen.codec, language: languageOf(chosen))
    }

    public static func codecName(_ codecId: String?) -> String? {
        guard let c = codecId?.uppercased() else { return nil }
        if c.hasPrefix("A_DTS") { return "DTS" }
        switch c {
        case "A_TRUEHD", "A_MLP": return "TrueHD"
        case "A_AC3": return "AC3"
        case "A_EAC3": return "E-AC3"
        case "A_OPUS": return "Opus"
        case "A_FLAC": return "FLAC"
        case "A_VORBIS": return "Vorbis"
        case "A_MPEG/L3": return "MP3"
        case "A_MPEG/L2": return "MP2"
        default: break
        }
        if c.hasPrefix("A_AAC") { return "AAC" }
        if c.hasPrefix("A_PCM") { return "PCM" }
        return c.hasPrefix("A_") ? String(c.dropFirst(2)) : c
    }
}
