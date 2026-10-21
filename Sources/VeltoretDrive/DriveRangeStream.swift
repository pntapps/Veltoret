import Foundation
import VeltoretKit

/// A random-access, read-only view of a Drive file over HTTP Range requests (Android: DriveMedia + OkHttp data
/// source). The player streams Drive videos through it (via the loopback media server), and ZIP extraction reads
/// archives through it.
///
/// One connection reads ahead from the current position. A read within the read-ahead buffer or a short way
/// forward is served from it / by reading on; anything else closes the connection and opens a new range at the
/// new position. Every (re)open is a new request with a fresh bearer token, so seeking still works long after the
/// first token expired. A dropped connection is reopened twice before the read fails.
public final class DriveRangeStream: ByteSource, @unchecked Sendable {
    static let bufferSize = 2 * 1024 * 1024
    /// Forward seeks shorter than this read through instead of opening a new connection.
    static let skipAhead: Int64 = 4 * 1024 * 1024

    private let drive: DriveRepository
    private let email: String
    private let id: String
    public let length: Int64
    private let mutex = AsyncMutex()
    private let stateLock = NSLock()
    private var closed = false

    private var body: HttpBodyStream?
    /// The open connection, for close() from another thread while a read waits on it.
    private var liveBody: HttpBodyStream?
    /// File offset of the next byte the connection will deliver.
    private var connectionPos: Int64 = -1

    /// Read-ahead: bytes starting at file offset `bufferStart`.
    private var buffer = Data()
    private var bufferStart: Int64 = 0

    /// Connections opened (tests).
    public private(set) var opens = 0

    public init(drive: DriveRepository, email: String, id: String, length: Int64) {
        self.drive = drive
        self.email = email
        self.id = id
        self.length = length
    }

    private var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }

    /// Reads up to `count` bytes at `offset`; fewer only at the end of the file.
    public func read(at offset: Int64, count: Int) async throws -> Data {
        if count <= 0 { return Data() }
        if offset < 0 { throw DriveIOError("Seek before the start of the file") }
        return try await mutex.run {
            var out = Data()
            var pos = offset
            while out.count < count {
                let part = try await readSome(at: pos, max: count - out.count)
                if part.isEmpty { break }
                out.append(part)
                pos += Int64(part.count)
            }
            return out
        }
    }

    /// One buffer's worth (the C# stream's ReadAsync).
    private func readSome(at position: Int64, max: Int) async throws -> Data {
        if isClosed { throw DriveIOError("The stream was closed") }
        if length >= 0 && position >= length { return Data() }

        // Served from the read-ahead buffer?
        if let d = fromBuffer(position, max) { return d }

        // Refill the buffer from the connection, (re)opening it when it isn't at a useful position.
        var attempt = 0
        while true {
            do {
                let filled = try await fill(position)
                return filled ? (fromBuffer(position, max) ?? Data()) : Data()
            } catch where attempt < 2 && Self.isRetryable(error) && !Task.isCancelled && !isClosed {
                // A dropped connection mid-stream: reopen at the same place and carry on.
                closeConnection()
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                attempt += 1
            }
        }
    }

    static func isRetryable(_ e: Error) -> Bool { e is DriveIOError || e is URLError }

    private func fromBuffer(_ position: Int64, _ max: Int) -> Data? {
        guard position >= bufferStart && position < bufferStart + Int64(buffer.count) else { return nil }
        let start = Int(position - bufferStart)
        let n = min(max, buffer.count - start)
        return buffer.subdata(in: start..<(start + n))
    }

    /// Puts the bytes at `position` into the buffer. False at end of file.
    private func fill(_ position: Int64) async throws -> Bool {
        if body == nil || position < connectionPos || position - connectionPos > Self.skipAhead {
            closeConnection()
            opens += 1
            guard let response = try await drive.openRange(email, id: id, from: position) else { return false }
            body = response.body
            stateLock.withLock { liveBody = response.body }
            // A server that ignores Range answers 200 with the whole file.
            connectionPos = response.status == 206 ? position : 0
        }
        guard let body else { return false }

        // Read through bytes before `position` (a short forward seek, or a 200 answer).
        while connectionPos < position {
            let skip = Int(min(Int64(Self.bufferSize), position - connectionPos))
            let n = try await body.read(max: skip)
            if n.isEmpty { throw DriveIOError("The connection to Google Drive closed early") }
            connectionPos += Int64(n.count)
        }

        // Read ahead: at least one chunk, more while the connection already has data waiting.
        bufferStart = position
        buffer = Data()
        let want = length >= 0 ? Int(min(Int64(Self.bufferSize), length - position)) : Self.bufferSize
        while buffer.count < want {
            let n = try await body.read(max: want - buffer.count)
            if n.isEmpty { break }
            buffer.append(n)
            connectionPos += Int64(n.count)
            if buffer.count >= 256 * 1024 { break } // enough to answer; don't stall the player waiting for 2 MB
        }
        if buffer.isEmpty {
            if length >= 0 && position < length { throw DriveIOError("The connection to Google Drive closed early") }
            return false
        }
        return true
    }

    private func closeConnection() {
        body?.close()
        body = nil
        connectionPos = -1
    }

    public func close() {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        let live = liveBody
        liveBody = nil
        stateLock.unlock()
        if wasClosed { return }
        live?.close()
        Task { [self] in await mutex.run { closeConnection(); buffer = Data() } }
    }
}
