import Foundation
import VeltoretKit

/// Drive is out of space (HTTP 403 storageQuotaExceeded). Retrying can't help until space is freed.
public struct DriveStorageFullError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public init() {}
    public var message: String { "Google Drive is full" }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A file or folder as Drive v3 returns it. int64 values (size, duration) arrive as JSON strings.
public struct DriveFile: Codable, Hashable, Sendable {
    public static let folderMime = "application/vnd.google-apps.folder"

    public var id: String
    public var name: String
    public var mimeType: String
    public var size: String?
    public var modifiedTime: String?
    public var parents: [String]?
    public var fileExtension: String?
    public var videoMediaMetadata: VideoMetadata?
    public var capabilities: Capabilities?

    public init(id: String = "", name: String = "", mimeType: String = "", size: String? = nil, modifiedTime: String? = nil,
                parents: [String]? = nil, fileExtension: String? = nil, videoMediaMetadata: VideoMetadata? = nil,
                capabilities: Capabilities? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.modifiedTime = modifiedTime
        self.parents = parents; self.fileExtension = fileExtension; self.videoMediaMetadata = videoMediaMetadata
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, modifiedTime, parents, fileExtension, videoMediaMetadata, capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        size = try c.decodeIfPresent(String.self, forKey: .size)
        modifiedTime = try c.decodeIfPresent(String.self, forKey: .modifiedTime)
        parents = try c.decodeIfPresent([String].self, forKey: .parents)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
        videoMediaMetadata = try c.decodeIfPresent(VideoMetadata.self, forKey: .videoMediaMetadata)
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
    }

    public var isFolder: Bool { mimeType == Self.folderMime }
    public var sizeBytes: Int64 { size.flatMap { Int64($0) } ?? 0 }

    public func toItem() -> StorageItem {
        StorageItem(id: id, name: name, mimeType: mimeType, isFolder: isFolder, sizeBytes: sizeBytes,
                    modifiedTime: modifiedTime, parents: parents ?? [],
                    width: videoMediaMetadata?.width, height: videoMediaMetadata?.height,
                    durationMs: videoMediaMetadata?.durationMillis.flatMap { Int64($0) },
                    canRename: capabilities?.canRename ?? true, canTrash: capabilities?.canTrash ?? true,
                    canDelete: capabilities?.canDelete ?? false, canAddChildren: capabilities?.canAddChildren ?? true)
    }
}

public struct VideoMetadata: Codable, Hashable, Sendable {
    public var width: Int?
    public var height: Int?
    public var durationMillis: String?
    public init(width: Int? = nil, height: Int? = nil, durationMillis: String? = nil) {
        self.width = width; self.height = height; self.durationMillis = durationMillis
    }
}

public struct Capabilities: Codable, Hashable, Sendable {
    public var canRename: Bool?
    public var canTrash: Bool?
    public var canDelete: Bool?
    public var canAddChildren: Bool?
    public init(canRename: Bool? = nil, canTrash: Bool? = nil, canDelete: Bool? = nil, canAddChildren: Bool? = nil) {
        self.canRename = canRename; self.canTrash = canTrash; self.canDelete = canDelete; self.canAddChildren = canAddChildren
    }
}

public struct DriveFileList: Codable, Sendable {
    public var nextPageToken: String?
    public var files: [DriveFile]

    enum CodingKeys: String, CodingKey { case nextPageToken, files }
    public init(nextPageToken: String? = nil, files: [DriveFile] = []) { self.nextPageToken = nextPageToken; self.files = files }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        files = try c.decodeIfPresent([DriveFile].self, forKey: .files) ?? []
    }
}

public struct DriveAbout: Codable, Sendable {
    public var user: DriveUser?
    public var storageQuota: StorageQuota?
    public init(user: DriveUser? = nil, storageQuota: StorageQuota? = nil) { self.user = user; self.storageQuota = storageQuota }
}

public struct DriveUser: Codable, Sendable {
    public var displayName: String?
    public var emailAddress: String?
    public var photoLink: String?
}

public struct StorageQuota: Codable, Sendable {
    public var limit: String?
    public var usage: String?
    public init(limit: String? = nil, usage: String? = nil) { self.limit = limit; self.usage = usage }
}

/// What happens to the ZIP once every file in it has been extracted.
public enum ZipAfterExtract: String, Codable, Sendable, CaseIterable {
    case keep = "Keep", trash = "Trash", delete = "Delete"
}

/// The Drive calls ZIP extraction and uploads need (DriveRepository; an in-memory fake in tests).
public protocol DriveClient: AnyObject, Sendable {
    func listChildren(_ email: String, folderId: String, orderBy: String?) async throws -> [DriveFile]
    func createFolder(_ email: String, parentId: String, name: String) async throws -> DriveFile
    func trash(_ email: String, id: String) async throws
    func deletePermanently(_ email: String, id: String) async throws
    func freeBytes(_ email: String) async throws -> Int64?
    /// A random-access reader over the file (HTTP Range requests). ZIP extraction reads the central directory and
    /// each entry through it.
    func openRead(_ email: String, id: String) async throws -> ByteSource
    /// Resumable upload. `size` may be -1 (unknown). The stream from `open` is closed at the end.
    func upload(_ email: String, parentId: String, name: String, mimeType: String, size: Int64,
                open: @escaping () throws -> ByteStream, onProgress: ((Int64, Int64) -> Void)?) async throws -> DriveFile
}

public extension DriveClient {
    func listChildren(_ email: String, folderId: String) async throws -> [DriveFile] {
        try await listChildren(email, folderId: folderId, orderBy: "folder,name_natural")
    }
}
