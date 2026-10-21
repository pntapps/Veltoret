import Foundation
import Network
import VeltoretKit

/// A file-sharing server found on the local network. `name` is what it calls itself, when it says.
public struct FoundServer: Hashable, Sendable, Identifiable {
    public var address: String
    public var name: String?
    public var isRouter: Bool
    public init(address: String, name: String?, isRouter: Bool = false) {
        self.address = address; self.name = name; self.isRouter = isRouter
    }
    public var id: String { address }

    /// "Your router" for the gateway, else "File server" when the server gave no name.
    public var label: String { name ?? (isRouter ? "Your router" : "File server") }
    /// "<ip> · router" for the gateway, else the address.
    public var subtitle: String { isRouter ? "\(address) · router" : address }
}

/// Finds SMB servers on the Wi-Fi/Ethernet network, for people who don't know their server's address (port of
/// Android's / Windows' SmbDiscovery). Two ways at once:
/// - servers that announce themselves over Bonjour ("_smb._tcp": NAS boxes, Macs, many Linux machines), browsed
///   with NWBrowser for 5 s;
/// - a sweep of the local subnet for anything accepting file-sharing connections (TCP 445), which finds routers
///   with a USB drive and Windows PCs that don't announce. Each hit is asked its NetBIOS name (UDP 137).
///
/// `discover()` streams raw results; `start()` / `stop()` run one scan and keep the merged, sorted `servers`
/// (deduplicated by address), firing `changed` on every update and when the scan ends.
public final class SmbDiscovery: @unchecked Sendable {
    public static let serviceType = "_smb._tcp"
    static let sweepBatch = 64
    static let connectTimeoutMs: Int32 = 400
    static let netBiosTimeoutMs: Int32 = 700
    static let resolveTimeoutMs = 3_000
    static let announceWindowMs = 5_000
    /// Never sweep more than a /22 (1022 addresses); bigger networks fall back to the /24 around us.
    static let minPrefix = 22

    private let lock = NSLock()
    private var found: [FoundServer] = []
    private var task: Task<Void, Never>?
    private var running = false

    /// Fired (on any thread) when `servers` or `isScanning` change.
    public let changed = Event<Void>()

    public init() {}

    /// Merged results of the current/last scan: routers first, then named servers, then by address.
    public var servers: [FoundServer] { lock.lock(); defer { lock.unlock() }; return found }

    public var isScanning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Starts a fresh scan ("Scan again" calls it again). Previous results are cleared.
    public func start() {
        lock.lock()
        task?.cancel()
        found = []
        running = true
        lock.unlock()
        changed.fire()
        let t = Task { [weak self] in
            guard let self else { return }
            for await server in self.discover() {
                if Task.isCancelled { break }
                self.add(server)
            }
            if !Task.isCancelled { self.scanFinished() }
        }
        lock.lock(); task = t; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let t = task
        task = nil
        let was = running
        running = false
        lock.unlock()
        t?.cancel()
        if was { changed.fire() }
    }

    private func scanFinished() {
        lock.lock()
        running = false
        task = nil
        lock.unlock()
        changed.fire()
    }

    private func add(_ server: FoundServer) {
        lock.lock()
        found = SmbDiscovery.merge(found, server)
        lock.unlock()
        changed.fire()
    }

    /// Adds `server` to `list`: one row per address (`name = existing.name ?? new.name`, router if either says so),
    /// sorted routers first, then rows with a name, then by address.
    public static func merge(_ list: [FoundServer], _ server: FoundServer) -> [FoundServer] {
        var out = list
        if let i = out.firstIndex(where: { $0.address == server.address }) {
            out[i].name = out[i].name ?? server.name
            out[i].isRouter = out[i].isRouter || server.isRouter
        } else {
            out.append(server)
        }
        return out.sorted { a, b in
            if a.isRouter != b.isRouter { return a.isRouter }
            if (a.name != nil) != (b.name != nil) { return a.name != nil }
            return a.address < b.address
        }
    }

