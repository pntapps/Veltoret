import Foundation

/// Creates and holds every repository, API and service (Android: AppContainer, Windows: AppServices). Manual DI.
///
/// The foundation (database, DAOs, settings, storage, secrets) is created here by `initFoundation()`. Each module
/// declares its own services as static properties in an `extension AppServices` inside its own target, and exposes
/// `<Module>Module.initialize()` / `start()` / `shutdown()`; the app target calls them in this order:
/// foundation → Core → Drive → Smb → Player → Plans → Cast → UI, then start() after the main window shows.
public enum AppServices {
    public static var db: VeltoretDb!
    public static var accountDao: AccountDao!
    public static var mediaFileDao: MediaFileDao!
    public static var catalogDao: CatalogDao!
    public static var plansDao: PlansDao!
    public static var watchDao: WatchDao!
    public static var settings: SettingsStore!
    public static var storage: Storage!
    public static var secrets: SecretStoring!

    /// Starts the player for movies, episodes or files. Set by the player module.
    public static var playback: PlaybackLauncher!

    /// Shows a page in the main window (set by the shell; brings the window to the front). Main actor.
    public static var navigate: @MainActor (Route) -> Void = { _ in }

    /// Shows an in-app toast/snackbar (set by the UI module). Safe from any thread.
    public static var toast: (String) -> Void = { Log.info("toast: \($0)") }

    public static func initFoundation(secrets: SecretStoring = KeychainSecretStore()) throws {
        AppPaths.ensure(AppPaths.root)
        db = try VeltoretDb(path: AppPaths.database)
        accountDao = AccountDao(db)
        mediaFileDao = MediaFileDao(db)
        catalogDao = CatalogDao(db)
        plansDao = PlansDao(db)
        watchDao = WatchDao(db)
        settings = SettingsStore(url: AppPaths.settings)
        storage = Storage()
        self.secrets = secrets
    }

    /// Tests: an in-memory database, temp settings and in-memory secrets.
    public static func initForTests() throws {
        AppPaths.root = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-tests-\(UUID().uuidString)")
        AppPaths.ensure(AppPaths.root)
        db = try VeltoretDb()
        accountDao = AccountDao(db)
        mediaFileDao = MediaFileDao(db)
        catalogDao = CatalogDao(db)
        plansDao = PlansDao(db)
        watchDao = WatchDao(db)
        settings = SettingsStore(url: AppPaths.settings)
        storage = Storage()
        secrets = MemorySecretStore()
    }
}

/// Pages of the main window (Android: ui/navigation/Navigation.kt). One back stack; top-level destinations reset it.
public enum Route: Hashable, Sendable {
    case home
    case movies(genre: String? = nil)
    case shows(genre: String? = nil)
    case search(query: String? = nil, spoken: Bool = false)
    case files(account: String? = nil, folderId: String? = nil)
    case settings
    case movieDetail(movieId: Int)
    case showDetail(showId: Int, season: Int? = nil)
    case collection(collectionId: Int)
    /// No file ids: the "Needs a match" list. With file ids: the Fix match screen for them; `kind` is "MOVIE" or
    /// "EPISODE" (default: the files' kind) and `query` the initial search (default: parsed title).
    case fixMatch(fileIds: [String]? = nil, kind: String? = nil, query: String? = nil)
    case archives
    case onboarding

    public var isTopLevel: Bool {
        switch self {
        case .home, .movies, .shows, .search, .files, .settings: return true
        default: return false
        }
    }
}

/// What "Play" buttons call (Home, details, Search, Files, reminders). Implemented by the player module, which
/// resolves the best copy (device first; offline only local copies), the resume position and the episode list.
public protocol PlaybackLauncher: AnyObject {
    /// Plays the best copy of a movie. `startOver` ignores saved progress.
    func playMovie(_ movieId: Int, startOver: Bool) async
    /// Plays what "Play" on a show means: the next episode (PlayTargets), or episode 1 once all are watched.
    func playShow(_ showId: Int) async
    func playEpisode(showId: Int, season: Int, episode: Int, startOver: Bool) async
    /// Plays one specific file (Files screen, "Versions", unmatched files).
    func playFile(_ file: MediaFileEntity, startOver: Bool) async
    /// Plays any file from a source by id, even if it isn't in the library (Files screen).
    func playItem(account: String, fileId: String, name: String) async
}
