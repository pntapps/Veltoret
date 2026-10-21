import Foundation
import Network

/// A resolved DNS-SD service instance. `host` is an IPv4 address.
public struct BonjourService: Hashable, Sendable {
    public var instance: String
    public var host: String?
    public var port: Int
    public var txt: [String: String]
    public init(instance: String, host: String?, port: Int, txt: [String: String]) {
        self.instance = instance; self.host = host; self.port = port; self.txt = txt
    }
    public func txtValue(_ key: String) -> String? { txt[key.lowercased()] }
}

/// DNS-SD browsing with NWBrowser (the Windows app's hand-rolled Mdns.Browse). Each instance is resolved to an
/// IPv4 address and port by opening (and closing) a TCP connection to it. Emits an instance whenever it becomes
/// resolvable or its records change; the stream ends after `window`.
///
/// Service types browsed by the app (Info.plist NSBonjourServices): `_googlecast._tcp`, `_veltoret-play._tcp`,
/// `_veltoret._tcp`.
public enum Bonjour {
    public static func browse(_ serviceType: String, window: TimeInterval) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "veltoret.bonjour")
            var type = serviceType
            if type.hasSuffix(".") { type.removeLast() }
            if type.lowercased().hasSuffix(".local") { type = String(type.dropLast(6)) }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
            var emitted: [String: String] = [:]
            var resolving: Set<String> = []
            var finished = false

            func resolve(_ result: NWBrowser.Result) {
                guard case let .service(name, _, _, _) = result.endpoint else { return }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata { txt = parseTxt(record) }
                let key = "\(result.endpoint)"
                if resolving.contains(key) { return }
                resolving.insert(key)
                let conn = NWConnection(to: result.endpoint, using: NetConnection.parameters(tlsAcceptingAny: false, ipv4Only: true))
                var done = false
                func finish(_ host: String?, _ port: Int) {
                    if done { return }
                    done = true
                    conn.cancel()
                    resolving.remove(key)
                    guard let host, port > 0, !finished else { return }
                    let sig = "\(host):\(port):\(txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))"
                    if emitted[key] == sig { return }
                    emitted[key] = sig
                    continuation.yield(BonjourService(instance: name, host: host, port: port, txt: txt))
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .preparing:
                        if case .ready = state, let remote = conn.currentPath?.remoteEndpoint,
                           case let .hostPort(host, port) = remote {
                            finish(hostString(host), Int(port.rawValue))
                        }
                    case .failed, .cancelled, .waiting:
                        finish(nil, 0)
                    default: break
                    }
                }
                conn.start(queue: queue)
                // Resolve with a 4 s timeout.
                queue.asyncAfter(deadline: .now() + 4) { finish(nil, 0) }
            }

            browser.browseResultsChangedHandler = { results, _ in
                for r in results { resolve(r) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finished = true; continuation.finish() }
            }
            browser.start(queue: queue)
            // Ask again now and then: instances that missed the first answer resolve later.
            func pump() {
                queue.asyncAfter(deadline: .now() + 1.5) {
                    if finished { return }
                    for r in browser.browseResults { resolve(r) }
                    pump()
                }
            }
            pump()
            queue.asyncAfter(deadline: .now() + window) {
                finished = true
                continuation.finish()
            }
            continuation.onTermination = { _ in
                queue.async {
                    finished = true
                    browser.cancel()
                }
            }
        }
    }

    static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let a): return IPAddressUtil.string([UInt8](a.rawValue))
        case .ipv6(let a): return IPAddressUtil.string([UInt8](a.rawValue))
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    /// "fn=Living Room" → fn: Living Room. Keys are lowercased (DNS-SD keys are case-insensitive).
    static func parseTxt(_ record: NWTXTRecord) -> [String: String] {
        var map: [String: String] = [:]
        for (k, v) in record.dictionary where map[k.lowercased()] == nil { map[k.lowercased()] = v }
        return map
    }
}
