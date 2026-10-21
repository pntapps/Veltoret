import Foundation

/// Core module entry points: TMDB, library scanner, repositories, local file source, images, connectivity
/// (Windows AppServices.Core.cs InitCore / StartCore).
public enum CoreModule {
    /// Creates every core service. Call after `AppServices.initFoundation()` (or `initForTests()`).
    public static func initialize() {
        let connectivity = Connectivity()
        AppServices.connectivity = connectivity
        let settings = AppServices.settings!
        let tmdbClient = TmdbClient(keyProvider: { settings.current.tmdbKey })
        AppServices.tmdb = TmdbRepository(api: tmdbClient, catalog: AppServices.catalogDao)
        let images = ImageCache(directory: AppPaths.imageCache)
        AppServices.images = images
        AppServices.watch = WatchRepository(AppServices.watchDao)
        AppServices.resolver = PlaybackResolver(files: AppServices.mediaFileDao, watch: AppServices.watchDao,
                                                isOnline: { connectivity.isOnline })
        AppServices.library = LibraryRepository(catalog: AppServices.catalogDao, files: AppServices.mediaFileDao,
                                                accounts: AppServices.accountDao, connectivity: connectivity)
        let local = LocalFileSource()
        AppServices.localFiles = local
        AppServices.storage.register(local)
        AppServices.scanner = LibraryScanner(accounts: AppServices.accountDao, files: AppServices.mediaFileDao,
                                             catalog: AppServices.catalogDao, storage: AppServices.storage,
                                             tmdb: AppServices.tmdb, settings: settings, connectivity: connectivity)
        AppServices.artwork = ArtworkPrefetch(catalog: AppServices.catalogDao, prefetch: { await images.prefetch($0) })
        AppServices.scans = ScanScheduler(scanner: AppServices.scanner, connectivity: connectivity, settings: settings,
                                          prefetch: AppServices.artwork)
    }

    /// Starts connectivity monitoring and the scan scheduler (call once the main window shows).
    public static func start() {
        AppServices.connectivity.start()
        AppServices.scans.start()
    }

    public static func shutdown() {
        AppServices.scans?.stop()
        AppServices.connectivity?.stop()
    }
}
