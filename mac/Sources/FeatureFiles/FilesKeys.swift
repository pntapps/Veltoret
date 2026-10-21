import AppKit
import VeltoretKit
import VeltoretUI

/// Keyboard and mouse handling of the Files page. The shell (`MainShell`) handles Back with an NSEvent local monitor;
/// AppKit calls the most recently added local monitor first, so this one (installed when the first Files page is
/// created, after the shell's) gets the first say while a Files page is shown:
///
/// - Esc / ⌘[ / mouse back button / two-finger swipe right: clear the selection → close search → up a folder; only
///   then the shell's Back runs (the event is passed on).
/// - ⌘F opens the Files search (this Drive / this folder) instead of the library Search.
/// - ⌘A select all, ⌘⌫ delete / move to trash, ⌥⌘⌫ delete permanently (Drive), Return rename (one selected),
///   ⌘↓ / ⌘O open, ⌘↑ enclosing folder, ⇧⌘N new folder, Space Quick Look (This Mac).
@MainActor
enum FilesKeys {
    nonisolated(unsafe) private static var monitor: Any?
    private static var swipeTracking = false

    static func install() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .scrollWheel]) { event in
            nonisolated(unsafe) let ev = event
            let consumed = MainActor.assumeIsolated { handle(ev) }
            return consumed ? nil : event
        }
    }

    private static func editingText(_ window: NSWindow) -> Bool {
        window.firstResponder is NSText || window.firstResponder is NSTextView
    }

    /// True when the event was handled (and must not reach the shell).
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === DialogHost.shared.shellWindow,
              DialogHost.shared.items.isEmpty, let model = FilesModel.shown else { return false }
        switch event.type {
        case .keyDown: return key(event, model, window)
        case .otherMouseDown: return event.buttonNumber == 3 && model.handleBack()
        case .scrollWheel: return swipe(event, model)
        default: return false
        }
    }

    private static func key(_ e: NSEvent, _ model: FilesModel, _ window: NSWindow) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let editing = editingText(window)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch e.keyCode {
        case 53 where mods.isEmpty: // Esc
            if editing {
                if model.searchQuery != nil { model.setSearch(nil); window.makeFirstResponder(nil); return true }
                return false
            }
            return model.handleBack()
        case 126 where mods == .command: // ⌘↑
            return !editing && model.goUp()
        case 125 where mods == .command: // ⌘↓
            guard !editing, model.selection.count == 1, let item = model.selectedItems.first else { return false }
            model.selection = []
            model.activate(item)
            return true
        case 51 where mods == .command, 117 where mods == .command: // ⌘⌫
            guard !editing, model.selecting, model.movable else { return false }
            model.trashSelection()
            return true
        case 51 where mods == [.command, .option], 117 where mods == [.command, .option]: // ⌥⌘⌫
            guard !editing, model.selecting, model.isDrive, model.movable, model.selectedItems.allSatisfy(\.canDelete) else { return false }
            model.deleteSelectionForever()
            return true
        case 36 where mods.isEmpty, 76 where mods.isEmpty: // Return
            guard !editing, model.selection.count == 1 else { return false }
            model.renameSelection()
            return true
        case 49 where mods.isEmpty: // Space
            guard !editing else { return false }
            return model.toggleQuickLook()
        default: break
        }
        if mods == .command {
            switch ch {
            case "[": return model.handleBack()
            case "f":
                guard model.account != nil else { return false }
                if model.searchQuery == nil { model.setSearch("") } else { model.setSearch(model.searchQuery) }
                return true
            case "a":
                guard !editing, !model.items.isEmpty else { return false }
                model.selectAll()
                return true
            case "o":
                guard !editing, model.selection.count == 1, let item = model.selectedItems.first else { return false }
                model.selection = []
                model.activate(item)
                return true
            default: return false
            }
        }
        if mods == [.command, .shift], ch == "n", !editing, model.showsAddButton, !(model.isLocal && model.stack.count == 1) {
            model.newFolder()
            return true
        }
        return false
    }

    /// Two-finger swipe right: the Files page's Back first (same rules as Esc).
    private static func swipe(_ e: NSEvent, _ model: FilesModel) -> Bool {
        guard e.phase == .began, !swipeTracking, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), e.scrollingDeltaX > 0 else { return false }
        guard model.selecting || model.searchQuery != nil || model.stack.count > 1 else { return false }
        swipeTracking = true
        e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: 0, max: 1) { amount, phase, complete, _ in
            if complete || phase == .ended || phase == .cancelled {
                Task { @MainActor in
                    swipeTracking = false
                    if complete && amount >= 1 { _ = FilesModel.shown?.handleBack() }
                }
            }
        }
        return true
    }
}
