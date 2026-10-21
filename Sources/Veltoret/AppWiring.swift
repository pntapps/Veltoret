import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI
import FeatureLibrary

/// Connects feature modules that can't import each other (hooks filled with the other modules' APIs).
@MainActor
enum AppWiring {
    static func connectModules() {
        // Filled in once the feature modules land (LibraryHooks, player ↔ cast bridge, notifications…).
    }

    static func extendMenu(_ main: NSMenu) {}
}
