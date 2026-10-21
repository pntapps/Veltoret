import AppKit
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// macOS firewall hint (Windows CastFirewall). The TV fetches the video from this Mac, so incoming connections must be
/// allowed; with the Application Firewall on and Veltoret denied (or asked once and the user said no) macOS blocks
/// them silently. When the receiver never reaches the cast server, once per run: if the firewall is off, a toast
/// about the network; otherwise a dialog that opens System Settings → Network → Firewall.
@MainActor
public enum CastFirewall {
    private static var offered = false
    private static var subscription: Subscription?

    /// Settings URLs, newest first (macOS 13+ moved Firewall under Network).
    static let settingsUrls = [
        "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
        "x-apple.systempreferences:com.apple.preference.security?Firewall",
    ]

    /// Starts watching `AppServices.cast.receiverUnreachable` (idempotent).
    public static func watch() {
        guard subscription == nil, let cast = AppServices.cast else { return }
        subscription = cast.receiverUnreachable.subscribe { Task { @MainActor in await offer() } }
    }

    static func offer() async {
        if offered { return }
        offered = true
        if await firewallEnabled() == false {
            Toast.show("The TV couldn't reach this Mac. Check that both are on the same network, with no VPN or guest Wi-Fi between them, and try again.")
            return
        }
        let open = await Dialogs.confirm(
            title: "Let the TV reach this Mac?",
            message: "The TV couldn't load the video from this Mac. macOS may be blocking incoming connections — allow Veltoret in System Settings → Network → Firewall, then try casting again.",
            confirm: "Open Firewall settings", cancel: "Not now")
        if open { openSettings() }
    }

    public static func openSettings() {
        for s in settingsUrls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// The Application Firewall's global state (`socketfilterfw --getglobalstate` needs no admin rights);
    /// nil when it can't be read.
    static func firewallEnabled() async -> Bool? {
        await Task.detached { () -> Bool? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
            p.arguments = ["--getglobalstate"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = (String(data: data, encoding: .utf8) ?? "").lowercased()
            if text.contains("disabled") || text.contains("state = 0") { return false }
            if text.contains("enabled") || text.contains("state = 1") || text.contains("state = 2") { return true }
            return nil
        }.value
    }
}
