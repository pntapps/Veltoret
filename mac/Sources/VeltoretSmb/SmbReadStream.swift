import AMSMB2
import Foundation
import VeltoretKit

/// An open file on a share for random-access reads (the player's data source; Android: SmbReader + SmbDataSource,
/// Windows: SmbReadStream). Reads are positioned (SMB READ at an offset) in chunks of 1 MiB, kept in a small cache
/// with read-ahead of the next 2 chunks so playback doesn't wait on the network. A read that fails because the
/// connection dropped is retried once on a fresh connection. Safe to call from any thread.
public final class SmbReadStream: ByteSource, @unchecked Sendable {
    static let chunkSize: Int64 = 1024 * 1024
    static let readAhead = 2
    static let cacheChunks = 6

    private let source: SmbFileSource
    public let path: SmbPath
    public let length: Int64

    private let lock = NSLock()
    private var chunks: [Int64: Task<Data, Error>] = [:]
    private var recent: [Int64] = [] // most recent first
    private var closed = false

    init(source: SmbFileSource, path: SmbPath, length: Int64) {
        self.source = source
        self.path = path
        self.length = length
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        if isClosed { throw SmbError("The file was closed") }
        guard count > 0, offset >= 0, length < 0 || offset < length else { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        var pos = offset
        var lastIndex: Int64 = -1
        while out.count < count, length < 0 || pos < length {
            let index = pos / Self.chunkSize
            lastIndex = index
            let chunk: Data
            do {
                chunk = try await self.chunk(index).value
            } catch let e as SmbError {
                throw e
            } catch {
                throw SmbError(SmbErrors.describe(error), underlying: error)
            }
            let inChunk = Int(pos - index * Self.chunkSize)
            if inChunk >= chunk.count { break } // end of file (or unknown length reached)
            let n = min(count - out.count, chunk.count - inChunk)
            out.append(chunk.subdata(in: inChunk..<(inChunk + n)))
            pos += Int64(n)
            if chunk.count < Int(Self.chunkSize) && pos >= index * Self.chunkSize + Int64(chunk.count) { break }
        }
        if lastIndex >= 0 { prefetch(after: lastIndex) }
        return out
    }

    public func close() {
        lock.lock()
        closed = true
        let tasks = Array(chunks.values)
        chunks = [:]
        recent = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func prefetch(after index: Int64) {
        let total = length < 0 ? Int64.max : (length + Self.chunkSize - 1) / Self.chunkSize
        for k in 1...Int64(Self.readAhead) where index + k < total {
            _ = chunk(index + k)
        }
    }

    /// The cached (or newly started) fetch of chunk `index`. Failed fetches are dropped so a later read retries.
    private func chunk(_ index: Int64) -> Task<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let task = chunks[index] {
            touch(index)
            return task
        }
        let task = Task<Data, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                return try await self.fetch(index)
            } catch {
                self.forget(index)
                throw error
            }
        }
        if closed { return task }
        chunks[index] = task
        touch(index)
        while recent.count > Self.cacheChunks {
            let old = recent.removeLast()
            chunks[old] = nil
        }
        return task
    }

    /// Call with the lock held.
    private func touch(_ index: Int64) {
        recent.removeAll { $0 == index }
        recent.insert(index, at: 0)
    }

    private func forget(_ index: Int64) {
        lock.lock()
        chunks[index] = nil
        recent.removeAll { $0 == index }
        lock.unlock()
    }

    private func fetch(_ index: Int64) async throws -> Data {
        let offset = index * Self.chunkSize
        let end = length < 0 ? offset + Self.chunkSize : min(offset + Self.chunkSize, length)
        guard end > offset else { return Data() }
        let filePath = path.filePath
        return try await source.withShare(path) { manager in
            if self.isClosed { throw CancellationError() }
            return try await manager.contents(atPath: filePath, range: offset..<end)
        }
    }
}
