import Foundation
import VeltoretKit

// [drive] module services: Google sign-in, Drive REST, the Drive file source, uploads and ZIP extraction.
// Created by VeltoretDriveModule.initialize() (after the foundation and core).
extension AppServices {
    public static var googleAuth: GoogleAuthService!
    public static var drive: DriveRepository!
    public static var driveFiles: DriveFileSource!
    /// Uploads to Drive and ZIP extraction jobs (saved in transfers.json, resumed at start).
    public static var transfers: TransferService!
}
