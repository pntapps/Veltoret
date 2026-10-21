import Foundation
import VeltoretKit

/// VeltoretDrive module entry points (called by the app target).
public enum VeltoretDriveModule {
    public static func initialize() {
        let auth = GoogleAuthService(http: URLSessionTransport(), secrets: AppServices.secrets, accounts: AppServices.accountDao)
        AppServices.googleAuth = auth
        let drive = DriveRepository(http: DriveRepository.createTransport(tokens: auth))
        AppServices.drive = drive
        let files = DriveFileSource(drive: drive)
        AppServices.driveFiles = files
        AppServices.storage.register(files)

        let transfers = TransferService(drive: drive, jobsURL: AppPaths.transfers)
        transfers.isOnline = { AppServices.connectivity?.isOnline ?? true }
        transfers.isUnmetered = { !(AppServices.connectivity?.isMetered ?? false) }
        // A new folder full of videos: an automatic library rescan (queued behind a running scan).
        transfers.afterExtraction = {
            if let scans = AppServices.scans { Task { await scans.runNow() } }
        }
        transfers.forgetArchive = { id in
            if let library = AppServices.library { try library.forgetArchive(id) } else { try AppServices.mediaFileDao.deleteArchive(id) }
        }
        AppServices.transfers = transfers
    }

    public static func start() {
        if let transfers = AppServices.transfers, transfers.hasPending { transfers.resume() }
    }

    public static func shutdown() {}
}
