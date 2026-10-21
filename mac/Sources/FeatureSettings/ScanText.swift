import Foundation
import VeltoretKit
import VeltoretPlans

/// What Settings (and the menu bar item) say about scans (Android ui/settings/ScanText.kt, Windows ScanText), word for word.
public enum ScanText {
    public static func videos(_ n: Int) -> String { n == 1 ? "1 video" : "\(n) videos" }

    public static func title(_ s: ScanState) -> String {
        if s.folderIds == nil { return "Scanning your library" }
        return s.currentFolder != "" ? "Scanning \(s.currentFolder)" : "Scanning folder"
    }

    public static func step(_ s: ScanState) -> String {
        if s.toMatch > 0 { return "Matching with TMDB · \(s.matched) of \(s.toMatch)" }
        if s.currentFolder != "" && s.foldersTotal > 1 {
            return "Reading \(s.currentFolder) · folder \(min(s.foldersDone + 1, s.foldersTotal)) of \(s.foldersTotal)"
        }
        if s.currentFolder != "" { return "Reading \(s.currentFolder)" }
        return s.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Starting" : s.phase
    }

    public static func counts(_ s: ScanState) -> String {
        var parts = [videos(s.filesFound)]
        if s.newFiles > 0 { parts.append("\(s.newFiles) new") }
        if s.identified > 0 { parts.append("\(s.identified) identified") }
        return parts.joined(separator: " · ")
    }

    private static func rel(_ t: Int64) -> String { PlanFormat.relative(t).lowercased(with: Locale(identifier: "en_US")) }

    public static func idle(_ s: ScanState, lastScanAt: Int64) -> String {
        let broken = s.folderErrors.count
        if broken > 0 { return "\(broken) \(broken == 1 ? "folder" : "folders") couldn't be read. Details are under Library." }
        if s.cancelled { return "Last scan was cancelled \(rel(s.lastFinishedAt))" }
        if let e = s.error { return "Last scan had a problem: \(e)" }
        if s.lastFinishedAt > 0 {
            let what: String
            if let ids = s.folderIds { what = ids.count == 1 ? "Folder scan" : "Scan of \(ids.count) folders" } else { what = "Last scan" }
            return "\(what) \(rel(s.lastFinishedAt)): \(counts(s))"
        }
        return "Last scanned \(rel(lastScanAt))"
    }

    public static func folder(_ folder: LibraryFolderEntity, count: Int, _ s: ScanState) -> String {
        if s.running && s.currentFolderId == folder.id { return "Scanning… \(s.currentPath != "" ? s.currentPath : "top folder")" }
        if let error = s.folderErrors[folder.id] { return error }
        if s.waiting(folder.id) { return "\(videos(count)) · waiting to scan" }
        if folder.lastScannedAt <= 0 { return "Not scanned yet" }
        return "\(videos(count)) · scanned \(rel(folder.lastScannedAt))"
    }

    /// One short line for the menu bar item: "Scanning your library · 42%".
    public static func menuLine(_ s: ScanState) -> String {
        guard s.running else { return "" }
        if let p = s.progress { return "\(title(s)) · \(Int((Double(p) * 100).rounded()))%" }
        return "\(title(s)) · \(counts(s))"
    }
}
