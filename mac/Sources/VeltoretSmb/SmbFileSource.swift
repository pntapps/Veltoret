import AMSMB2
import Foundation
import VeltoretKit

/// File access on SMB servers (Windows sharing, Samba on routers and NAS boxes, Macs) through AMSMB2 (libsmb2,
/// SMB 2 and 3) (Android: SmbStorage, Windows: SmbFileSource). One signed-in connection per share is kept and
/// reused (AMSMB2 binds a connection to one share); a dropped connection is reopened once per call. Requests time
/// out after 20 s, but there's no idle read timeout: the player stops reading for minutes once its buffer is full,
/// and the connection must survive that.
public final class SmbFileSource: FileSource, @unchecked Sendable {
    public static let folderMime = "application/vnd.google-apps.folder"
    static let requestTimeout: TimeInterval = 20
    static let connectTimeoutMs: Int32 = 8_000

    public let servers: SmbServerStore
    private let lock = NSLock()
    private var hosts: [String: HostConnections] = [:]

    public init(servers: SmbServerStore) { self.servers = servers }

    // MARK: - FileSource

    public func handles(_ account: String) -> Bool { SmbPath.isSmb(account) }

    public func rootId(_ account: String) -> String { (try? SmbPath.parse(account).account) ?? account }

    public func rootName(_ account: String) -> String {
        guard let p = try? SmbPath.parse(account) else { return account }
        return servers.server(p.account)?.displayName ?? p.host
    }