    /// Results as they're found; finishes when both the Bonjour browse and the sweep are done (or on cancel).
    public func discover() -> AsyncStream<FoundServer> {
        AsyncStream { continuation in
            let cancelled = CancelFlag()
            let work = Task.detached {
                guard let network = SmbNet.localNetwork() else { continuation.finish(); return }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await SmbDiscovery.announced(cancelled) { continuation.yield($0) } }
                    group.addTask {
                        try? await SmbNet.background {
                            SmbDiscovery.sweep(network, cancelled) { continuation.yield($0) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in cancelled.set(); work.cancel() }
        }
    }

    /// The machine's own name (e.g. "MYNAS") for an address someone typed; nil if it doesn't answer.
    public func nameOf(_ address: String) async -> String? {
        let ip: UInt32
        if let v = SmbNet.parseIPv4(address) {
            ip = v
        } else {
            guard let addrs = try? SmbNet.resolve(address, port: 445),
                  let v4 = addrs.first(where: { $0.count >= 8 && $0[1] == UInt8(AF_INET) }) else { return nil }
            ip = UInt32(v4[4]) << 24 | UInt32(v4[5]) << 16 | UInt32(v4[6]) << 8 | UInt32(v4[7])
        }
        return try? await SmbNet.background { SmbNet.netBiosName(ip, timeoutMs: SmbDiscovery.netBiosTimeoutMs) } ?? nil
    }

    // MARK: - Subnet sweep

    private static func sweep(_ network: SmbNet.LocalNetwork, _ cancelled: CancelFlag, emit: (FoundServer) -> Void) {
        let hosts = subnetHosts(network.ownAddress, network.prefix).filter { $0 != network.ownAddress }
        var start = 0
        while start < hosts.count, !cancelled.isSet {
            let batch = Array(hosts[start..<min(start + sweepBatch, hosts.count)])
            start += sweepBatch
            let hits = SmbNet.acceptingHosts(batch, port: 445, timeoutMs: connectTimeoutMs)
            if hits.isEmpty || cancelled.isSet { continue }
            // Ask the hits their names in parallel (each waits up to 700 ms).
            var names = [String?](repeating: nil, count: hits.count)
            let namesLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: hits.count) { i in
                let n = SmbNet.netBiosName(hits[i], timeoutMs: netBiosTimeoutMs)
                namesLock.lock(); names[i] = n; namesLock.unlock()
            }
            for (i, ip) in hits.enumerated() where !cancelled.isSet {
                let address = fromInt(ip)
                emit(FoundServer(address: address, name: names[i], isRouter: address == network.gateway))
            }
        }
    }

    // MARK: - Bonjour

    /// Servers announcing "_smb._tcp" over Bonjour, for `announceWindowMs`; each resolved to its IPv4 address.
    private static func announced(_ cancelled: CancelFlag, emit: @escaping @Sendable (FoundServer) -> Void) async {
        let queue = DispatchQueue(label: "veltoret.smb.bonjour")
        let browser = NWBrowser(for: .bonjour(type: serviceType + ".", domain: "local."), using: .tcp)
        let seen = SeenNames()
        let (instances, sink) = AsyncStream<NWEndpoint>.makeStream()
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, seen.insert(name) { sink.yield(r.endpoint) }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { sink.finish() }
        }
        browser.start(queue: queue)
        let window = Task {
            try? await Task.sleep(nanoseconds: UInt64(announceWindowMs) * 1_000_000)
            sink.finish()
        }
        // One resolve at a time, like Android.
        for await endpoint in instances {
            if cancelled.isSet { break }
            guard case let .service(name, _, _, _) = endpoint else { continue }
            if let address = await resolve(endpoint, queue: queue) {
                emit(FoundServer(address: address, name: name))
            }
        }
        window.cancel()
        browser.cancel()
    }

    /// The service's IPv4 address, found by connecting to it (Network.framework resolves on connect).
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        let once = OnceBox()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            @Sendable func finish(_ v: String?) {
                guard once.claim() else { return }
                conn.cancel()
                c.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint, case let .ipv4(v4) = host {
                        finish(SmbNet.format(v4.rawValue.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                case .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(resolveTimeoutMs)) { finish(nil) }
        }
    }

    // MARK: - Address math

    /// The other addresses on our subnet (network and broadcast addresses left out).
    public static func subnetHosts(_ own: UInt32, _ prefix: Int) -> [UInt32] {
        let bits = (minPrefix...30).contains(prefix) ? prefix : 24
        let mask: UInt32 = ~0 << UInt32(32 - bits)
        let base = own & mask
        let size = UInt32(1) << UInt32(32 - bits)
        return (1..<(size - 1)).map { base + $0 }
    }

    /// The address as a host-order integer; nil when it isn't a dotted IPv4 address.
    public static func toInt(_ address: String) -> UInt32? { SmbNet.parseIPv4(address) }

    public static func fromInt(_ ip: UInt32) -> String { SmbNet.format(ip) }
}

/// A thread-safe "stop" flag for the blocking halves of discovery.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class SeenNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()
    func insert(_ n: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.insert(n.lowercased()).inserted }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
