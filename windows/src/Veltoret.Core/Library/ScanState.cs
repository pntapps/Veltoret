namespace Veltoret.Core.Library;

/// <summary>Progress of the running (or last) library scan. Immutable; the scanner replaces it with <c>with</c>.</summary>
public sealed record ScanState
{
    public bool Running { get; init; }
    public string Phase { get; init; } = "";
    public int FilesFound { get; init; }
    public int ToMatch { get; init; }
    /// <summary>Files looked up on TMDB so far in this scan (found or not).</summary>
    public int Matched { get; init; }
    public string? Error { get; init; }
    public long LastFinishedAt { get; init; }
    /// <summary>Library folders this scan covers; null means the whole library.</summary>
    public IReadOnlySet<long>? FolderIds { get; init; }
    public int FoldersTotal { get; init; }
    public int FoldersDone { get; init; }
    /// <summary>Folders this scan has finished reading.</summary>
    public IReadOnlySet<long> DoneFolderIds { get; init; } = new HashSet<long>();
    public long? CurrentFolderId { get; init; }
    public string CurrentFolder { get; init; } = "";
    /// <summary>Sub-folder being read, relative to the library folder ("Breaking Bad/Season 2").</summary>
    public string CurrentPath { get; init; } = "";
    public int NewFiles { get; init; }
    /// <summary>Files TMDB identified in this scan.</summary>
    public int Identified { get; init; }
    public bool Cancelled { get; init; }
    /// <summary>Why a folder couldn't be read in its latest scan, by folder id. Kept until that folder scans cleanly.</summary>
    public IReadOnlyDictionary<long, string> FolderErrors { get; init; } = new Dictionary<long, string>();

    public bool Covers(long folderId) => Running && (FolderIds == null || FolderIds.Contains(folderId));

    /// <summary>Part of the running scan but not read yet.</summary>
    public bool Waiting(long folderId) => Covers(folderId) && folderId != CurrentFolderId && !DoneFolderIds.Contains(folderId);

    /// <summary>Progress of the current step from 0 to 1, or null when it can't be measured yet.</summary>
    public float? Progress =>
        !Running ? null
        : ToMatch > 0 ? (float)Matched / ToMatch
        : FoldersTotal > 1 ? (float)FoldersDone / FoldersTotal
        : null;
}
