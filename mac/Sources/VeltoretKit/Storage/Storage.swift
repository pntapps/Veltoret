import Foundation

/// One file or folder from any source (the Android app's DriveFile). `id` is a Drive file id, a local path, or
/// smb://host/share/path.
public struct StorageItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var isFolder: Bool
    public var sizeBytes: Int64
    /// RFC 3339, as Drive sends it.
    public var modifiedTime: String?
    public var parents: [String]
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var canRename: Bool
    public var canTrash: Bool
    /// Drive: only the owner may delete permanently.
    public var canDelete: Bool
    public var canAddChildren: Bool

    public init(id: String, name: String, mimeType: String = "", isFolder: Bool = false, sizeBytes: Int64 = 0,
                modifiedTime: String? = nil, parents: [String] = [], width: Int? = nil, height: Int? = nil,
                durationMs: Int64? = nil, canRename: Bool = true, canTrash: Bool = true, canDelete: Bool = false,
                canAddChildren: Bool = true) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.isFolder = isFolder; self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime; self.parents = parents; self.width = width; self.height = height
        self.durationMs = durationMs; self.canRename = canRename; self.canTrash = canTrash; self.canDelete = canDelete
        self.canAddChildren = canAddChildren
    }
}

/// Space where a folder lives: the Google account's storage, the disk or the shared folder.
/// total and free are nil when unknown or unlimited (some Google Workspace accounts).
public struct StorageSpace: Hashable, Sendable {
    public var name: String
    public var used: Int64
    public var total: Int64?
    public var free: Int64?
    public init(name: String, used: Int64, total: Int64?, free: Int64?) {
        self.name = name; self.used = used; self.total = total; self.free = free
    }
}

/// A random-access, read-only view of one file (the Windows app's seekable Stream). The player streams through
/// it (via the loopback media server), so Drive and SMB implementations read ranges with read-ahead.
/// Implementations must be safe to call from any thread, one read at a time per instance.
public protocol ByteSource: AnyObject, Sendable {
    /// Total length in bytes (-1 when unknown).
    var length: Int64 { get }
    /// Reads up to `count` bytes at `offset`. Returns fewer only at the end of the file (empty = end).
    func read(at offset: Int64, count: Int) async throws -> Data
    func close()
}

public extension ByteSource {
    /// Reads the whole source (small files: subtitles, NFOs).
    func readAll(limit: Int = 64 * 1024 * 1024) async throws -> Data {
        var out = Data()
        var pos: Int64 = 0
        while out.count < limit {
            let chunk = try await read(at: pos, count: 1 << 20)
            if chunk.isEmpty { break }
            out.append(chunk)
            pos += Int64(chunk.count)
        }
        return out
    }
}

/// A ByteSource over a local file (FileHandle).
public final class FileByteSource: ByteSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public let length: Int64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        length = (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        try readSync(at: offset, count: count)
    }

    public func readSync(at offset: Int64, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return try handle.read(upToCount: count) ?? Data()
    }

    public func close() { try? handle.close() }
}

/// A ByteSource over bytes in memory (tests, converted subtitles).
public final class DataByteSource: ByteSource, @unchecked Sendable {
    private let data: Data
    public init(_ data: Data) { self.data = data }
    public var length: Int64 { Int64(data.count) }
    public func read(at offset: Int64, count: Int) async throws -> Data {
        let start = Int(min(max(0, offset), Int64(data.count)))
        let end = min(start + count, data.count)
        return data.subdata(in: start..<end)
    }
    public func close() {}
}

