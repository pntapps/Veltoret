using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Plans;

namespace Veltoret.App.Pages.Settings;

/// <summary>What Settings says about scans (Android: ui/settings/ScanText.kt), word for word.</summary>
public static class ScanText
{
    public static string Videos(int n) => n == 1 ? "1 video" : $"{n} videos";

    public static string Title(ScanState s) =>
        s.FolderIds == null ? "Scanning your library"
        : s.CurrentFolder != "" ? $"Scanning {s.CurrentFolder}"
        : "Scanning folder";

    public static string Step(ScanState s)
    {
        if (s.ToMatch > 0) return $"Matching with TMDB · {s.Matched} of {s.ToMatch}";
        if (s.CurrentFolder != "" && s.FoldersTotal > 1)
            return $"Reading {s.CurrentFolder} · folder {Math.Min(s.FoldersDone + 1, s.FoldersTotal)} of {s.FoldersTotal}";
        if (s.CurrentFolder != "") return $"Reading {s.CurrentFolder}";
        return string.IsNullOrWhiteSpace(s.Phase) ? "Starting" : s.Phase;
    }

    public static string Counts(ScanState s)
    {
        var parts = new List<string> { Videos(s.FilesFound) };
        if (s.NewFiles > 0) parts.Add($"{s.NewFiles} new");
        if (s.Identified > 0) parts.Add($"{s.Identified} identified");
        return string.Join(" · ", parts);
    }

    private static string Rel(long t) => PlanFormat.Relative(t).ToLowerInvariant();

    public static string Idle(ScanState s, long lastScanAt)
    {
        var broken = s.FolderErrors.Count;
        if (broken > 0) return $"{broken} {(broken == 1 ? "folder" : "folders")} couldn't be read. Details are under Sources.";
        if (s.Cancelled) return $"Last scan was cancelled {Rel(s.LastFinishedAt)}";
        if (s.Error != null) return $"Last scan had a problem: {s.Error}";
        if (s.LastFinishedAt > 0)
        {
            var what = s.FolderIds == null ? "Last scan" : s.FolderIds.Count == 1 ? "Folder scan" : $"Scan of {s.FolderIds.Count} folders";
            return $"{what} {Rel(s.LastFinishedAt)}: {Counts(s)}";
        }
        return $"Last scanned {Rel(lastScanAt)}";
    }

    public static string Folder(LibraryFolderEntity folder, int count, ScanState s)
    {
        if (s.Running && s.CurrentFolderId == folder.Id) return $"Scanning… {(s.CurrentPath != "" ? s.CurrentPath : "top folder")}";
        if (s.FolderErrors.TryGetValue(folder.Id, out var error)) return error;
        if (s.Waiting(folder.Id)) return $"{Videos(count)} · waiting to scan";
        if (folder.LastScannedAt <= 0) return "Not scanned yet";
        return $"{Videos(count)} · scanned {Rel(folder.LastScannedAt)}";
    }
}
