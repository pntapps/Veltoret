import Foundation
import VeltoretKit

/// Google Drive behind the `Storage` facade: every account that isn't This Mac or a network server.
/// Root "root" = "My Drive"; the pseudo-folder `sharedRoot` lists "Shared with me".
/// Remove = trash (recoverable); deletePermanently = files.delete. Rename keeps the id.
public final class DriveFileSource: FileSource, @unchecked Sendable {
    public static let rootFolder = "root"
    public static let sharedRoot = "shared"

    private let drive: DriveRepository

    public init(drive: DriveRepository) { self.drive = drive }

    public func handles(_ account: String) -> Bool { Accounts.isDrive(account) }

    public func rootId(_ account: String) -> String { Self.rootFolder }

    public func rootName(_ account: String) -> String { "My Drive" }

    public func list(_ account: String, folderId: String) async throws -> [StorageItem] {
        let files = folderId == Self.sharedRoot
            ? try await drive.listSharedWithMe(account)
            : try await drive.listChildren(account, folderId: folderId, orderBy: "folder,name_natural")
        return files.map { $0.toItem() }
    }

    public func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem] {
        try await drive.search(account, text: query).map { $0.toItem() }
    }

    public func rename(_ account: String, id: String, newName: String) async throws -> String {
        let newId = try await drive.rename(account, id: id, newName: newName).id
        return newId.isEmpty ? id : newId
    }

    public func remove(_ account: String, id: String) async throws { try await drive.trash(account, id: id) }

    public func deletePermanently(_ account: String, id: String) async throws { try await drive.deletePermanently(account, id: id) }

    public func space(_ account: String, folderId: String) async throws -> StorageSpace? { try await drive.space(account) }

    /// Every folder of an account shares the account's Google storage.
    public func spaceKey(_ account: String, folderId: String) -> String? { account }

    public func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws {
        try await drive.move(account, id: id, fromParent: fromParent, toParent: toParent)
    }

    public func createFolder(_ account: String, parentId: String, name: String) async throws {
        try await drive.createFolder(account, parentId: parentId, name: name)
    }

    /// A random-access range reader (the player streams Drive files through it).
    public func openRead(_ account: String, id: String) async throws -> ByteSource {
        try await drive.openRead(account, id: id)
    }
}