/// One kind of source: Google Drive, folders on this Mac, or SMB network shares. Registered with `Storage`.
public protocol FileSource: AnyObject, Sendable {
    /// True for the accounts this source serves (an email, `Accounts.device`, or "smb://host").
    func handles(_ account: String) -> Bool
    func rootId(_ account: String) -> String
    func rootName(_ account: String) -> String
    func list(_ account: String, folderId: String) async throws -> [StorageItem]
    /// Drive searches the whole account; local and network sources filter `currentFolder`.
    func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem]
    /// Returns the item's id afterwards (it changes for local and SMB files).
    func rename(_ account: String, id: String, newName: String) async throws -> String
    /// Drive: to trash (recoverable). This Mac: to the Trash. Network servers: deleted permanently.
    func remove(_ account: String, id: String) async throws
    /// Skips Drive's trash (owner only; a folder goes with everything in it). Others: same as remove.
    func deletePermanently(_ account: String, id: String) async throws
    func space(_ account: String, folderId: String) async throws -> StorageSpace?
    /// Folders with the same key have the same space, so browsing between them needn't ask again.
    func spaceKey(_ account: String, folderId: String) -> String?
    func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws
    func createFolder(_ account: String, parentId: String, name: String) async throws
    /// A random-access reader for the file (the player streams through it).
    func openRead(_ account: String, id: String) async throws -> ByteSource
}

public enum Accounts {
    /// Pseudo-account for folders on this Mac (Android: LocalStorage.ACCOUNT, Windows: "This PC").
    public static let device = "device"
    public static let deviceDisplayName = "This Mac"

    public static func isLocal(_ account: String?) -> Bool { account == device }
    public static func isSmb(_ account: String?) -> Bool { account?.lowercased().hasPrefix("smb://") ?? false }
    public static func isDrive(_ account: String?) -> Bool { account != nil && !isLocal(account) && !isSmb(account) }
}

public struct NoFileSourceError: Error, CustomStringConvertible {
    public let account: String
    public var description: String { "No file source for \(account)" }
}

/// One front door for every file source. Code that must work for every source goes through here; check
/// `isLocal` / `isSmb` instead of assuming Drive.
public final class Storage: @unchecked Sendable {
    private var sources: [FileSource] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ source: FileSource) {
        lock.lock(); sources.append(source); lock.unlock()
    }

    public func isLocal(_ account: String?) -> Bool { Accounts.isLocal(account) }
    public func isSmb(_ account: String?) -> Bool { Accounts.isSmb(account) }

    public func sourceFor(_ account: String) throws -> FileSource {
        lock.lock(); defer { lock.unlock() }
        guard let s = sources.first(where: { $0.handles(account) }) else { throw NoFileSourceError(account: account) }
        return s
    }

    public func hasSource(_ account: String) -> Bool { (try? sourceFor(account)) != nil }

    public func rootId(_ account: String) throws -> String { try sourceFor(account).rootId(account) }
    public func rootName(_ account: String) throws -> String { try sourceFor(account).rootName(account) }

    public func list(_ account: String, folderId: String) async throws -> [StorageItem] {
        try await sourceFor(account).list(account, folderId: folderId)
    }
    public func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem] {
        try await sourceFor(account).search(account, query: query, currentFolder: currentFolder)
    }
    public func rename(_ account: String, id: String, newName: String) async throws -> String {
        try await sourceFor(account).rename(account, id: id, newName: newName)
    }
    public func remove(_ account: String, id: String) async throws {
        try await sourceFor(account).remove(account, id: id)
    }
    public func deletePermanently(_ account: String, id: String) async throws {
        try await sourceFor(account).deletePermanently(account, id: id)
    }
    public func space(_ account: String, folderId: String) async throws -> StorageSpace? {
        try await sourceFor(account).space(account, folderId: folderId)
    }
    public func spaceKey(_ account: String, folderId: String) -> String? {
        (try? sourceFor(account))?.spaceKey(account, folderId: folderId)
    }
    public func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws {
        try await sourceFor(account).move(account, id: id, fromParent: fromParent, toParent: toParent)
    }
    public func createFolder(_ account: String, parentId: String, name: String) async throws {
        try await sourceFor(account).createFolder(account, parentId: parentId, name: name)
    }
    public func openRead(_ account: String, id: String) async throws -> ByteSource {
        try await sourceFor(account).openRead(account, id: id)
    }

    /// Reads a whole (small) file, e.g. a subtitle.
    public func readAll(_ account: String, id: String) async throws -> Data {
        let s = try await openRead(account, id: id)
        defer { s.close() }
        return try await s.readAll()
    }
}
