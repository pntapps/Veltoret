// swift-tools-version: 6.0
// Veltoret for Mac. Build with `swift build`; package a runnable app with `Scripts/build-app.sh`.
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Veltoret",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Veltoret", targets: ["Veltoret"]),
    ],
    dependencies: [
        // SMB2/3 client (libsmb2), LGPL-2.1: network shares.
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.3"),
    ],
    targets: [
        // LibVLC for macOS (VLCKit, LGPL-2.1). Not committed: Scripts/fetch-vlckit.sh downloads it.
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),

        // ---- Logic (no UI). Everything testable lives here. ----
        // Shared foundation (Data, Storage, Settings, Util, Services) + core (Library, Tmdb, Local, Net, Images).
        .target(name: "VeltoretKit", swiftSettings: swift5,
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // Player logic without VLC: media formats, subtitles, HDR probe, track memory, episode navigation.
        .target(name: "VeltoretPlayerKit", dependencies: ["VeltoretKit"], swiftSettings: swift5),
        // Google sign-in (loopback + PKCE), Drive REST, uploads, ZIP extraction.
        .target(name: "VeltoretDrive", dependencies: ["VeltoretKit"], swiftSettings: swift5),
        // SMB file source, discovery, server store.
        .target(name: "VeltoretSmb", dependencies: ["VeltoretKit", .product(name: "AMSMB2", package: "AMSMB2")],
                swiftSettings: swift5),
        // Chromecast (Cast v2), Play on TV client, pairing crypto, cast stream server.
        .target(name: "VeltoretCast", dependencies: ["VeltoretKit", "VeltoretPlayerKit"], swiftSettings: swift5),
        // Watchlist, reminders, upcoming episodes, VoiceQuery.
        .target(name: "VeltoretPlans", dependencies: ["VeltoretKit"], swiftSettings: swift5),

        // ---- UI (SwiftUI + AppKit) ----
        // Design system: tokens, fonts, shared components, navigation, dialogs, toasts.
        .target(name: "VeltoretUI", dependencies: ["VeltoretKit"],
                resources: [.copy("Resources/Fonts")], swiftSettings: swift5),
        // Home, Movies, TV Shows, Search, details, collections, Fix match, onboarding.
        .target(name: "FeatureLibrary", dependencies: ["VeltoretUI", "VeltoretKit", "VeltoretPlans", "VeltoretPlayerKit"],
                swiftSettings: swift5),
        // The player window (VLCKit).
        .target(name: "FeaturePlayer", dependencies: ["VeltoretUI", "VeltoretKit", "VeltoretPlayerKit", "VLCKit"],
                swiftSettings: swift5),
        // Files manager, Archives, Google accounts UI.
        .target(name: "FeatureFiles", dependencies: ["VeltoretUI", "VeltoretKit", "VeltoretDrive"], swiftSettings: swift5),
        // Add network server, network servers section, Cast / Play on TV UI.
        .target(name: "FeatureNetwork", dependencies: ["VeltoretUI", "VeltoretKit", "VeltoretSmb", "VeltoretCast", "VeltoretPlayerKit"],
                swiftSettings: swift5),
        // Settings page, reminder dialog, notifications, menu bar item, voice search.
        .target(name: "FeatureSettings", dependencies: ["VeltoretUI", "VeltoretKit", "VeltoretPlans"], swiftSettings: swift5),

        // The app: wiring (AppServices init), main window, menus.
        .executableTarget(
            name: "Veltoret",
            dependencies: ["VeltoretKit", "VeltoretPlayerKit", "VeltoretDrive", "VeltoretSmb", "VeltoretCast", "VeltoretPlans",
                           "VeltoretUI", "FeatureLibrary", "FeaturePlayer", "FeatureFiles", "FeatureNetwork", "FeatureSettings"],
            swiftSettings: swift5,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),

        // ---- Tests (ported one for one from the Windows/Android unit tests) ----
        .testTarget(name: "VeltoretKitTests", dependencies: ["VeltoretKit"], swiftSettings: swift5),
        .testTarget(name: "VeltoretPlayerKitTests", dependencies: ["VeltoretPlayerKit"], swiftSettings: swift5),
        .testTarget(name: "VeltoretDriveTests", dependencies: ["VeltoretDrive"], swiftSettings: swift5),
        .testTarget(name: "VeltoretSmbTests", dependencies: ["VeltoretSmb"], swiftSettings: swift5),
        .testTarget(name: "VeltoretCastTests", dependencies: ["VeltoretCast"], swiftSettings: swift5),
        .testTarget(name: "VeltoretPlansTests", dependencies: ["VeltoretPlans"], swiftSettings: swift5),
    ]
)
