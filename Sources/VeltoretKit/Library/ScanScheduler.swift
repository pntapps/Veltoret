import Foundation

/// When library scans run (Android SyncWorker + WorkManager). One scan at a time from a serial queue:
/// - User scans (`runNow`: "Scan library now", a folder's scan, adding a folder, saving a TMDB key) queue up behind
///   the running one.
/// - Automatic scans (`requestAutomatic`: after renames, moves, extraction, Fix match, coming back online, every
///   12 hours) are dropped while another scan is queued or running, since that scan covers them.
/// A failed scan is retried twice. After a scan that went online and wasn't cancelled, artwork is prefetched.
public final class ScanScheduler: @unchecked Sendable {
    public static let period: TimeInterval = 12 * 3600

    private let scanner: LibraryScanner
    private let connectivity: ScanConnectivity
    private let settings: SettingsStore
    private let prefetch: ArtworkPrefetch?

    private let lock = NSLock()
    private var queue: [Request] = []
    private var running = false
    private var started = false
    private var timerTask: Task<Void, Never>?
    private var onlineSub: Subscription?
    private var prefetching = false

    /// Delays between retries of a failed scan (seconds); tests shorten them.
    var retryDelays: [TimeInterval] = [30, 60]
    /// How often to check whether another scan holds the scanner (seconds).
    var busyPoll: TimeInterval = 0.5

    private final class Request: @unchecked Sendable {
        let folderIds: Set<Int64>?
        let automatic: Bool
        private let lock = NSLock()
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(folderIds: Set<Int64>?, automatic: Bool) { self.folderIds = folderIds; self.automatic = automatic }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished { lock.unlock(); c.resume(); return }
                waiters.append(c)
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let w = waiters
            waiters = []
            lock.unlock()
            w.forEach { $0.resume() }
        }
    }

    public init(scanner: LibraryScanner, connectivity: ScanConnectivity, settings: SettingsStore, prefetch: ArtworkPrefetch?) {
        self.scanner = scanner
        self.connectivity = connectivity
        self.settings = settings
        self.prefetch = prefetch
    }

    deinit { timerTask?.cancel() }

    /// True while a scan runs or waits in the queue.
    public var busy: Bool {
        lock.lock(); defer { lock.unlock() }
        return running || !queue.isEmpty
    }

    /// Starts the 12-hour schedule (checked hourly against the last whole-library scan) and the back-online trigger.
    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        onlineSub = connectivity.onlineChanged.subscribe { [weak self] online in
            guard let self else { return }
            if online && self.settings.current.onboardingComplete { self.requestAutomatic() }
        }
        // First check shortly after startup, then every hour: a periodic scan is due 12 h after the last one.
        timerTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                self?.periodicCheck()
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    /// Stops the timer and the back-online trigger (app quit).
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        onlineSub?.cancel()
        onlineSub = nil
        lock.lock(); started = false; lock.unlock()
    }

    private func periodicCheck() {
        let s = settings.current
        if !s.onboardingComplete { return }
        let last = max(0, s.lastScanAt)
        if Double(nowMillis() - last) / 1000 >= Self.period { requestAutomatic() }
    }

    /// A scan the user asked for: queued behind a running one. Returns when this scan has finished.
    public func runNow(_ folderIds: Set<Int64>? = nil) async {
        if let r = enqueue(folderIds, automatic: false) { await r.wait() }
    }

    /// An automatic whole-library scan; ignored when a scan is already queued or running.
    public func requestAutomatic() {
        if busy { return }
        _ = enqueue(nil, automatic: true)
    }

    /// Stops the running scan (keeping what it already found) and drops queued ones.
    public func cancel() {
        lock.lock()
        let dropped = queue
        queue.removeAll()
        lock.unlock()
        scanner.cancel()
        dropped.forEach { $0.finish() }
    }

    private func enqueue(_ folderIds: Set<Int64>?, automatic: Bool) -> Request? {
        let request = Request(folderIds: folderIds, automatic: automatic)
        lock.lock()
        if automatic && (running || !queue.isEmpty) { lock.unlock(); return nil }
        queue.append(request)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { Task.detached { [self] in await self.drain() } }
        return request
    }

    private func drain() async {
        while true {
            let next: Request? = lock.withLock {
                if queue.isEmpty {
                    running = false
                    return nil
                }
                return queue.removeFirst()
            }
            guard let next else { return }
            await runOne(next)
            next.finish()
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func runOne(_ request: Request) async {
        var attempt = 0
        while attempt < 3 {
            do {
                // A scan started directly on the scanner (not through here) holds it: wait for that one first.
                while scanner.isBusy { await sleep(busyPoll) }
                try await scanner.scan(request.folderIds)
                break
            } catch {
                if attempt == 2 { return }
                Log.info("Scan failed, retrying: \(LibraryScanner.message(error))")
                await sleep(retryDelays[min(attempt, retryDelays.count - 1)])
            }
            attempt += 1
        }
        // Keep artwork on this Mac for offline use; a failure here never fails the scan.
        guard let prefetch, connectivity.isOnline, !scanner.state.cancelled else { return }
        let go = lock.withLock { () -> Bool in
            if prefetching { return false }
            prefetching = true
            return true
        }
        guard go else { return }
        Task.detached { [self] in
            do { try await prefetch.run() } catch { Log.info("Artwork prefetch failed: \(error)") }
            self.lock.withLock { self.prefetching = false }
        }
    }
}
