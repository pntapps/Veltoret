import Foundation
import SwiftUI
import VeltoretKit
import VeltoretUI

/// FeatureNetwork module entry points (called by the app target).
///
/// The app target also wires (FeatureNetwork depends on neither FeatureLibrary nor FeaturePlayer):
/// `LibraryHooks.addNetworkServer = { await AddServerDialog.show() }`,
/// `LibraryHooks.castButton = { AnyView(CastButton()) }`,
/// `LibraryHooks.castIfConnected = { await CastLauncher.castIfConnected($0) }`,
/// `PlayerHooks.castButton = { CastPlayerBridge.makeCastButton() }` and `CastPlayerBridge.attach(...)`.
public enum FeatureNetworkModule {
    /// After VeltoretUIModule/VeltoretSmbModule/VeltoretCastModule.initialize(): registers the Settings sections.
    @MainActor
    public static func initialize() {
        SettingsSections.register(id: "network", title: "Network servers", order: 300, icon: "server.rack") {
            NetworkServersSection()
        }
        SettingsSections.register(id: "play-on-tv", title: "Play on TV", order: 500, icon: "tv") {
            PlayOnTvSection()
        }
    }

    /// Follows the cast state (player hand-off, firewall hint).
    @MainActor
    public static func start() {
        CastStateModel.shared.bind()
        CastPlayerBridge.start()
        CastFirewall.watch()
    }

    @MainActor
    public static func shutdown() {
        CastPanel.close()
    }
}
