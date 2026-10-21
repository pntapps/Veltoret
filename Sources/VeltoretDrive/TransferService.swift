import Foundation
import VeltoretKit

public enum TransferKind: String, Codable, Sendable { case upload = "Upload", extract = "Extract" }

public enum TransferState: String, Codable, Sendable {
    case enqueued = "Enqueued", waiting = "Waiting", running = "Running", succeeded = "Succeeded", failed = "Failed"
}

/// One upload or ZIP extraction (Android: a WorkManager job). Snapshots are handed out.
public struct TransferJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public var kind: TransferKind = .upload
    public var account: String = ""
    /// Upload: the Drive folder to upload into. Extract: the folder holding the ZIP.
    public var parentId: String = ""
    /// Upload: the file on this Mac.
    public var localPath: String?
    public var zipId: String?
    /// File name (upload) or ZIP name (extract).
    public var name: String = ""
    public var size: Int64 = 0
    public var after: ZipAfterExtract = .keep
    public var wifiOnly: Bool = false
    public var state: TransferState = .enqueued
    /// 0..1; for extraction, compressed bytes consumed / ZIP size.
    public var progress: Float = 0
    /// Extraction: the file being unpacked ("Preparing…" at first).
    public var current: String?
    /// Extraction: files done so far; after success, files extracted or already there.
    public var count: Int = 0
    public var error: String?
    public var zipNote: String?
    /// Extraction: the folder the files went into.
    public var folderId: String?
    public var attempt: Int = 0
    public var createdAt: Int64 = 0
    public var finishedAt: Int64 = 0

    public init() {}

    public var isActive: Bool { state == .enqueued || state == .waiting || state == .running }
    public var isFinished: Bool { state == .succeeded || state == .failed }
}

/// What the Extract dialog shows before starting: free space and whether an earlier attempt's folder exists.
public struct ExtractCheck: Hashable, Sendable {
    public var free: Int64?
    public var resuming: Bool
    public var size: Int64
    public init(free: Int64?, resuming: Bool, size: Int64) { self.free = free; self.resuming = resuming; self.size = size }
    public var tooBig: Bool { if let free { return free < size && !resuming }; return false }
}

/// The local file of an upload is gone.
public struct LocalFileMissingError: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "The file is no longer on this Mac" }
}

/// Background uploads and ZIP extractions (Android: UploadWorker / ExtractWorker on WorkManager). Jobs run as
/// Swift tasks, at most two uploads and two extractions at a time, and are saved to a JSON file so they continue
/// after a restart (an interrupted job restarts: uploads from byte 0, extractions skipping files already in Drive).
///
/// Uploads: 3 attempts, extractions: 4 (backoff 30 s, 60 s, 120 s). A full Drive or an unreadable ZIP fails at
/// once. Failed jobs stay listed until dismissed.
public final class TransferService: @unchecked Sendable {
    static let uploadAttempts = 3
    static let extractAttempts = 4

    private let drive: DriveClient
    private let url: URL
    private let lock = NSLock()
    private var jobList: [TransferJob] = []
    private var running: [String: Task<Void, Never>] = [:]
    private let uploadSlots = AsyncSemaphore(2)
    private let extractSlots = AsyncSemaphore(2)
    private var resumed = false

    /// Whether there is an internet connection (jobs wait while offline).
    public var isOnline: () -> Bool = { true }
    /// "Only on Wi-Fi" extractions wait until this is true (Mac: a non-expensive, non-constrained network).
    public var isUnmetered: () -> Bool = { true }
    /// After a successful extraction: an automatic library rescan.
    public var afterExtraction: (() async -> Void)?
    /// After the ZIP was trashed/deleted: drop its archive row.
    public var forgetArchive: ((String) async throws -> Void)?
    public var backoff: [TimeInterval] = [30, 60, 120]
    public var constraintPoll: TimeInterval = 5

    /// Fired (on a background thread) whenever a job changes: progress, state, added.
    public let jobChanged = Event<TransferJob>()
    /// Fired once when a job succeeds or finally fails.
    public let jobFinished = Event<TransferJob>()
    /// Fired when a job was dismissed or cancelled (its id).
    public let jobRemoved = Event<String>()

    public init(drive: DriveClient, jobsURL: URL) {
        self.drive = drive
        self.url = jobsURL
        load()
    }

    public var jobs: [TransferJob] { lock.lock(); defer { lock.unlock() }; return jobList }

