import Foundation
import VeltoretKit

public struct ExtractProgress: Sendable {
    public var fraction: Float
    public var current: String
    public var done: Int
    public init(fraction: Float, current: String, done: Int) { self.fraction = fraction; self.current = current; self.done = done }
}

public struct ExtractResult: Sendable {
    public var count: Int
    public var folderId: String
    public var zipNote: String?
}

/// An extraction that must not be retried (full Drive, unreadable ZIP). `message` is for the user.
public struct ExtractFailedError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let message: String
    public let underlying: Error?
    public init(_ message: String, _ underlying: Error? = nil) { self.message = message; self.underlying = underlying }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Unpacks a ZIP that lives in Google Drive back into Google Drive (Android: ExtractWorker.doWork).
///
/// Nothing is written to this Mac: the archive's central directory is read by HTTP range requests, then each
/// entry's range is inflated as it arrives and piped straight into a resumable upload. Re-running skips files
/// already in Drive (without downloading them), so an interrupted season picks up where it stopped. The ZIP is
/// trashed/deleted only after every file was extracted.
public final class ZipExtractor {
    private let drive: DriveClient
    private let forgetArchive: ((String) async throws -> Void)?

    public init(drive: DriveClient, forgetArchive: ((String) async throws -> Void)? = nil) {
        self.drive = drive
        self.forgetArchive = forgetArchive
    }

    public func run(_ email: String, zipId: String, zipName: String, parentId: String, after: ZipAfterExtract,
                    report: @escaping (ExtractProgress) -> Void) async throws -> ExtractResult {
        report(ExtractProgress(fraction: 0, current: "Preparing…", done: 0))
        var extracted = 0
        var alreadyThere = 0
        do {
            let folders = FolderCache(drive: drive, email: email)
            let root = try await folders.child(parentId, DriveFormat.baseName(zipName))

            let source = try await drive.openRead(email, id: zipId)
            defer { source.close() }
            let length = source.length
            let entries = try await ZipArchive.entries(source)

            for entry in entries {
                try Task.checkCancellation()
                let path = entry.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if entry.isDirectory || path.isEmpty || Self.isJunk(path) { continue }
                if entry.isEncrypted { throw ExtractFailedError("This ZIP is password-protected, which isn't supported.") }

                let slash = path.lastIndex(of: "/")
                let dirId = try await folders.path(root, slash.map { String(path[..<$0]) } ?? "")
                let fileName = slash.map { String(path[path.index(after: $0)...]) } ?? path
                let size = entry.uncompressedSize
                if let existing = try await folders.files(dirId)[fileName], existing.sizeBytes == size {
                    alreadyThere += 1
                    continue // extracted by an earlier run
                }

                let stream = try await ZipArchive.open(source, entry)
                let base = entry.localHeaderOffset
                let fraction: () -> Float = { length > 0 ? Float(Double(base + stream.consumed) / Double(length)) : 0 }
                report(ExtractProgress(fraction: fraction(), current: fileName, done: extracted))
                var lastPercent = -1
                let done = extracted
                do {
                    _ = try await drive.upload(email, parentId: dirId, name: fileName, mimeType: DriveFormat.mimeFor(fileName), size: size,
                                               open: { NonClosingStream(stream) }, onProgress: { _, _ in
                        let percent = Int(fraction() * 100)
                        if percent == lastPercent { return }
                        lastPercent = percent
                        report(ExtractProgress(fraction: fraction(), current: fileName, done: done))
                    })
                    stream.close()
                } catch {
                    stream.close()
                    throw error
                }
                extracted += 1
            }

            // The whole archive was read and every file is in Drive. Never remove an archive that produced nothing.
            var zipNote: String?
            if after != .keep && extracted + alreadyThere > 0 {
                do {
                    if after == .delete {
                        try await drive.deletePermanently(email, id: zipId)
                        zipNote = "ZIP deleted"
                    } else {
                        try await drive.trash(email, id: zipId)
                        zipNote = "ZIP moved to trash"
                    }
                    if let forgetArchive { try await forgetArchive(zipId) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    zipNote = "ZIP kept: \(Self.text(error))"
                }
            }
            return ExtractResult(count: extracted + alreadyThere, folderId: root, zipNote: zipNote)
        } catch let e as DriveStorageFullError {
            // Retrying can't help until space is freed, and every retry would read the ZIP again.
            let done = extracted + alreadyThere
            throw ExtractFailedError("Google Drive is full" +
                (done > 0 ? " after " + (done == 1 ? "1 file" : "\(done) files") : "") +
                ". Free up space (and empty Drive's trash), then extract again: it continues where it stopped.", e)
        } catch {
            if let message = Self.zipError(error) { throw ExtractFailedError(message, error) }
            throw error
        }
    }

    /// A user message for errors that mean the archive itself can't be read (no retry); nil otherwise.
    public static func zipError(_ e: Error) -> String? {
        switch e {
        case let u as ZipUnsupportedError:
            return u.encrypted
                ? "This ZIP is password-protected, which isn't supported."
                : "This ZIP uses a compression format Veltoret can't read. Re-create it with standard ZIP compression."
        case let f as ZipFormatError:
            return "The ZIP looks damaged or incomplete (\(f.message))."
        default:
            return nil
        }
    }

    /// __MACOSX/, AppleDouble "._" files, .DS_Store, Thumbs.db, desktop.ini.
    public static func isJunk(_ path: String) -> Bool {
        let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
        return path.hasPrefix("__MACOSX/") || name.hasPrefix("._") || name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini"
    }

    static func text(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return (error as NSError).localizedDescription
    }

    /// Drive folder lookups with caching: reuses existing folders so re-runs land in the same place.
    private final class FolderCache {
        private let drive: DriveClient
        private let email: String
        private var children: [String: [String: DriveFile]] = [:]
        private var resolved: [String: String] = [:]

        init(drive: DriveClient, email: String) { self.drive = drive; self.email = email }

        func files(_ folderId: String) async throws -> [String: DriveFile] {
            if let known = children[folderId] { return known }
            var map: [String: DriveFile] = [:]
            for f in try await drive.listChildren(email, folderId: folderId, orderBy: "folder,name_natural") {
                map[f.name] = f // duplicates: the last one wins (associateBy)
            }
            children[folderId] = map
            return map
        }

        func child(_ parentId: String, _ name: String) async throws -> String {
            let files = try await files(parentId)
            if let existing = files[name], existing.isFolder { return existing.id }
            let created = try await drive.createFolder(email, parentId: parentId, name: name)
            children[parentId, default: [:]][name] = created
            children[created.id] = [:]
            return created.id
        }

        func path(_ root: String, _ relative: String) async throws -> String {
            if relative.isEmpty { return root }
            if let known = resolved[relative] { return known }
            var current = root
            // Ignore "." / ".." so a malformed archive can't climb out of its own folder.
            for segment in relative.split(separator: "/").map(String.init)
            where !segment.trimmingCharacters(in: .whitespaces).isEmpty && segment != "." && segment != ".." {
                current = try await child(current, segment)
            }
            resolved[relative] = current
            return current
        }
    }
}

/// Lets the uploader close an entry stream without closing it for the extractor (Android: KeepOpen).
final class NonClosingStream: ByteStream {
    private let inner: ByteStream
    init(_ inner: ByteStream) { self.inner = inner }
    func read(max: Int) async throws -> Data { try await inner.read(max: max) }
    func close() {}
}
