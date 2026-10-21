import SwiftUI
import VeltoretKit

/// FeatureLibrary entry points (called by the app target after VeltoretUIModule.initialize()).
public enum FeatureLibraryModule {
    @MainActor public static func initialize() {
        BrowsePages.register()   // home, movies, shows, search, collection   (library-browse worker)
        DetailPages.register()   // movieDetail, showDetail, fixMatch, onboarding (library-detail worker)
    }
    public static func start() {}
    public static func shutdown() {}
}

/// Things the library screens need from other feature modules, which FeatureLibrary can't import (they'd form a
/// cycle). The app target fills these in at launch; each is optional so a missing module only hides its button.
@MainActor
public enum LibraryHooks {
    /// Voice search (FeatureSettings.VoiceSearch.listen): returns the spoken text, nil if cancelled/unavailable.
    public static var voiceSearch: (() async -> String?)?
    /// Connect a Google account (FeatureFiles.ConnectGoogle.run): returns the account, nil if cancelled.
    public static var connectGoogle: (() async -> AccountEntity?)?
    /// Add a network server (FeatureNetwork.AddServerDialog.show): returns the server account id, nil if cancelled.
    public static var addNetworkServer: (() async -> String?)?
    /// The "Remind me" dialog (FeatureSettings.ReminderDialog.show): returns true when a reminder was saved.
    public static var reminderDialog: ((_ type: String, _ id: Int, _ season: Int?, _ episode: Int?,
                                        _ title: String, _ airDate: String?) async -> Bool)?
    /// The Cast button (FeatureNetwork.CastButton) for Home's top bar.
    public static var castButton: (() -> AnyView)?
    /// Cast a library file instead of playing it here when a TV is connected (FeatureNetwork); nil = play locally.
    public static var castIfConnected: ((_ file: MediaFileEntity) async -> Bool)?
}
