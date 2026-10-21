import Foundation
import VeltoretKit

/// Google Drive v3 REST, call for call the Android app's DriveApi/DriveRepository: listing with paging, search,
/// rename/move/trash, delete, create folder, about/space, downloads (whole or by byte range) and resumable uploads.
///
/// Every request is tagged with its account; `DriveAuthTransport` adds the token and retries a 401 once. The
/// transport must not follow redirects (Drive's 308 "Resume Incomplete" is not a redirect). Timeouts: metadata
/// 60 s, each upload chunk 5 min, downloads 60 s without data.
public final class DriveRepository: DriveClient, @unchecked Sendable {
    public static let base = "https://www.googleapis.com/"
    public static let fileFields =
        "id,name,mimeType,size,modifiedTime,parents,fileExtension,videoMediaMetadata(width,height,durationMillis)," +
        "capabilities(canRename,canTrash,canDelete,canAddChildren)"
    public static let listFields = "nextPageToken,files(" + fileFields + ")"
    public static let aboutFields = "user(displayName,emailAddress,photoLink),storageQuota(limit,usage)"
    public static let chunkSize = 8 * 1024 * 1024

    static let callTimeout: TimeInterval = 60
    static let chunkTimeout: TimeInterval = 5 * 60
    public static let readTimeout: TimeInterval = 60

    private let http: HttpTransport

    public init(http: HttpTransport) { self.http = http }

    /// The usual production transport: the auth wrapper over URLSession (no redirects).
    public static func createTransport(tokens: TokenProvider) -> HttpTransport {
        DriveAuthTransport(tokens: tokens, inner: URLSessionTransport())
    }

    /// Escaping inside a q string literal: \ → \\, then ' → \'.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private static func esc(_ s: String) -> String { UrlEncoding.escape(s) }

