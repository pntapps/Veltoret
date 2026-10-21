import Foundation

/// Progress of the running (or last) library scan. A value type; the scanner replaces it on every change.
public struct ScanState: Hashable, Sendable {
    public var running = false
    public var phase = ""
    public var filesFound = 0
    public var toMatch = 0
    /// Files looked up on TMDB so far in this scan (found or not).
    public var matched = 0
    public var error: String?
    public var lastFinishedAt: Int64 = 0
    /// Library folders this scan covers; nil means the whole library.
    public var folderIds: Set<Int64>?
    public var foldersTotal = 0
    public var foldersDone = 0
    /// Folders this scan has finished reading.
    public var doneFolderIds: Set<Int64> = []
    public var currentFolderId: Int64?
    public var currentFolder = ""
    /// Sub-folder being read, relative to the library folder ("Breaking Bad/Season 2").
    public var currentPath = ""
    public var newFiles = 0
    /// Files TMDB identified in this scan.
    public var identified = 0
    public var cancelled = false
    /// Why a folder couldn't be read in its latest scan, by folder id. Kept until that folder scans cleanly.
    public var folderErrors: [Int64: String] = [:]

    public init() {}

    public func covers(_ folderId: Int64) -> Bool { running && (folderIds == nil || folderIds!.contains(folderId)) }

    /// Part of the running scan but not read yet.
    public func waiting(_ folderId: Int64) -> Bool {
        covers(folderId) && folderId != currentFolderId && !doneFolderIds.contains(folderId)
    }

    /// Progress of the current step from 0 to 1, or nil when it can't be measured yet.
    public var progress: Float? {
        if !running { return nil }
        if toMatch > 0 { return Float(matched) / Float(toMatch) }
        if foldersTotal > 1 { return Float(foldersDone) / Float(foldersTotal) }
        return nil
    }
}

/// What the scanner needs from TMDB (implemented by `TmdbRepository` in core-data; tests use a fake).
/// Methods return TMDB ids so this file doesn't depend on the TMDB model types.
public protocol TmdbMatching: AnyObject {
    /// `TmdbRepository.findMovie(title:year:exactOnly:)?.id`.
    func matchMovie(title: String, year: Int?, exactOnly: Bool) async throws -> Int?
    /// `TmdbRepository.findShow(title:year:exactOnly:)?.id`.
    func matchShow(title: String, year: Int?, exactOnly: Bool) async throws -> Int?
    /// `TmdbRepository.ensureMovie(_:)`.
    func fetchMovie(_ id: Int) async throws
    /// `TmdbRepository.ensureShow(_:seasons:)`.
    func fetchShow(_ id: Int, seasons: Set<Int>) async throws
    /// `TmdbRepository.ensureRecommendations(type:id:)`.
    func fetchRecommendations(type: String, id: Int) async throws
    /// True for errors that must stop the scan (a missing TMDB key) instead of skipping one title.
    func isFatal(_ error: Error) -> Bool
}

public extension TmdbMatching {
    func isFatal(_ error: Error) -> Bool { false }
}

/// What the scanner and scheduler need from `Connectivity` (core-data's `Connectivity` conforms; tests use a fake).
public protocol ScanConnectivity: AnyObject {
    var isOnline: Bool { get }
    var onlineChanged: Event<Bool> { get }
}