    public func list(_ account: String, folderId: String) async throws -> [StorageItem] {
        try await io {
            let path = try SmbPath.parse(folderId)
            guard path.share != nil else {
                return try await self.shareNames(path.host).map { Self.folder(path.child($0), parent: nil) }
            }
            let entries = try await self.withShare(path) { try await $0.contentsOfDirectory(atPath: path.filePath) }
            return entries.compactMap { e -> StorageItem? in
                guard let name = e[.nameKey] as? String, name != ".", name != "..", !Self.isHidden(name) else { return nil }
                let child = path.child(name)
                if (e[.isDirectoryKey] as? NSNumber)?.boolValue == true || (e[.isDirectoryKey] as? Bool) == true {
                    return Self.folder(child, parent: path.id)
                }
                let size = (e[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                return StorageItem(id: child.id, name: name, mimeType: SmbMime.forName(name), isFolder: false, sizeBytes: size,
                                   modifiedTime: Self.iso(e[.contentModificationDateKey] as? Date), parents: [path.id],
                                   canRename: true, canTrash: true, canDelete: true, canAddChildren: true)
            }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    public func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try await list(account, folderId: currentFolder)
        return q.isEmpty ? items : items.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    public func rename(_ account: String, id: String, newName: String) async throws -> String {
        try await io {
            let path = try SmbPath.parse(id)
            guard !path.segments.isEmpty, let parent = path.parent else { throw SmbError("Shared folders can't be renamed from here") }
            let target = parent.child(newName)
            try await self.withShare(path) { try await $0.moveItem(atPath: path.filePath, toPath: target.filePath) }
            return target.id
        }
    }

    public func remove(_ account: String, id: String) async throws { try await delete(id) }

    public func deletePermanently(_ account: String, id: String) async throws { try await delete(id) }

    public func space(_ account: String, folderId: String) async throws -> StorageSpace? {
        try await io {
            let path = try SmbPath.parse(folderId)
            guard let share = path.share else { return nil }
            let attrs = try await self.withShare(path) { try await $0.attributesOfFileSystem(forPath: path.filePath) }
            guard let total = (attrs[.systemSize] as? NSNumber)?.int64Value else { return nil }
            // f_bavail: what this user can still write (respects quotas).
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            return StorageSpace(name: share, used: max(0, total - free), total: total, free: free)
        }
    }

    public func spaceKey(_ account: String, folderId: String) -> String? {
        guard let path = try? SmbPath.parse(folderId), let share = path.share else { return nil }
        return "\(path.host)/\(share)"
    }

    public func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws {
        try await io {
            let path = try SmbPath.parse(id)
            let folder = try SmbPath.parse(toParent)
            if path.segments.isEmpty { throw SmbError("Shared folders can't be moved from here") }
            if folder.host != path.host || folder.share != path.share {
                throw SmbError("Files can only be moved within the same shared folder")
            }
            let target = folder.child(path.name)
            try await self.withShare(path) { try await $0.moveItem(atPath: path.filePath, toPath: target.filePath) }
        }
    }

    public func createFolder(_ account: String, parentId: String, name: String) async throws {
        try await io {
            let path = try SmbPath.parse(parentId).child(name)
            if path.segments.isEmpty { throw SmbError("Shared folders can't be created from here") }
            try await self.withShare(path) { try await $0.createDirectory(atPath: path.filePath) }
        }
    }

    /// A random-access reader (1 MiB chunks with read-ahead) the player streams through.
    public func openRead(_ account: String, id: String) async throws -> ByteSource {
        try await io {
            let path = try SmbPath.parse(id)
            guard let share = path.share else { throw SmbError("Pick a shared folder on \(path.host) first") }
            if path.segments.isEmpty { throw SmbError("\"\(share)\" isn't a file") }
            let attrs = try await self.withShare(path) { try await $0.attributesOfItem(atPath: path.filePath) }
            if (attrs[.isDirectoryKey] as? NSNumber)?.boolValue == true || (attrs[.isDirectoryKey] as? Bool) == true {
                throw SmbError("\"\(path.name)\" isn't a file")
            }
            let length = (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? -1
            return SmbReadStream(source: self, path: path, length: length)
        }
    }

    // MARK: - Server-level operations ("Add network server", Settings)

    /// Signs in to `server` with `password` without saving anything, and lists its shares. Used by "Add network
    /// server" to check the details before they're stored. Throws `SmbError` (worded for people).
    @discardableResult
    public func test(server: SmbServer, password: String) async throws -> [String] {
        try await io { try await Self.listShares(server: server, password: password) }
    }

    /// Forgets the open connections, e.g. after the server was removed or its password changed.
    public func disconnect(_ account: String) {
        guard let host = try? SmbPath.parse(account).host else { return }
        lock.lock()
        let slot = hosts.removeValue(forKey: host)
        lock.unlock()
        if let slot { Task { await slot.closeAll() } }
    }

    /// Closes every connection (app exit).
    public func disconnectAll() {
        lock.lock()
        let all = Array(hosts.values)
        hosts = [:]
        lock.unlock()
        for slot in all { Task { await slot.closeAll() } }
    }

    // MARK: - Internals

    private func delete(_ id: String) async throws {
        try await io {
            let path = try SmbPath.parse(id)
            if path.segments.isEmpty { throw SmbError("Shared folders can't be deleted from here") }
            // Network shares have no trash: deleted permanently, folders with everything in them.
            try await self.withShare(path) { try await $0.removeItem(atPath: path.filePath) }
        }
    }

    /// Hidden and system entries people shouldn't browse (AMSMB2 doesn't report the HIDDEN/SYSTEM attributes).
    static func isHidden(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        switch name.lowercased() {
        case "$recycle.bin", "system volume information", "desktop.ini", "thumbs.db", "recycler":
            return true
        default:
            return false
        }
    }

    private static func folder(_ path: SmbPath, parent: String?) -> StorageItem {
        StorageItem(id: path.id, name: path.name, mimeType: folderMime, isFolder: true,
                    parents: parent.map { [$0] } ?? [], canRename: true, canTrash: true, canDelete: true, canAddChildren: true)
    }

    private static func iso(_ date: Date?) -> String? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        let f = ISO8601DateFormatter()
        let hasMillis = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) >= 0.001
        f.formatOptions = hasMillis ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Disk shares people can browse: no printers, IPC$ or hidden admin shares (ending in $).
    private func shareNames(_ host: String) async throws -> [String] {
        let account = SmbPath.accountOf(host)
        guard let server = servers.server(account) else { throw SmbError("This network server was removed from Veltoret") }
        guard let password = servers.password(account) else { throw SmbError("Sign in to \(server.displayName) again") }
        do {
            return try await Self.listShares(server: server, password: password)
        } catch where SmbErrors.isDropped(error) {
            return try await Self.listShares(server: server, password: password)
        }
    }

    static func listShares(server: SmbServer, password: String) async throws -> [String] {
        let manager = try await makeManager(server: server, password: password)
        let shares = try await manager.listShares(enumerateHidden: false)
        return shares.map(\.name)
            .filter { !$0.hasSuffix("$") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A new, not yet connected manager for `server`, after a quick TCP probe (8 s) so "server off" fails fast.
    static func makeManager(server: SmbServer, password: String) async throws -> SMB2Manager {
        let port = server.port <= 0 ? 445 : server.port
        let host = server.host
        try await SmbNet.background { try SmbNet.probe(host: host, port: port, timeoutMs: connectTimeoutMs) }
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        if port != 445 { comps.port = port }
        // Guest is the "Guest" account with an empty password (not anonymous, which is "").
        let credential = server.guest
            ? URLCredential(user: "Guest", password: "", persistence: .none)
            : URLCredential(user: server.username, password: password, persistence: .none)
        guard let url = comps.url,
              let manager = SMB2Manager(url: url, domain: server.guest ? "" : server.domain, credential: credential) else {
            throw SmbSocketError.hostNotFound(host)
        }
        manager.timeout = requestTimeout
        return manager
    }

    private func slot(_ host: String) -> HostConnections {
        lock.lock(); defer { lock.unlock() }
        if let s = hosts[host] { return s }
        let s = HostConnections(host: host, servers: servers)
        hosts[host] = s
        return s
    }

    /// The share's signed-in connection. Pass the connection that just failed as `stale` to get a fresh one
    /// (unless another caller already replaced it).
    func manager(_ path: SmbPath, stale: SMB2Manager? = nil) async throws -> SMB2Manager {
        guard let share = path.share else { throw SmbError("Pick a shared folder on \(path.host) first") }
        return try await slot(path.host).manager(share: share, stale: stale)
    }

    /// Runs `block` with the share's connection, reconnecting once if the old connection went stale.
    func withShare<T>(_ path: SmbPath, _ block: (SMB2Manager) async throws -> T) async throws -> T {
        let m = try await manager(path)
        do {
            return try await block(m)
        } catch where SmbErrors.isDropped(error) {
            let fresh = try await manager(path, stale: m)
            return try await block(fresh)
        }
    }

    /// Words any failure for people.
    private func io<T>(_ block: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        do {
            return try await block()
        } catch let e as SmbError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmbError(SmbErrors.describe(error), underlying: error)
        }
    }
}

/// The open connections to one server, one per share (AMSMB2 binds a connection to a share). Connecting is
/// serialized per share so parallel callers share one connection.
actor HostConnections {
    let host: String
    let servers: SmbServerStore
    private var managers: [String: SMB2Manager] = [:]
    private var connecting: [String: Task<SMB2Manager, Error>] = [:]

    init(host: String, servers: SmbServerStore) { self.host = host; self.servers = servers }

    func manager(share: String, stale: SMB2Manager?) async throws -> SMB2Manager {
        if let pending = connecting[share] { return try await pending.value }
        if let current = managers[share] {
            if stale == nil || current !== stale { return current }
            managers[share] = nil
            Self.close(current)
        }
        let account = SmbPath.accountOf(host)
        let servers = self.servers
        let task = Task<SMB2Manager, Error> {
            guard let server = servers.server(account) else { throw SmbError("This network server was removed from Veltoret") }
            guard let password = servers.password(account) else { throw SmbError("Sign in to \(server.displayName) again") }
            let m = try await SmbFileSource.makeManager(server: server, password: password)
            try await m.connectShare(name: share)
            return m
        }
        connecting[share] = task
        defer { connecting[share] = nil }
        let m = try await task.value
        managers[share] = m
        return m
    }

    func closeAll() {
        let all = managers.values
        managers = [:]
        for m in all { Self.close(m) }
    }

    nonisolated static func close(_ m: SMB2Manager) {
        m.disconnectShare(gracefully: false, completionHandler: nil)
    }
}
