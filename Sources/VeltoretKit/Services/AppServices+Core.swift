import Foundation

// [core] module services: TMDB, library scanner and repositories, connectivity, image cache, "This Mac" file source.
// Created by CoreModule.initialize() (after the foundation).
extension AppServices {
    public static var tmdb: TmdbRepository!
    public static var scanner: LibraryScanner!
    public static var library: LibraryRepository!
    public static var watch: WatchRepository!
    public static var resolver: PlaybackResolver!
    public static var connectivity: Connectivity!
    public static var images: ImageCache!
    public static var scans: ScanScheduler!
    public static var artwork: ArtworkPrefetch!
    /// "This Mac" (also reachable as `storage.sourceFor(Accounts.device)`).
    public static var localFiles: LocalFileSource!
}
