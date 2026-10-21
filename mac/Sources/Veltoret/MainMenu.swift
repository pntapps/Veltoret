import AppKit
import VeltoretKit
import VeltoretUI
import FeaturePlayer

/// The menu bar (Windows has none; these are the Mac-standard menus plus Veltoret's commands and shortcuts).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Veltoret")
        appMenu.addItem(withTitle: "About Veltoret", action: #selector(MenuActions.about), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(MenuActions.settings), keyEquivalent: ",").target = MenuActions.shared
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Veltoret", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Veltoret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open Video…", action: #selector(MenuActions.openVideo), keyEquivalent: "o").target = MenuActions.shared
        file.addItem(withTitle: "Add Folder to Library…", action: #selector(MenuActions.addFolder), keyEquivalent: "O").target = MenuActions.shared
        file.addItem(.separator())
        file.addItem(withTitle: "Scan Library", action: #selector(MenuActions.scan), keyEquivalent: "r").target = MenuActions.shared
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(MenuActions.search), keyEquivalent: "f").target = MenuActions.shared
        add(edit, to: main)

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(MenuActions.back), keyEquivalent: "[").target = MenuActions.shared
        go.addItem(.separator())
        for (i, tab) in RailTab.all.enumerated() {
            let item = go.addItem(withTitle: tab.label, action: #selector(MenuActions.tab(_:)), keyEquivalent: "\(i + 1)")
            item.tag = i
            item.target = MenuActions.shared
        }
        go.addItem(.separator())
        go.addItem(withTitle: "Needs a Match", action: #selector(MenuActions.needsMatch), keyEquivalent: "").target = MenuActions.shared
        add(go, to: main)

        let view = NSMenu(title: "View")
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        add(view, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Veltoret", action: #selector(MenuActions.showMain), keyEquivalent: "0").target = MenuActions.shared
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Setup Guide", action: #selector(MenuActions.setupGuide), keyEquivalent: "?").target = MenuActions.shared
        help.addItem(withTitle: "Veltoret on GitHub", action: #selector(MenuActions.github), keyEquivalent: "").target = MenuActions.shared
        add(help, to: main)
        NSApp.helpMenu = help

        // The player adds its own Playback menu (FeaturePlayer) through AppWiring.
        AppWiring.extendMenu(main)
        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    @objc func about() { app?.showMainWindow(); AppServices.navigate(.settings) }
    @objc func settings() { app?.showMainWindow(); AppServices.navigate(.settings) }
    @objc func showMain() { app?.showMainWindow() }
    @objc func back() { _ = ShellCommands.goBack() }
    @objc func tab(_ sender: NSMenuItem) { app?.showMainWindow(); ShellCommands.selectTab(sender.tag) }
    @objc func search() { app?.showMainWindow(); ShellCommands.openSearch() }
    @objc func needsMatch() { app?.showMainWindow(); AppServices.navigate(.fixMatch()) }

    @objc func scan() {
        Task { await AppServices.scans.runNow() }
        Toast.show("Scanning your library…")
    }

    @objc func addFolder() {
        app?.showMainWindow()
        Task { @MainActor in
            guard let f = await FolderPicker.pickLibraryFolder(account: Accounts.device) else { return }
            do {
                if let id = try AppServices.library.addFolder(account: Accounts.device, folderId: f.id, name: f.name, type: f.type) {
                    Task { await AppServices.scans.runNow([id]) }
                } else {
                    Toast.show("That folder is already in your library")
                }
            } catch {
                Toast.show("Couldn't add the folder")
                Log.error(error, "Add folder")
            }
        }
    }

    @objc func openVideo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VeltoretPlaybackLauncher.openLocalFile(url)
    }

    @objc func setupGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/pntapps/Veltoret/blob/main/mac/docs/SETUP.md")!)
    }

    @objc func github() {
        NSWorkspace.shared.open(URL(string: "https://github.com/pntapps/Veltoret")!)
    }
}