    public var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return jobList.contains { $0.isActive } }

    /// The latest job for a ZIP, an active one preferred (Archives screen).
    public func latestForZip(_ zipId: String) -> TransferJob? {
        lock.lock(); defer { lock.unlock() }
        let mine = jobList.filter { $0.kind == .extract && $0.zipId == zipId }.sorted { $0.createdAt > $1.createdAt }
        return mine.first { $0.isActive } ?? mine.first
    }

    /// Starts the jobs that were waiting or running when Veltoret last quit.
    public func resume() {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let pending = jobList.filter { $0.isActive }
        lock.unlock()
        for j in pending { start(j.id) }
    }

    // MARK: - enqueue

    @discardableResult
    public func upload(account: String, parentId: String, urls: [URL]) -> [TransferJob] {
        urls.map { upload(account: account, parentId: parentId, url: $0) }
    }

    @discardableResult
    public func upload(account: String, parentId: String, url: URL) -> TransferJob {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        var job = TransferJob()
        job.kind = .upload
        job.account = account
        job.parentId = parentId
        job.localPath = url.path
        job.name = url.lastPathComponent.isEmpty ? "Upload" : url.lastPathComponent
        job.size = size
        job.state = .enqueued
        job.createdAt = nowMillis()
        add(job)
        start(job.id)
        return job
    }

    /// One job per ZIP: extracting a ZIP that is already being extracted returns that job.
    @discardableResult
    public func extract(account: String, zipId: String, zipName: String?, zipSize: Int64, parentId: String,
                        after: ZipAfterExtract, wifiOnly: Bool) -> TransferJob {
        var job = TransferJob()
        lock.lock()
        if let active = jobList.first(where: { $0.kind == .extract && $0.zipId == zipId && $0.isActive }) {
            lock.unlock()
            return active
        }
        job.kind = .extract
        job.account = account
        job.zipId = zipId
        job.name = (zipName?.isEmpty ?? true) ? "Archive.zip" : zipName!
        job.size = zipSize
        job.parentId = parentId
        job.after = after
        job.wifiOnly = wifiOnly
        job.state = .enqueued
        job.createdAt = nowMillis()
        jobList.append(job)
        saveLocked()
        lock.unlock()
        jobChanged.fire(job)
        start(job.id)
        return job
    }

    /// Free space in Drive and whether a folder named like the ZIP already sits next to it.
    public func checkExtract(account: String, zipName: String, zipSize: Int64, parentId: String) async -> ExtractCheck {
        async let freeTask = drive.freeBytes(account)
        async let childrenTask = drive.listChildren(account, folderId: parentId, orderBy: "folder,name_natural")
        let free: Int64? = (try? await freeTask) ?? nil
        let baseName = DriveFormat.baseName(zipName)
        let resuming = ((try? await childrenTask) ?? []).contains { $0.isFolder && $0.name == baseName }
        return ExtractCheck(free: free, resuming: resuming, size: zipSize)
    }

    /// Runs a failed job again (extraction continues where it stopped).
    public func retry(_ id: String) {
        lock.lock()
        guard var job = find(id), !job.isActive else { lock.unlock(); return }
        job.state = .enqueued; job.attempt = 0; job.error = nil; job.progress = 0; job.current = nil; job.count = 0; job.zipNote = nil
        replaceLocked(job)
        lock.unlock()
        jobChanged.fire(job)
        start(id)
    }

    /// Removes a finished or failed job from the list.
    public func dismiss(_ id: String) {
        lock.lock()
        guard let job = find(id), !job.isActive else { lock.unlock(); return }
        jobList.removeAll { $0.id == job.id }
        saveLocked()
        lock.unlock()
        jobRemoved.fire(id)
    }

    /// Stops a job and removes it. A half-done upload session simply expires on Drive's side.
    public func cancel(_ id: String) {
        lock.lock()
        running[id]?.cancel()
        jobList.removeAll { $0.id == id }
        saveLocked()
        lock.unlock()
        jobRemoved.fire(id)
    }

    // MARK: - running

    private func start(_ id: String) {
        lock.lock()
        if running[id] != nil || find(id) == nil { lock.unlock(); return }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(id)
            self.lock.withLock { self.running[id] = nil }
        }
        running[id] = task
        lock.unlock()
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        else { try Task.checkCancellation() }
    }

    private func run(_ id: String) async {
        do {
            while true {
                guard var job = get(id) else { return }
                let slots = job.kind == .upload ? uploadSlots : extractSlots
                let maxAttempts = job.kind == .upload ? Self.uploadAttempts : Self.extractAttempts

                // Constraints: a connection; "Only on Wi-Fi" extractions an unmetered one.
                while !(isOnline() && (!job.wifiOnly || isUnmetered())) {
                    if job.state != .waiting {
                        job = update(id, save: true) { $0.state = .waiting } ?? job
                    }
                    try await sleep(constraintPoll)
                }

                await slots.wait()
                var retry = false
                do {
                    try Task.checkCancellation()
                    guard let current = update(id, save: true, { $0.state = .running; $0.attempt += 1; $0.error = nil }) else {
                        await slots.signal()
                        return
                    }
                    job = current
                    if job.kind == .upload { try await runUpload(job) } else { try await runExtract(job) }
                    await slots.signal()
                    return
                } catch is CancellationError {
                    await slots.signal()
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { await slots.signal(); throw CancellationError() }
                    if Self.isFinal(error) || (get(id)?.attempt ?? maxAttempts) >= maxAttempts {
                        let failed = update(id, save: true) {
                            $0.state = .failed
                            $0.error = Self.failureMessage($0, error)
                            $0.finishedAt = nowMillis()
                        }
                        await slots.signal()
                        if let failed { jobFinished.fire(failed) }
                        return
                    }
                    // Retry from the start (a new upload session; extraction skips files already in Drive).
                    guard let next = update(id, save: true, { $0.state = .enqueued }) else { await slots.signal(); return }
                    job = next
                    retry = true
                    await slots.signal()
                }
                if retry {
                    let attempt = min(max(job.attempt - 1, 0), max(backoff.count - 1, 0))
                    try await sleep(backoff.isEmpty ? 0 : backoff[attempt])
                }
            }
        } catch {
            // Cancelled: the job was removed.
        }
    }

    /// Errors a retry can't fix: a full Drive, an unreadable ZIP, a missing local file, a sign-in to redo.
    static func isFinal(_ e: Error) -> Bool {
        if e is ExtractFailedError || e is DriveStorageFullError || e is LocalFileMissingError || e is AuthRequiredError
            || e is GoogleSetupError { return true }
        return !(e is DriveIOError || e is URLError)
    }

    static func failureMessage(_ job: TransferJob, _ e: Error) -> String {
        if e is LocalFileMissingError { return "The file is no longer on this Mac" }
        let message = ZipExtractor.text(e).trimmingCharacters(in: .whitespacesAndNewlines)
        if e is DriveIOError || e is URLError { return message.isEmpty ? "Network problem" : message }
        if !message.isEmpty { return message }
        return job.kind == .extract ? "Extraction failed" : "Upload failed"
    }

    private func runUpload(_ job: TransferJob) async throws {
        guard let path = job.localPath else { throw LocalFileMissingError() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { throw LocalFileMissingError() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
        update(job.id) { $0.progress = 0; $0.size = size }
        var lastPercent = -1
        let fileURL = URL(fileURLWithPath: path)
        _ = try await drive.upload(job.account, parentId: job.parentId, name: job.name, mimeType: DriveFormat.mimeFor(job.name),
                                   size: size, open: {
            do { return try FileByteStream(url: fileURL) } catch { throw LocalFileMissingError() }
        }, onProgress: { [weak self] sent, total in
            let percent = total > 0 ? Int(sent * 100 / total) : 0
            if percent == lastPercent { return }
            lastPercent = percent
            self?.update(job.id) { $0.progress = Float(percent) / 100 }
        })
        let done = update(job.id, save: true) { $0.state = .succeeded; $0.progress = 1; $0.finishedAt = nowMillis() }
        if let done { jobFinished.fire(done) }
    }

    private func runExtract(_ job: TransferJob) async throws {
        let extractor = ZipExtractor(drive: drive, forgetArchive: forgetArchive)
        let result = try await extractor.run(job.account, zipId: job.zipId ?? "", zipName: job.name, parentId: job.parentId,
                                             after: job.after) { [weak self] p in
            self?.update(job.id) { $0.progress = p.fraction; $0.current = p.current; $0.count = p.done }
        }
        let done = update(job.id, save: true) {
            $0.state = .succeeded
            $0.progress = 1
            $0.count = result.count
            $0.folderId = result.folderId
            $0.zipNote = result.zipNote
            $0.current = nil
            $0.finishedAt = nowMillis()
        }
        if let afterExtraction { await afterExtraction() }
        if let done { jobFinished.fire(done) }
    }

    // MARK: - state

    private func find(_ id: String) -> TransferJob? { jobList.first { $0.id == id } }

    private func get(_ id: String) -> TransferJob? { lock.lock(); defer { lock.unlock() }; return find(id) }

    private func replaceLocked(_ job: TransferJob) {
        if let i = jobList.firstIndex(where: { $0.id == job.id }) { jobList[i] = job }
        saveLocked()
    }

    private func add(_ job: TransferJob) {
        lock.lock()
        jobList.append(job)
        saveLocked()
        lock.unlock()
        jobChanged.fire(job)
    }

    @discardableResult
    private func update(_ id: String, save: Bool = false, _ edit: (inout TransferJob) -> Void) -> TransferJob? {
        lock.lock()
        guard let i = jobList.firstIndex(where: { $0.id == id }) else { lock.unlock(); return nil }
        edit(&jobList[i])
        let next = jobList[i]
        if save { saveLocked() }
        lock.unlock()
        jobChanged.fire(next)
        return next
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let jobs = try? JSONDecoder().decode([TransferJob].self, from: data) else { return }
        let dayAgo = nowMillis() - 24 * 3600 * 1000
        for var j in jobs {
            // Finished uploads and day-old successes needn't come back; failures stay until dismissed.
            if j.state == .succeeded && (j.kind == .upload || j.finishedAt < dayAgo) { continue }
            // A job that was running when Veltoret quit starts over.
            if j.isActive { j.state = .enqueued; j.attempt = 0; j.progress = 0 }
            jobList.append(j)
        }
    }

    private func saveLocked() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(jobList).write(to: url, options: .atomic)
        } catch {
            Log.error(error, "Saving transfers")
        }
    }
}
