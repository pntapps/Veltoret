import AppKit
import Foundation
import ServiceManagement
import VeltoretKit

/// "Open at login" (Windows StartupRegistration): registers the app itself as a login item with SMAppService.
public enum LoginItem {
    /// Login items need a real app bundle.
    static var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// True when macOS will open Veltoret at login (or is waiting for the user to approve it in System Settings).
    public static var isEnabled: Bool {
        guard isSupported else { return false }
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    /// Waiting for approval in System Settings → General → Login Items.
    public static var needsApproval: Bool { isSupported && SMAppService.mainApp.status == .requiresApproval }

    /// Turns opening at login on or off; false when macOS refused.
    @discardableResult
    public static func set(_ on: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.error(error, on ? "Registering the login item" : "Removing the login item")
            return false
        }
    }

    /// At start: the setting follows what macOS says (the user may have removed it in System Settings). A setting
    /// that's on while the app isn't registered (moved / reinstalled) registers again.
    public static func sync() {
        guard isSupported, let settings = AppServices.settings else { return }
        let wanted = settings.current.startAtLogin
        let status = SMAppService.mainApp.status
        if wanted && status == .notRegistered {
            if !set(true) { settings.update { $0.startAtLogin = false } }
            return
        }
        let actual = status == .enabled || status == .requiresApproval
        if actual != wanted { settings.update { $0.startAtLogin = actual } }
    }

    /// True when this process was launched as a login item (the app target can then stay in the menu bar
    /// without showing its window). Read it in `applicationWillFinishLaunching` / `DidFinishLaunching`.
    @MainActor
    public static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
