import Foundation
import VeltoretKit

extension AppServices {
    /// Chromecast + "Play on TV". Set by `VeltoretCastModule.initialize()`.
    public static var cast: CastController!
    /// Paired Veltoret TVs (secrets in the Keychain).
    public static var tvLinks: TvLinkStore!
}
