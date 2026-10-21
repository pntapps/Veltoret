import AppKit

// Veltoret for Mac. AppKit lifecycle (not SwiftUI App) so the app can keep running without windows (menu bar
// item), open at login hidden, and own its menus; the window content is SwiftUI (VeltoretUI.MainShell).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
