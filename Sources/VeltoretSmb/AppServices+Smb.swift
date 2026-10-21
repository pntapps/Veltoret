import Foundation
import VeltoretKit

extension AppServices {
    /// Saved network servers (passwords in the Keychain).
    public static var smbServers: SmbServerStore!
    /// The FileSource for "smb://host" accounts (registered with `storage`).
    public static var smbFiles: SmbFileSource!
    /// Finds SMB servers on the local network ("Add network server").
    public static var smbDiscovery: SmbDiscovery!
}
