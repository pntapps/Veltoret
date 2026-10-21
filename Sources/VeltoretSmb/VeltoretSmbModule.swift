import Foundation
import VeltoretKit

/// VeltoretSmb module entry points (called by the app target).
public enum VeltoretSmbModule {
    /// Creates the server store, the SMB file source (registered with `AppServices.storage`) and discovery, and
    /// back-fills library account rows for saved servers. Needs the foundation (`AppServices.initFoundation`).
    public static func initialize() {
        let store = SmbServerStore(url: SmbServerStore.defaultURL, secrets: AppServices.secrets)
        AppServices.smbServers = store
        let files = SmbFileSource(servers: store)
        AppServices.smbFiles = files
        AppServices.storage.register(files)
        AppServices.smbDiscovery = SmbDiscovery()
        do {
            try SmbAccounts.ensureServerAccounts(AppServices.accountDao, store)
        } catch {
            Log.error(error, "Adding network server accounts")
        }
    }

    public static func start() {}

    public static func shutdown() {
        AppServices.smbDiscovery?.stop()
        AppServices.smbFiles?.disconnectAll()
    }
}
