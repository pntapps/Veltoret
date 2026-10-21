import Foundation
import SwiftUI
import VeltoretKit
import VeltoretUI

/// FeatureFiles module entry points (called by the app target): the Files manager, the Archives page, the Extract
/// dialog and the "Google accounts" Settings section.
public enum FeatureFilesModule {
    /// Registers the `.files(account:folderId:)` and `.archives` pages and the "Google accounts" Settings section.
    @MainActor
    public static func initialize() {
        PageRegistry.register(.files) { route in
            guard case .files(let account, let folderId) = route else { return nil }
            return AnyView(FilesPage(account: account, folderId: folderId))
        }
        PageRegistry.register(.archives) { route in
            guard case .archives = route else { return nil }
            return AnyView(ArchivesPage())
        }
        SettingsSections.register(id: "google-accounts", title: "Google accounts", order: 200, icon: "person.crop.circle") {
            AccountsSection()
        }
        // Title-bar Back and Go → Back also clear the selection / close search / go up a folder first.
        ShellCommands.backInterceptor = { FilesModel.shown?.handleBack() ?? false }
    }

    public static func start() {}

    public static func shutdown() {}
}
