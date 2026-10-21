import AppKit
import Foundation
import UserNotifications
import VeltoretKit
import VeltoretPlans
import VeltoretUI

/// Reminder ("Time for …", Play / Snooze 1 hour) and new-episode notifications through UserNotifications (Windows
/// ToastNotifier, Android PlanNotifications), and what happens when one is clicked. Artwork comes from the image
/// cache (8 s limit, skipped on failure) and is copied to a temp file first, because UserNotifications moves
/// attachment files into its own store.
///
/// Set as `AppServices.plans.notifier` (and `upcoming.notifier`) by `FeatureSettingsModule.initialize()`; also the
/// `UNUserNotificationCenter` delegate.
public final class MacNotifier: NSObject, PlanNotifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = MacNotifier()

    /// A reminder whose title can't be played: only "Snooze 1 hour".
    static let reminderSnoozeOnlyCategory = "reminder-snooze"

    private let lock = NSLock()
    private var _status: UNAuthorizationStatus?

    /// Fires (on the main thread) when the authorization status may have changed.
    public let statusChanged = Event<UNAuthorizationStatus>()

    /// UserNotifications needs a real app bundle (`swift run` / tests have none and would crash).
    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? { Self.isSupported ? UNUserNotificationCenter.current() : nil }

    override private init() { super.init() }

    // MARK: Setup and permission

    /// Delegate + categories. Call early (before the app finishes launching) so a click that launched the app arrives.
    public func install() {
        guard let center else { return }
        center.delegate = self
        let play = UNNotificationAction(identifier: PlanNotificationIds.playAction, title: PlanNotificationIds.playTitle,
                                        options: [.foreground])
        let snooze = UNNotificationAction(identifier: PlanNotificationIds.snoozeAction,
                                          title: PlanNotificationIds.snoozeTitle, options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: PlanNotificationIds.reminderCategory, actions: [play, snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.reminderSnoozeOnlyCategory, actions: [snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PlanNotificationIds.newEpisodeCategory, actions: [],
                                   intentIdentifiers: [], options: []),
        ])
        refreshStatus()
    }

    /// The last known authorization status (nil until the first check finished).
    public var status: UNAuthorizationStatus? {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    /// Re-reads the authorization status (app activation, Settings appearing).
    public func refreshStatus(_ done: (@Sendable (UNAuthorizationStatus) -> Void)? = nil) {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            self?.setStatus(settings.authorizationStatus)
            done?(settings.authorizationStatus)
        }
    }

    private func setStatus(_ s: UNAuthorizationStatus) {
        lock.lock()
        let old = _status
        _status = s
        lock.unlock()
        if old != s {
            DispatchQueue.main.async { self.statusChanged.fire(s) }
            // Reminders kept while notifications were off can appear now.
            if Self.allows(s), old != nil, !Self.allows(old!) { VeltoretPlansModule.restoreReminders() }
        }
    }

    static func allows(_ s: UNAuthorizationStatus) -> Bool { s == .authorized || s == .provisional }

    /// Asks macOS for permission (alerts + sound) the first time; returns whether Veltoret may post.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.error(error, "Notification permission")
        }
        let s = await center.notificationSettings().authorizationStatus
        setStatus(s)
        return Self.allows(s)
    }

    // MARK: PlanNotifier

    /// False when notifications are off for Veltoret (then reminders stay pending and Settings warns).
    public var canPostNow: Bool {
        guard Self.isSupported else { return false }
        if let s = status { return Self.allows(s) }
        // First call before the async check finished: ask synchronously off the main thread.
        guard !Thread.isMainThread, let center else { return false }
        let sem = DispatchSemaphore(value: 0)
        var result: UNAuthorizationStatus = .notDetermined
        center.getNotificationSettings { settings in
            result = settings.authorizationStatus
            sem.signal()
        }
        if sem.wait(timeout: .now() + 3) == .timedOut { return false }
        setStatus(result)
        return Self.allows(result)
    }

    public func showReminder(_ r: ReminderEntity) async throws {
        guard let center else { return }
        let catalog = AppServices.catalogDao!
        let movie = r.mediaType == Plans.movie ? try? catalog.movie(r.mediaId) : nil
        let show = r.mediaType == Plans.tv ? try? catalog.show(r.mediaId) : nil
        var season = r.season, episode = r.episode
        var playable = false
        let title: String
        var text: String
        var picture: String?, poster: String?

        if let movie {
            title = "Time for \(movie.title)"
            text = [movie.year.map(String.init), movie.genreList.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                    PlanFormat.runtime(movie.runtimeMin)].compactMap { $0 }.joined(separator: " · ")
            picture = TmdbImages.backdrop(movie.backdropPath, "w780")
            poster = TmdbImages.poster(movie.posterPath)
            playable = (try? AppServices.resolver?.movieFile(movie.tmdbId)) != nil
        } else if let show, let s = season, let e = episode {
            let ep = try? catalog.episode(show.tmdbId, s, e)
            title = "Time for \(show.name)"
            text = [PlanFormat.episodeCode(s, e), ep?.name].compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "  ·  ")
            picture = TmdbImages.still(ep?.stillPath, "w780") ?? TmdbImages.backdrop(show.backdropPath, "w780")
            poster = TmdbImages.poster(show.posterPath)
            playable = (try? AppServices.resolver?.episodeFile(showId: show.tmdbId, season: s, episode: e)) != nil
        } else if let show {
            // A show reminder plays what "Play" on its page would: the next episode.
            let target = (try? AppServices.resolver?.showPlayTarget(show.tmdbId)) ?? nil
            season = target?.file.season
            episode = target?.file.episode
            var ep: EpisodeEntity?
            if let s = season, let e = episode { ep = try? catalog.episode(show.tmdbId, s, e) }
            title = "Time for \(show.name)"
            if let target {
                text = [target.resuming ? "Continue" : "Up next", PlanFormat.episodeCode(season, episode), ep?.name]
                    .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "  ·  ")
            } else {
                text = "Your reminder"
            }
            picture = TmdbImages.still(ep?.stillPath, "w780") ?? TmdbImages.backdrop(show.backdropPath, "w780")
            poster = TmdbImages.poster(show.posterPath)
            playable = target != nil
        } else {
            // The title left the library since the reminder was set.
            title = "Time for \(r.title)"
            text = "Your reminder"
        }
        if text.isEmpty { text = "Your reminder" }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "Reminder"
        content.body = text
        content.sound = .default
        content.threadIdentifier = "reminders"
        let canPlay = playable && (movie != nil || show != nil)
        content.categoryIdentifier = canPlay ? PlanNotificationIds.reminderCategory : Self.reminderSnoozeOnlyCategory
        // Each action carries its own complete arguments: the body opens the page; Play plays the resolved episode;
        // Snooze re-creates this reminder (the row was deleted when it fired).
        var info = OpenTarget(mediaType: r.mediaType, mediaId: r.mediaId, season: r.season, episode: r.episode).userInfo
        info["title"] = r.title
        if let season { info["playSeason"] = season }
        if let episode { info["playEpisode"] = episode }
        if let s = r.season { info["snoozeSeason"] = s }
        if let e = r.episode { info["snoozeEpisode"] = e }
        content.userInfo = info
        if let a = await attachment(picture ?? poster, id: "r\(r.id)") { content.attachments = [a] }
        try await center.add(UNNotificationRequest(identifier: "r\(r.id)", content: content, trigger: nil))
    }

    public func showNewEpisode(_ show: ShowEntity) async throws {
        guard let center, canPostNow else { return }
        let code = PlanFormat.episodeCode(show.nextEpisodeSeason, show.nextEpisodeNumber)
        let text = [code.isEmpty ? nil : code, show.nextEpisodeName.map { "“\($0)”" }, "out today"]
            .compactMap { $0 }.joined(separator: "  ·  ")
        let content = UNMutableNotificationContent()
        content.title = "New episode of \(show.name)"
        content.subtitle = show.network ?? "New episode"
        content.body = text
        content.sound = .default
        content.threadIdentifier = "new-episodes"
        content.categoryIdentifier = PlanNotificationIds.newEpisodeCategory
        content.userInfo = OpenTarget(mediaType: Plans.tv, mediaId: show.tmdbId).userInfo
        let picture = TmdbImages.backdrop(show.backdropPath, "w780") ?? TmdbImages.poster(show.posterPath)
        if let a = await attachment(picture, id: "e\(show.tmdbId)") { content.attachments = [a] }
        try await center.add(UNNotificationRequest(identifier: "e\(show.tmdbId)", content: content, trigger: nil))
    }

    // MARK: Artwork

    /// The cached image (8 s limit), copied to a temp file that UserNotifications may move away.
    private func attachment(_ url: String?, id: String) async -> UNNotificationAttachment? {
        guard let url, let images = AppServices.images else { return nil }
        let file: URL? = await withTaskGroup(of: URL?.self) { group in
            group.addTask { await images.file(for: url) }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-notifications", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = Self.imageExtension(file)
            let copy = dir.appendingPathComponent("\(id)-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: file, to: copy)
            return try UNNotificationAttachment(identifier: id, url: copy, options: nil)
        } catch {
            Log.error(error, "Notification artwork")
            return nil
        }
    }

    /// Cache files are named by hash without an extension; UserNotifications needs one to know the type.
    private static func imageExtension(_ file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "jpg" }
        defer { try? h.close() }
        let head = [UInt8](h.readData(ofLength: 12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.count >= 12, head[0...3] == [0x52, 0x49, 0x46, 0x46], head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let info = request.content.userInfo
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        defer { completionHandler() }
        guard let open = OpenTarget(userInfo: info), open.mediaId >= 0 else { return }

        switch response.actionIdentifier {
        case PlanNotificationIds.snoozeAction:
            let title = info["title"] as? String ?? ""
            let season = info["snoozeSeason"] as? Int, episode = info["snoozeEpisode"] as? Int
            do {
                _ = try AppServices.plans.snooze(type: open.mediaType, id: open.mediaId, season: season, episode: episode,
                                                 title: title)
            } catch {
                Log.error(error, "Snoozing a reminder")
            }
        case PlanNotificationIds.playAction:
            let target = OpenTarget(mediaType: open.mediaType, mediaId: open.mediaId,
                                    season: info["playSeason"] as? Int ?? open.season,
                                    episode: info["playEpisode"] as? Int ?? open.episode, play: true)
            DispatchQueue.main.async { OpenRequests.open(target) }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            let target = OpenTarget(mediaType: open.mediaType, mediaId: open.mediaId, season: open.season,
                                    episode: open.episode, play: false)
            DispatchQueue.main.async { OpenRequests.open(target) }
        }
    }
}
