import CryptoKit
import Foundation

/// A tiny async semaphore (SemaphoreSlim).
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { free = count }

    func wait() async {
        if lock.withLock({ () -> Bool in
            if free > 0 { free -= 1; return true }
            return false
        }) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                // A slot may have freed up meanwhile.
                if free > 0 { free -= 1; return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func signal() {
        lock.lock()
        if waiters.isEmpty { free += 1; lock.unlock(); return }
        let c = waiters.removeFirst()
        lock.unlock()
        c.resume()
    }
}

/// Disk cache for TMDB artwork (and account photos), keyed by URL, so the library looks right offline. A file's
/// name is the SHA-1 of its URL. Downloads of the same URL are shared; the cache is trimmed to `maxBytes` by
/// least-recent use (access date, refreshed on every hit), down to 90%.
public final class ImageCache: @unchecked Sendable {
    public static let maxBytes: Int64 = 512 * 1024 * 1024
    /// Trim down to this, so a full cache doesn't trim on every download.
    static let trimTarget: Int64 = maxBytes * 9 / 10

    public let directory: URL
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<URL?, Never>] = [:]
    private let downloads = AsyncGate(6)
    private var size: Int64 = -1
    private var trimming = false
    private let maxBytes: Int64

    public init(directory: URL, session: URLSession? = nil, maxBytes: Int64 = ImageCache.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// Where `url` is (or would be) cached.
    public func path(for url: String) -> URL {
        let hash = Insecure.SHA1.hash(data: Data(url.utf8))
        return directory.appendingPathComponent(hash.map { String(format: "%02x", $0) }.joined())
    }

    public func isCached(_ url: String) -> Bool { FileManager.default.fileExists(atPath: path(for: url).path) }

    /// The local file for `url`: from disk when cached (works offline), else downloaded once.
    /// Nil for a nil/empty URL or when it can't be fetched.
    public func file(for url: String?) async -> URL? {
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let target = path(for: url)
        if FileManager.default.fileExists(atPath: target.path) {
            Self.touch(target)
            return target
        }
        let task: Task<URL?, Never> = lock.withLock {
            if let existing = inflight[url] { return existing }
            let t = Task { await self.download(url, target) }
            inflight[url] = t
            return t
        }
        return await task.value
    }

    /// Downloads every URL not cached yet, four at a time; failures are skipped.
    public func prefetch<S: Sequence>(_ urls: S) async where S.Element == String {
        var seen = Set<String>()
        let todo = urls.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted && !isCached($0) }
        let gate = AsyncGate(4)
        await withTaskGroup(of: Void.self) { group in
            for url in todo {
                await gate.wait()
                group.addTask {
                    _ = await self.file(for: url)
                    gate.signal()
                }
            }
        }
    }

    private func download(_ url: String, _ target: URL) async -> URL? {
        await downloads.wait()
        let tmp = URL(fileURLWithPath: target.path + "." + String(UUID().uuidString.prefix(8)) + ".tmp")
        defer {
            downloads.signal()
            lock.withLock { inflight[url] = nil }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return target }
        guard let u = URL(string: url) else { return nil }
        do {
            let (downloaded, response) = try await session.download(from: u)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: downloaded)
                return nil
            }
            let written = ((try? fm.attributesOfItem(atPath: downloaded.path)[.size]) as? NSNumber)?.int64Value ?? 0
            if written == 0 {
                try? fm.removeItem(at: downloaded)
                return nil
            }
            try fm.moveItem(at: downloaded, to: tmp)
            if fm.fileExists(atPath: target.path) {
                _ = try? fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            addSize(written)
            return target
        } catch {
            try? fm.removeItem(at: tmp)
            return fm.fileExists(atPath: target.path) ? target : nil
        }
    }

    private static func touch(_ file: URL) {
        var f = file
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? f.setResourceValues(values) // in use or read-only: not important
    }

    private func addSize(_ bytes: Int64) {
        lock.lock()
        if size < 0 { size = measureSize() } else { size += bytes }
        let trim = size > maxBytes && !trimming
        if trim { trimming = true }
        lock.unlock()
        if trim {
            DispatchQueue.global(qos: .utility).async {
                self.trim()
                self.lock.lock(); self.trimming = false; self.lock.unlock()
            }
        }
    }

    private func entries() -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            let access = v.contentAccessDate ?? .distantPast, write = v.contentModificationDate ?? .distantPast
            return (u, Int64(v.fileSize ?? 0), max(access, write))
        }
    }

    private func measureSize() -> Int64 { entries().reduce(0) { $0 + $1.size } }

    /// Deletes least recently used files until the cache is under 90% of the maximum.
    public func trim() {
        let target = maxBytes * 9 / 10
        let files = entries().filter { !$0.url.lastPathComponent.hasSuffix(".tmp") }.sorted { $0.used < $1.used }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files {
            if total <= target { break }
            if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
        }
        lock.lock(); size = total; lock.unlock()
    }
}
