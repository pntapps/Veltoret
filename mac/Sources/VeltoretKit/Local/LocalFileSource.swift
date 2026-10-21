import Foundation

/// A file-system problem on This Mac, with a message the UI can show as is.
public struct LocalFileError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }

    public static let folderUnavailable = LocalFileError(
        "This folder isn't available. If it's on an external or USB drive, make sure it's connected.")
    public static let fileUnavailable = LocalFileError("This file isn't available")
}

/// "This Mac": folders and files on this computer, for account `Accounts.device`. The top level (`root`) lists Home,
/// Movies, Downloads, Desktop and every mounted volume (external and USB drives); every other id is a full POSIX
/// path. Deleting moves items to the Trash (the Mac convention). Hidden files are skipped.
public final class LocalFileSource: FileSource, @unchecked Sendable {
    public static let root = "device-root"
    public static let folderMime = "application/vnd.google-apps.folder"

    public init() {}

    public func handles(_ account: String) -> Bool { Accounts.isLocal(account) }
    public func rootId(_ account: String) -> String { Self.root }
    public func rootName(_ account: String) -> String { Accounts.deviceDisplayName }

    /// Full path without a trailing slash ("/" stays "/"); "~" expands to the home folder.
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = URL(fileURLWithPath: p).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    // MARK: Listing

    public func list(_ account: String, folderId: String) async throws -> [StorageItem] {
        try await Task.detached(priority: .userInitiated) { try Self.listSync(folderId) }.value
    }

    static func listSync(_ folderId: String) throws -> [StorageItem] {
        if folderId == root { return places() }
        let dir = normalize(folderId)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw LocalFileError.folderUnavailable
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
                                      .contentModificationDateKey, .isWritableKey, .isSymbolicLinkKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir, isDirectory: true),
                                                               includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        } catch {
            throw LocalFileError("Veltoret can't open this folder. Check its permissions in System Settings → Privacy & Security.")
        }
        var items: [StorageItem] = []
        for u in urls {
            try Task.checkCancellation()
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isHidden == true || u.lastPathComponent.hasPrefix(".") { continue }
            var folder = v.isDirectory == true && v.isPackage != true
            if v.isSymbolicLink == true {
                var d: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &d) else { continue }
                folder = d.boolValue
            }
            let path = dir == "/" ? "/" + u.lastPathComponent : dir + "/" + u.lastPathComponent
            let modified = v.contentModificationDate.map(iso)
            if folder {
                items.append(StorageItem(id: path, name: u.lastPathComponent, mimeType: folderMime, isFolder: true,
                                         modifiedTime: modified, parents: [dir], canRename: true, canTrash: true,
                                         canDelete: true, canAddChildren: true))
            } else {
                let writable = FileManager.default.isWritableFile(atPath: dir)
                items.append(StorageItem(id: path, name: u.lastPathComponent, mimeType: MimeTypes.forName(u.lastPathComponent),
                                         isFolder: false, sizeBytes: Int64(v.fileSize ?? 0), modifiedTime: modified,
                                         parents: [dir], canRename: writable, canTrash: writable, canDelete: writable,
                                         canAddChildren: false))
            }
        }
        return sortItems(items)
    }

    /// Folders first, then by name as Finder sorts (localizedStandardCompare).
    static func sortItems(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Home, Movies, Downloads, Desktop, then mounted volumes (not the startup disk, which Home already covers).
    static func places() -> [StorageItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var list: [StorageItem] = []
        func add(_ path: String, _ name: String) {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &d), d.boolValue else { return }
            list.append(StorageItem(id: normalize(path), name: name, mimeType: folderMime, isFolder: true, parents: [root],
                                    canRename: false, canTrash: false, canDelete: false, canAddChildren: true))
        }
        add(home, NSUserName().isEmpty ? "Home" : NSUserName())
        add(home + "/Movies", "Movies")
        add(home + "/Downloads", "Downloads")
        add(home + "/Desktop", "Desktop")
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeNameKey, .volumeIsRootFileSystemKey,
                                      .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for v in volumes {
            let path = normalize(v.path)
            if path == "/" || path.hasPrefix("/System/") || path.hasPrefix("/private/") { continue }
            guard let values = try? v.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsRootFileSystem == true || values.volumeIsBrowsable == false { continue }
            list.append(StorageItem(id: path, name: volumeName(values, path: path), mimeType: folderMime, isFolder: true,
                                    parents: [root], canRename: false, canTrash: false, canDelete: false, canAddChildren: true))
        }
        return list
    }

    /// The volume's name as Finder shows it ("Backup"), or "USB Drive" / "External Drive" when it has none.
    static func volumeName(_ v: URLResourceValues, path: String) -> String {
        let label = (v.volumeLocalizedName ?? v.volumeName ?? "").trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { return label }
        let last = (path as NSString).lastPathComponent
        if !last.isEmpty && last != "/" { return last }
        return v.volumeIsRemovable == true || v.volumeIsEjectable == true ? "USB Drive" : "External Drive"
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
    private static let isoLock = NSLock()
    static func iso(_ d: Date) -> String { isoLock.lock(); defer { isoLock.unlock() }; return isoFormatter.string(from: d) }

    /// Names in the current folder that contain the query (not recursive, as on Android/Windows).
    public func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem] {
        let items = try await list(account, folderId: currentFolder)
        return items.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Changes

    private static func checkName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") || name.contains("\0") {
            throw LocalFileError("That name can't be used on a Mac")
        }
    }

    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func rename(_ account: String, id: String, newName: String) async throws -> String {
        try await Task.detached {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.checkName(name)
            let path = Self.normalize(id)
            if path == "/" { throw LocalFileError("This item can't be renamed") }
            let parent = (path as NSString).deletingLastPathComponent
            let target = (parent as NSString).appendingPathComponent(name)
            if path == target { return path }
            guard Self.exists(path) else { throw LocalFileError.fileUnavailable }
            let caseOnly = path.lowercased() == target.lowercased()
            let fm = FileManager.default
            if !caseOnly && Self.exists(target) { throw LocalFileError("There's already something named \"\(name)\" here") }
            do {
                if caseOnly {
                    // Case-insensitive volumes need a detour for a case-only rename.
                    let temp = path + ".rename-" + String(UUID().uuidString.prefix(6))
                    try fm.moveItem(atPath: path, toPath: temp)
                    try fm.moveItem(atPath: temp, toPath: target)
                } else {
                    try fm.moveItem(atPath: path, toPath: target)
                }
            } catch {
                throw LocalFileError("Couldn't rename it")
            }
            return target
        }.value
    }

    /// To the Trash.
    public func remove(_ account: String, id: String) async throws {
        try await Task.detached {
            let path = Self.normalize(id)
            guard Self.exists(path) else { throw LocalFileError.fileUnavailable }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                throw LocalFileError("Couldn't move it to the Trash")
            }
        }.value
    }

    /// Also to the Trash on this Mac (see CLAUDE.md product decisions).
    public func deletePermanently(_ account: String, id: String) async throws { try await remove(account, id: id) }

    public func space(_ account: String, folderId: String) async throws -> StorageSpace? {
        if folderId == Self.root { return nil }
        return await Task.detached { () -> StorageSpace? in
            let url = URL(fileURLWithPath: Self.normalize(folderId))
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                             .volumeAvailableCapacityKey, .volumeLocalizedNameKey, .volumeNameKey]
            guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? v.volumeAvailableCapacity.map { Int64($0) } ?? 0
            let name = v.volumeLocalizedName ?? v.volumeName ?? "This Mac"
            return StorageSpace(name: name, used: max(0, Int64(total) - free), total: Int64(total), free: free)
        }.value
    }

    /// The folder's volume.
    public func spaceKey(_ account: String, folderId: String) -> String? {
        if folderId == Self.root { return nil }
        let url = URL(fileURLWithPath: Self.normalize(folderId))
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
    }

    public func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws {
        try await Task.detached {
            if toParent == Self.root { throw LocalFileError("Choose a folder on a drive") }
            let path = Self.normalize(id)
            let name = (path as NSString).lastPathComponent
            let dest = (Self.normalize(toParent) as NSString).appendingPathComponent(name)
            if path.lowercased() == dest.lowercased() { return }
            guard Self.exists(path) else { throw LocalFileError.fileUnavailable }
            if Self.exists(dest) { throw LocalFileError("There's already something named \"\(name)\" there") }
            if dest.lowercased().hasPrefix(path.lowercased() + "/") { throw LocalFileError("A folder can't be moved into itself") }
            do {
                try FileManager.default.moveItem(atPath: path, toPath: dest)
            } catch {
                throw LocalFileError("Couldn't move it there")
            }
        }.value
    }

    public func createFolder(_ account: String, parentId: String, name: String) async throws {
        try await Task.detached {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if parentId == Self.root { throw LocalFileError("Couldn't create the folder here") }
            try Self.checkName(clean)
            let target = (Self.normalize(parentId) as NSString).appendingPathComponent(clean)
            if Self.exists(target) { throw LocalFileError("There's already something named \"\(clean)\" here") }
            do {
                try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
            } catch {
                throw LocalFileError("Couldn't create the folder here")
            }
        }.value
    }

    public func openRead(_ account: String, id: String) async throws -> ByteSource {
        let path = Self.normalize(id)
        do {
            return try FileByteSource(url: URL(fileURLWithPath: path))
        } catch {
            throw LocalFileError.fileUnavailable
        }
    }
}

