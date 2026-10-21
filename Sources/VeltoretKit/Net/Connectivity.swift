import Foundation
import Network

/// Whether this Mac can reach the internet right now. Drives "offline mode": when it's false the library shows only
/// titles that can play from this Mac, scans skip Drive/network folders and TMDB, and Drive-only actions explain that
/// they need a connection.
///
/// NWPathMonitor reports network changes (debounced 1.5 s); a reachability check (`refresh()`) then confirms the
/// internet answers (Apple's captive-portal page, TMDB, Google), also every minute, as on Windows.
/// `isMetered` = the current path is expensive (hotspot, cellular) or constrained (Low Data Mode).
/// `onlineChanged` fires on a background thread; UI code hops to the main actor.
public final class Connectivity: @unchecked Sendable {
    private static let probeUrls = [
        "http://captive.apple.com/hotspot-detect.html",
        "https://api.themoviedb.org/",
        "https://www.googleapis.com/generate_204",
    ]

    private let lock = NSLock()
    private var online: Bool
    private var path: NWPath?
    private var monitor: NWPathMonitor?
    private var periodic: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var checking = false
    private var started = false
    private let queue = DispatchQueue(label: "com.pntapps.veltoret.connectivity")
    private let probe: URLSession

    /// Raised with the new value whenever online/offline changes (distinct values only).
    public let onlineChanged = Event<Bool>()

    /// Optional override for the system check: true/false when known, nil to fall back to the HTTP probe (tests).
    public var systemCheck: (() -> Bool?)?
    /// Optional override for `isMetered` (tests). Default: the NWPath's isExpensive || isConstrained.
    public var meteredCheck: (() -> Bool)?

    /// Optimistic until the first check.
    public init(initiallyOnline: Bool = true) {
        online = initiallyOnline
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        probe = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    /// Metered connection: "Only on Wi-Fi" work waits while this is true.
    public var isMetered: Bool {
        if let meteredCheck { return meteredCheck() }
        lock.lock(); defer { lock.unlock() }
        guard let path else { return false }
        return path.isExpensive || path.isConstrained
    }

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.path = p; self.lock.unlock()
            self.scheduleRefresh()
        }
        m.start(queue: queue)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(60))
        t.setEventHandler { [weak self] in Task { _ = await self?.refresh() } }
        t.resume()

        lock.lock(); monitor = m; periodic = t; lock.unlock()
    }

    public func stop() {
        lock.lock()
        monitor?.cancel(); monitor = nil
        periodic?.cancel(); periodic = nil
        debounce?.cancel(); debounce = nil
        started = false
        lock.unlock()
    }

    /// Adapters flap while connecting; wait for things to settle.
    private func scheduleRefresh() {
        let item = DispatchWorkItem { [weak self] in Task { _ = await self?.refresh() } }
        lock.lock(); debounce?.cancel(); debounce = item; lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Checks now and updates `isOnline`. Returns the new value.
    @discardableResult
    public func refresh() async -> Bool {
        let busy: Bool? = lock.withLock {
            if checking { return online }
            checking = true
            return nil
        }
        if let busy { return busy }
        let value = await check()
        lock.withLock { checking = false }
        set(value)
        return value
    }

    /// For tests and the app: force a value.
    public func set(_ value: Bool) {
        lock.lock()
        if online == value { lock.unlock(); return }
        online = value
        lock.unlock()
        onlineChanged.fire(value)
    }

    private func check() async -> Bool {
        if let systemCheck, let v = systemCheck() { return v }
        let p = lock.withLock { path }
        if let p, p.status != .satisfied { return false }
        for url in Self.probeUrls {
            guard let u = URL(string: url) else { continue }
            do {
                var request = URLRequest(url: u)
                request.httpMethod = "GET"
                let (data, response) = try await probe.data(for: request)
                if url.hasPrefix("http://") {
                    // Plain HTTP can be answered by a captive portal: only Apple's exact page counts.
                    let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                    if ok, String(decoding: data, as: UTF8.self).contains("Success") { return true }
                    continue
                }
                return true // any HTTPS answer means the internet is reachable
            } catch {
                continue // try the next host
            }
        }
        return false
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// The scanner's view of connectivity (core-scan seam in Library/ScanState.swift).
extension Connectivity: ScanConnectivity {}
