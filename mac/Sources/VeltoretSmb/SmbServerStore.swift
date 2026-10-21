import Foundation
import VeltoretKit

/// A network share server (SMB: Windows file sharing, Samba on routers and NAS boxes, Macs). Its account id is
/// `account` ("smb://host"); files are "smb://host/share/folder/file" (see `SmbPath`).
public struct SmbServer: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int
    /// Empty for guest access.
    public var username: String
    public var domain: String
    /// What the user sees; the host unless the server told us its name.
    public var name: String

    public init(host: String, port: Int = 445, username: String = "", domain: String = "", name: String = "") {
        self.host = host; self.port = port; self.username = username; self.domain = domain; self.name = name
    }

    public var account: String { SmbPath.accountOf(host) }
    public var guest: Bool { username.isEmpty }
    public var displayName: String { name.isEmpty ? host : name }

    enum CodingKeys: String, CodingKey { case host, port, username, domain, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 445
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        domain = (try? c.decodeIfPresent(String.self, forKey: .domain)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
    }
}

/// Saved servers (Android: SmbServerStore). The list is JSON in `AppPaths.stores/smb_servers.json` **without**
/// passwords; passwords live in the Keychain (`SecretStoring`) under "smb-<account>". A server whose password is
/// missing from the Keychain (another Mac, Keychain reset) means "sign in again". Guests have no Keychain item.
public final class SmbServerStore: @unchecked Sendable {
    public static var defaultURL: URL { AppPaths.stores.appendingPathComponent("smb_servers.json") }

    private let url: URL
    private let secrets: SecretStoring
    private let lock = NSLock()
    private var entries: [SmbServer]

    /// Raised (on any thread) after a server is saved or removed.
    public let changed = Event<Void>()

    public init(url: URL = SmbServerStore.defaultURL, secrets: SecretStoring) {
        self.url = url
        self.secrets = secrets
        entries = SmbServerStore.load(url)
    }

    static func secretKey(_ account: String) -> String { "smb-" + account }

    /// Saved servers, sorted by name.
    public var servers: [SmbServer] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(Self.normalized).sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    public func server(_ account: String) -> SmbServer? {
        lock.lock(); defer { lock.unlock() }
        return entries.map(Self.normalized).first { $0.account == account }
    }

    /// Saves (or replaces) a server and its password. Guests and empty passwords store "".
    public func save(_ server: SmbServer, password: String) {
        var s = server
        s.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.name.isEmpty { s.name = s.host }
        let key = Self.secretKey(s.account)
        if s.guest {
            secrets.delete(key)
        } else {
            do { try secrets.setString(key, password) } catch { Log.error(error, "Saving the password for \(s.account)") }
        }
        lock.lock()
        entries.removeAll { Self.normalized($0).account == s.account }
        entries.append(s)
        persist()
        lock.unlock()
        changed.fire()
    }

    public func remove(_ account: String) {
        lock.lock()
        entries.removeAll { Self.normalized($0).account == account }
        persist()
        lock.unlock()
        secrets.delete(Self.secretKey(account))
        changed.fire()
    }

    /// "" for guest or an empty password; nil when it's missing from the Keychain (sign in again) or the server is
    /// unknown.
    public func password(_ account: String) -> String? {
        guard let s = server(account) else { return nil }
        if s.guest { return "" }
        return secrets.getString(Self.secretKey(account))
    }

    // MARK: - File

    private struct FileShape: Codable { var servers: [SmbServer]? }

    private static func normalized(_ e: SmbServer) -> SmbServer {
        var s = e
        s.host = e.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.port <= 0 { s.port = 445 }
        if s.name.isEmpty { s.name = s.host }
        return s
    }

    private static func load(_ url: URL) -> [SmbServer] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileShape.self, from: data) else { return [] }
        return (file.servers ?? []).filter { !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Call with the lock held.
    private func persist() {
        do {
            AppPaths.ensure(url.deletingLastPathComponent())
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(FileShape(servers: entries)).write(to: url, options: .atomic)
        } catch {
            Log.error(error, "Saving network servers")
        }
    }
}

/// Library account rows for saved servers (Android: AccountRepository.addServerAccount / ensureServerAccounts).
public enum SmbAccounts {
    public static func addServerAccount(_ dao: AccountDao, _ server: SmbServer) throws {
        let existing = try dao.accounts().first { $0.email == server.account }
        try dao.upsert(AccountEntity(email: server.account, displayName: server.displayName, photoUrl: nil,
                                     addedAt: existing?.addedAt ?? nowMillis()))
    }

    /// Back-fills account rows for saved servers (runs at app start).
    public static func ensureServerAccounts(_ dao: AccountDao, _ store: SmbServerStore) throws {
        let accounts = Set(try dao.accounts().map(\.email))
        for server in store.servers where !accounts.contains(server.account) {
            try addServerAccount(dao, server)
        }
    }
}
