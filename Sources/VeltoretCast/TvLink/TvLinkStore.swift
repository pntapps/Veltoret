import Foundation
import VeltoretKit

/// Paired TVs and their shared secrets, plus this Mac's own link id (Android/Windows TvLinkStore).
/// `AppPaths.stores/tv_link.json` = `{deviceId, peers:[{id,name}]}`; each secret is in the Keychain
/// (`AppServices.secrets`, key "tvlink.secret.<id>"). Never logged; kept out of exports.
public final class TvLinkStore: @unchecked Sendable {
    private struct FileModel: Codable {
        var deviceId: String = ""
        var peers: [LinkPeer] = []
    }

    private let url: URL
    private let secrets: SecretStoring
    private let lock = NSLock()
    private var model: FileModel

    public let changed = Event<Void>()

    public init(url: URL = TvLinkStore.defaultURL, secrets: SecretStoring) {
        self.url = url
        self.secrets = secrets
        model = Self.load(url)
        if model.deviceId.isEmpty {
            model.deviceId = UUID().uuidString.lowercased()
            save()
        }
    }

    public static var defaultURL: URL { AppPaths.stores.appendingPathComponent("tv_link.json") }

    static func secretKey(_ id: String) -> String { "tvlink.secret.\(id)" }

    /// This Mac's id in the link protocol (random UUID, made once).
    public var deviceId: String { lock.lock(); defer { lock.unlock() }; return model.deviceId }

    public var peers: [LinkPeer] {
        lock.lock(); defer { lock.unlock() }
        return model.peers.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func save(_ peer: LinkPeer, secret: String) {
        lock.lock()
        do { try secrets.setString(Self.secretKey(peer.id), secret) } catch { Log.error(error, "Saving a paired TV") }
        model.peers.removeAll { $0.id == peer.id }
        model.peers.append(peer)
        save()
        lock.unlock()
        changed.fire()
    }

    public func remove(_ id: String) {
        lock.lock()
        let before = model.peers.count
        model.peers.removeAll { $0.id == id }
        let removed = model.peers.count != before
        secrets.delete(Self.secretKey(id))
        if removed { save() }
        lock.unlock()
        if removed { changed.fire() }
    }

    /// Nil when not paired, or when the Keychain item is gone: pair again.
    public func secret(_ id: String) -> String? {
        lock.lock()
        let known = model.peers.contains { $0.id == id }
        lock.unlock()
        guard known else { return nil }
        return secrets.getString(Self.secretKey(id))
    }

    private static func load(_ url: URL) -> FileModel {
        guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(FileModel.self, from: data) else { return FileModel() }
        return m
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(model).write(to: url, options: .atomic)
        } catch {
            Log.error(error, "Saving tv_link.json")
        }
    }
}