    private func request(_ method: String, _ email: String, _ url: String, body: Encodable? = nil,
                         timeout: TimeInterval = DriveRepository.callTimeout) -> URLRequest {
        var r = URLRequest(url: URL(string: url.hasPrefix("http") ? url : Self.base + url)!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        DriveAuthTransport.tag(&r, account: email)
        if let body {
            r.httpBody = try? JSONEncoder().encode(AnyEncodable(body))
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ request: URLRequest) async throws -> HttpResponse {
        do {
            return try await http.send(request)
        } catch let e as URLError where e.code == .timedOut {
            throw DriveIOError("Google Drive didn't respond in time.")
        } catch let e as URLError {
            throw DriveIOError(e.localizedDescription)
        }
    }

    private func call<T: Decodable>(_ request: URLRequest, _ what: String) async throws -> T {
        let response = try await send(request)
        if !response.isSuccess { throw DriveIOError(Self.errorMessage(what, response.status, response.body)) }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw DriveIOError(what + ": empty answer from Drive")
        }
    }

    /// Drive's own message when it sends one ("File not found: …"), else "{what} (HTTP {code})".
    static func errorMessage(_ what: String, _ status: Int, _ body: Data) -> String {
        if let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let e = root["error"] as? [String: Any], let m = e["message"] as? String,
           !m.trimmingCharacters(in: .whitespaces).isEmpty {
            return m
        }
        return "\(what) (HTTP \(status))"
    }

    // MARK: - files.list

    private func listAll(_ email: String, q: String, orderBy: String?, pageSize: Int, allPages: Bool) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String?
        repeat {
            try Task.checkCancellation()
            let url = "drive/v3/files?q=" + Self.esc(q) +
                (pageToken.map { "&pageToken=" + Self.esc($0) } ?? "") +
                (orderBy.map { "&orderBy=" + Self.esc($0) } ?? "") +
                "&fields=" + Self.esc(Self.listFields) +
                "&pageSize=\(pageSize)&supportsAllDrives=true&includeItemsFromAllDrives=true"
            let page: DriveFileList = try await call(request("GET", email, url), "Couldn't list the folder")
            all.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while allPages && pageToken != nil
        return all
    }

    /// Every child of a folder (all pages). Library scans pass orderBy "folder".
    public func listChildren(_ email: String, folderId: String, orderBy: String? = "folder,name_natural") async throws -> [DriveFile] {
        try await listAll(email, q: "'\(Self.escape(folderId))' in parents and trashed = false", orderBy: orderBy,
                          pageSize: 1000, allPages: true)
    }

    public func listSharedWithMe(_ email: String) async throws -> [DriveFile] {
        try await listAll(email, q: "sharedWithMe = true and trashed = false", orderBy: "folder,name", pageSize: 1000, allPages: true)
    }

    /// Whole-account name search; first page only (200).
    public func search(_ email: String, text: String) async throws -> [DriveFile] {
        try await listAll(email, q: "name contains '\(Self.escape(text))' and trashed = false", orderBy: "folder,name",
                          pageSize: 200, allPages: false)
    }

    public func get(_ email: String, id: String) async throws -> DriveFile {
        try await call(request("GET", email, "drive/v3/files/\(Self.esc(id))?fields=\(Self.esc(Self.fileFields))&supportsAllDrives=true"),
                       "Couldn't open the file")
    }

    // MARK: - files.update

    private struct UpdateBody: Encodable {
        var name: String?
        var trashed: Bool?
    }

    private struct CreateBody: Encodable {
        var name: String
        var mimeType: String
        var parents: [String]
    }

    private func update(_ email: String, _ id: String, _ body: UpdateBody, addParents: String?, removeParents: String?,
                        _ what: String) async throws -> DriveFile {
        let url = "drive/v3/files/\(Self.esc(id))?fields=\(Self.esc(Self.fileFields))&supportsAllDrives=true" +
            (addParents.map { "&addParents=" + Self.esc($0) } ?? "") +
            (removeParents.map { "&removeParents=" + Self.esc($0) } ?? "")
        return try await call(request("PATCH", email, url, body: body), what)
    }

    @discardableResult
    public func rename(_ email: String, id: String, newName: String) async throws -> DriveFile {
        try await update(email, id, UpdateBody(name: newName), addParents: nil, removeParents: nil, "Rename failed")
    }

    @discardableResult
    public func move(_ email: String, id: String, fromParent: String?, toParent: String) async throws -> DriveFile {
        try await update(email, id, UpdateBody(), addParents: toParent, removeParents: fromParent, "Move failed")
    }

    /// To Drive's trash (recoverable for 30 days).
    public func trash(_ email: String, id: String) async throws {
        _ = try await update(email, id, UpdateBody(trashed: true), addParents: nil, removeParents: nil, "Move to trash failed")
    }

    /// files.delete: skips the trash. Owner only; a folder goes with everything in it.
    public func deletePermanently(_ email: String, id: String) async throws {
        let response = try await send(request("DELETE", email, "drive/v3/files/\(Self.esc(id))?supportsAllDrives=true"))
        if response.isSuccess { return }
        throw DriveIOError(response.status == 403
            ? "Only the owner of this file can delete it permanently"
            : "Delete failed (HTTP \(response.status))")
    }

    @discardableResult
    public func createFolder(_ email: String, parentId: String, name: String) async throws -> DriveFile {
        try await call(request("POST", email, "drive/v3/files?fields=\(Self.esc(Self.fileFields))&supportsAllDrives=true",
                               body: CreateBody(name: name, mimeType: DriveFile.folderMime, parents: [parentId])),
                       "Couldn't create the folder")
    }

    // MARK: - about

    public func about(_ email: String) async throws -> DriveAbout {
        try await call(request("GET", email, "drive/v3/about?fields=" + Self.esc(Self.aboutFields)), "Couldn't open your Drive")
    }

    /// limit - usage (≥ 0); nil when Drive reports no limit (unlimited) or no quota.
    public func freeBytes(_ email: String) async throws -> Int64? {
        guard let q = try await about(email).storageQuota, let limit = q.limit.flatMap({ Int64($0) }),
              let usage = q.usage.flatMap({ Int64($0) }) else { return nil }
        return max(0, limit - usage)
    }

    public func space(_ email: String) async throws -> StorageSpace? {
        Self.spaceFrom(try await about(email).storageQuota)
    }

    public static func spaceFrom(_ q: StorageQuota?) -> StorageSpace? {
        guard let q, let usage = q.usage.flatMap({ Int64($0) }) else { return nil }
        let total = q.limit.flatMap { Int64($0) }
        return StorageSpace(name: "Google storage", used: usage, total: total, free: total.map { max(0, $0 - usage) })
    }

    // MARK: - downloads

    public static func mediaUrl(_ id: String) -> String { "\(base)drive/v3/files/\(UrlEncoding.escape(id))?alt=media&supportsAllDrives=true" }

    static func downloadError(_ status: Int) -> DriveIOError {
        switch status {
        case 403: return DriveIOError("Google Drive refused the download (it may have hit its daily download limit, or be flagged by Google).")
        case 404: return DriveIOError("The file is no longer in Google Drive.")
        default: return DriveIOError("Download failed (HTTP \(status)).")
        }
    }

    private func openStream(_ request: URLRequest) async throws -> HttpStreamResponse {
        do {
            return try await http.open(request)
        } catch let e as URLError where e.code == .timedOut {
            throw DriveIOError("Google Drive didn't respond in time.")
        } catch let e as URLError {
            throw DriveIOError(e.localizedDescription)
        }
    }

    /// Streams the whole file to `block` with its length (-1 when unknown). A read that gets no data for 60 s fails.
    public func download(_ email: String, id: String, _ block: (HttpBodyStream, Int64) async throws -> Void) async throws {
        let response = try await openStream(request("GET", email, Self.mediaUrl(id), timeout: Self.readTimeout))
        defer { response.body.close() }
        if !response.isSuccess { throw Self.downloadError(response.status) }
        let length = response.header("content-length").flatMap { Int64($0) } ?? -1
        try await block(response.body, length)
    }

    /// Opens the file from byte `from` (Range: bytes=from-). Returns nil at or past the end (416). The caller
    /// closes the body. Each call gets a fresh bearer token, so streams survive token expiry.
    public func openRange(_ email: String, id: String, from: Int64) async throws -> HttpStreamResponse? {
        var r = request("GET", email, Self.mediaUrl(id), timeout: Self.readTimeout)
        r.setValue("bytes=\(from)-", forHTTPHeaderField: "Range")
        let response = try await openStream(r)
        if response.status == 416 {
            response.body.close()
            return nil
        }
        if !response.isSuccess {
            response.body.close()
            throw Self.downloadError(response.status)
        }
        return response
    }

    /// A random-access reader (HTTP Range per (re)open).
    public func openRead(_ email: String, id: String) async throws -> ByteSource {
        let file = try await get(email, id: id)
        return DriveRangeStream(drive: self, email: email, id: id, length: file.size != nil ? file.sizeBytes : -1)
    }

    // MARK: - resumable upload

    /// Resumable upload in 8 MiB chunks. `size` may be -1 (unknown, e.g. a ZIP entry with a data descriptor):
    /// chunks then declare "/*" until the last one, which declares the total. The stream from `open` is closed at
    /// the end. There is no per-chunk retry: jobs retry from byte 0.
    @discardableResult
    public func upload(_ email: String, parentId: String, name: String, mimeType: String, size: Int64,
                       open: @escaping () throws -> ByteStream, onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> DriveFile {
        var start = request("POST", email,
                            "\(Self.base)upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=\(Self.esc(Self.fileFields))")
        start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        if size >= 0 { start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length") }
        start.httpBody = try JSONEncoder().encode(CreateBody(name: name, mimeType: mimeType, parents: [parentId]))
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let started = try await send(start)
        if !started.isSuccess { throw Self.uploadError("Upload could not start", started) }
        guard let session = started.header("location"), !session.isEmpty else {
            throw DriveIOError("Drive did not return an upload session")
        }

        let input = try open()
        defer { input.close() }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await Self.readChunk(input)
            let count = Int64(chunk.count)
            let last = chunk.count < Self.chunkSize
            let total = size >= 0 ? String(size) : last ? String(offset + count) : "*"
            let range = count == 0 ? "bytes */\(total)" : "bytes \(offset)-\(offset + count - 1)/\(total)"

            var put = request("PUT", email, session, timeout: Self.chunkTimeout)
            put.httpBody = chunk
            put.setValue(range, forHTTPHeaderField: "Content-Range")
            let response: HttpResponse
            do {
                response = try await http.send(put)
            } catch let e as URLError where e.code == .timedOut {
                throw DriveIOError("Upload timed out")
            } catch let e as URLError {
                throw DriveIOError(e.localizedDescription)
            }
            if response.status == 308 {
                if last { throw DriveIOError("File ended before upload completed") }
                offset += count
                onProgress?(offset, size)
                continue
            }
            if response.isSuccess {
                onProgress?(offset + count, size)
                guard let file = try? JSONDecoder().decode(DriveFile.self, from: response.body) else {
                    throw DriveIOError("Upload failed: empty answer from Drive")
                }
                return file
            }
            throw Self.uploadError("Upload failed", response)
        }
    }

    /// Fills a chunk unless the stream ends first.
    private static func readChunk(_ input: ByteStream) async throws -> Data {
        var out = Data()
        out.reserveCapacity(chunkSize)
        while out.count < chunkSize {
            let n = try await input.read(max: chunkSize - out.count)
            if n.isEmpty { break }
            out.append(n)
        }
        return out
    }

    static func uploadError(_ what: String, _ response: HttpResponse) -> Error {
        if response.status == 403 && response.text.contains("storageQuotaExceeded") { return DriveStorageFullError() }
        return DriveIOError("\(what) (HTTP \(response.status))")
    }
}

/// Type-erases an Encodable for JSONEncoder.
struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