/// MIME types for local and network files, from the extension (Drive sends its own).
public enum MimeTypes {
    private static let map: [String: String] = [
        "mkv": "video/x-matroska", "mp4": "video/mp4", "m4v": "video/x-m4v", "avi": "video/x-msvideo",
        "mov": "video/quicktime", "wmv": "video/x-ms-wmv", "flv": "video/x-flv", "webm": "video/webm",
        "ts": "video/mp2t", "m2ts": "video/mp2t", "mts": "video/mp2t", "mpg": "video/mpeg", "mpeg": "video/mpeg",
        "3gp": "video/3gpp", "ogv": "video/ogg", "vob": "video/dvd", "divx": "video/divx", "rmvb": "application/vnd.rn-realmedia-vbr",
        "asf": "video/x-ms-asf", "f4v": "video/x-f4v", "mxf": "application/mxf",
        "srt": "application/x-subrip", "vtt": "text/vtt", "ass": "text/x-ssa", "ssa": "text/x-ssa",
        "ttml": "application/ttml+xml", "dfxp": "application/ttml+xml",
        "zip": "application/zip", "rar": "application/vnd.rar", "7z": "application/x-7z-compressed",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac", "wav": "audio/wav", "ogg": "audio/ogg", "opus": "audio/opus",
        "txt": "text/plain", "nfo": "text/plain", "pdf": "application/pdf", "json": "application/json",
    ]

    public static func forName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return map[ext] ?? "application/octet-stream"
    }
}
