import AppKit
import Foundation

/// Calls back when the Mac wakes from sleep (NSWorkspace.didWakeNotification) or the system clock / time zone
/// changes (NSSystemClockDidChange, NSSystemTimeZoneDidChange). Reminders are restored on each.
/// Only `VeltoretPlansModule.start()` creates one, so tests never touch AppKit.
public final class SystemChangeMonitor {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(_ onChange: @escaping @Sendable () -> Void) {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in onChange() }))
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            tokens.append((nc, nc.addObserver(forName: name, object: nil, queue: nil) { _ in onChange() }))
        }
    }

    public func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    deinit { stop() }
}
