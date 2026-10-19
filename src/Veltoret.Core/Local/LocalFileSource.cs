using System.Runtime.InteropServices;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Local;

/// <summary>
/// "This PC": folders and files on this computer's drives, for account <see cref="Accounts.Device"/>. The top level
/// (<see cref="Root"/>) lists the ready fixed and removable drives; every other id is a full local path.
/// Deleting sends items to the Recycle Bin (the Windows convention).
/// </summary>
public sealed class LocalFileSource : IFileSource
{
    public const string Root = "device-root";
    public const string FolderMime = "application/vnd.google-apps.folder";

    private const string FolderUnavailable =
        "This folder isn't available. If it's on an external or USB drive, make sure it's connected.";

    public bool Handles(string account) => Accounts.IsLocal(account);

    public string RootId(string account) => Root;

    public string RootName(string account) => Accounts.DeviceDisplayName;

    /// <summary>Full path without a trailing separator (drive roots keep theirs: "C:\").</summary>
    public static string Normalize(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full);
        if (root != null && string.Equals(full.TrimEnd('\\', '/'), root.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))
            return root.EndsWith('\\') ? root : root + "\\";
        return full.TrimEnd('\\', '/');
    }

    public Task<List<StorageItem>> List(string account, string folderId, CancellationToken ct = default) =>
        Task.Run(() => ListSync(folderId, ct), ct);

    private static List<StorageItem> ListSync(string folderId, CancellationToken ct)
    {
        if (folderId == Root) return Drives();
        var dir = new DirectoryInfo(Normalize(folderId));
        if (!dir.Exists) throw new DirectoryNotFoundException(FolderUnavailable);
        var options = new EnumerationOptions
        {
            IgnoreInaccessible = true,
            RecurseSubdirectories = false,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
            ReturnSpecialDirectories = false,
        };
        var items = new List<StorageItem>();
        foreach (var info in dir.EnumerateFileSystemInfos("*", options))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                items.Add(ToItem(info, dir.FullName));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return items
            .OrderByDescending(i => i.IsFolder)
            .ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    private static List<StorageItem> Drives()
    {
        var list = new List<StorageItem>();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady || (d.DriveType != DriveType.Fixed && d.DriveType != DriveType.Removable)) continue;
                list.Add(new StorageItem
                {
                    Id = d.RootDirectory.FullName,
                    Name = DriveName(d),
                    MimeType = FolderMime,
                    IsFolder = true,
                    Parents = new[] { Root },
                    CanRename = false,
                    CanTrash = false,
                    CanDelete = false,
                    CanAddChildren = true,
                });
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return list;
    }

    /// <summary>"Data (D:)", or "Local Disk (C:)" when the drive has no label.</summary>
    public static string DriveName(DriveInfo d)
    {
        var letter = d.Name.TrimEnd('\\');
        string label;
        try { label = d.VolumeLabel; }
        catch { label = ""; }
        if (string.IsNullOrWhiteSpace(label)) label = d.DriveType == DriveType.Removable ? "USB Drive" : "Local Disk";
        return $"{label} ({letter})";
    }

    private static StorageItem ToItem(FileSystemInfo info, string parent)
    {
        var readOnly = info.Attributes.HasFlag(FileAttributes.ReadOnly) && info is FileInfo;
        if (info is DirectoryInfo)
        {
            return new StorageItem
            {
                Id = info.FullName,
                Name = info.Name,
                MimeType = FolderMime,
                IsFolder = true,
                ModifiedTime = Iso(info.LastWriteTimeUtc),
                Parents = new[] { parent },
                CanRename = true,
                CanTrash = true,
                CanDelete = true,
                CanAddChildren = true,
            };
        }
        var file = (FileInfo)info;
        return new StorageItem
        {
            Id = file.FullName,
            Name = file.Name,
            MimeType = MimeTypes.ForName(file.Name),
            IsFolder = false,
            SizeBytes = file.Length,
            ModifiedTime = Iso(file.LastWriteTimeUtc),
            Parents = new[] { parent },
            CanRename = !readOnly,
            CanTrash = !readOnly,
            CanDelete = !readOnly,
            CanAddChildren = false,
        };
    }

    private static string Iso(DateTime utc) => utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture);

    public async Task<List<StorageItem>> Search(string account, string query, string currentFolder, CancellationToken ct = default)
    {
        var items = await List(account, currentFolder, ct).ConfigureAwait(false);
        return items.Where(i => i.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    public Task<string> Rename(string account, string id, string newName, CancellationToken ct = default) => Task.Run(() =>
    {
        var name = newName.Trim();
        CheckName(name);
        var path = Normalize(id);
        var parent = Path.GetDirectoryName(path) ?? throw new IOException("This item can't be renamed");
        var target = Path.Combine(parent, name);
        if (string.Equals(path, target, StringComparison.Ordinal)) return path;
        var caseOnly = string.Equals(path, target, StringComparison.OrdinalIgnoreCase);
        if (Directory.Exists(path))
        {
            if (!caseOnly && (Directory.Exists(target) || File.Exists(target))) throw new IOException($"There's already something named \"{name}\" here");
            if (caseOnly)
            {
                // Windows needs a detour for a case-only folder rename.
                var temp = path + ".rename-" + Guid.NewGuid().ToString("N")[..6];
                Directory.Move(path, temp);
                Directory.Move(temp, target);
            }
            else Directory.Move(path, target);
        }
        else if (File.Exists(path))
        {
            if (!caseOnly && (Directory.Exists(target) || File.Exists(target))) throw new IOException($"There's already something named \"{name}\" here");
            File.Move(path, target);
        }
        else throw new FileNotFoundException("This file isn't available");
        return target;
    }, ct);

    private static void CheckName(string name)
    {
        if (name.Length == 0 || name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.EndsWith('.'))
            throw new IOException("That name can't be used on Windows");
    }

    /// <summary>To the Recycle Bin.</summary>
    public Task Remove(string account, string id, CancellationToken ct = default) => Task.Run(() => Recycle(Normalize(id)), ct);

    /// <summary>Also to the Recycle Bin on this PC (see CLAUDE.md product decisions).</summary>
    public Task DeletePermanently(string account, string id, CancellationToken ct = default) => Remove(account, id, ct);

    public Task<StorageSpace?> Space(string account, string folderId, CancellationToken ct = default) => Task.Run(() =>
    {
        if (folderId == Root) return null;
        try
        {
            var root = Path.GetPathRoot(Normalize(folderId));
            if (string.IsNullOrEmpty(root)) return null;
            var d = new DriveInfo(root);
            if (!d.IsReady) return null;
            var total = d.TotalSize;
            var free = d.AvailableFreeSpace;
            return (StorageSpace?)new StorageSpace(DriveName(d), Math.Max(0, total - free), total, free);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }, ct);

    public string? SpaceKey(string account, string folderId)
    {
        if (folderId == Root) return null;
        try { return Path.GetPathRoot(Normalize(folderId))?.ToUpperInvariant(); }
        catch { return null; }
    }

    public Task Move(string account, string id, string? fromParent, string toParent, CancellationToken ct = default) => Task.Run(() =>
    {
        if (toParent == Root) throw new IOException("Choose a folder on a drive");
        var path = Normalize(id);
        var dest = Path.Combine(Normalize(toParent), Path.GetFileName(path));
        if (string.Equals(path, dest, StringComparison.OrdinalIgnoreCase)) return;
        if (File.Exists(dest) || Directory.Exists(dest)) throw new IOException($"There's already something named \"{Path.GetFileName(path)}\" there");
        if (Directory.Exists(path))
        {
            if (dest.StartsWith(path + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException("A folder can't be moved into itself");
            try
            {
                Directory.Move(path, dest);
            }
            catch (IOException) when (!string.Equals(Path.GetPathRoot(path), Path.GetPathRoot(dest), StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("This storage doesn't support moving files between these folders");
            }
        }
        else if (File.Exists(path)) File.Move(path, dest);
        else throw new FileNotFoundException("This file isn't available");
    }, ct);

    public Task CreateFolder(string account, string parentId, string name, CancellationToken ct = default) => Task.Run(() =>
    {
        var clean = name.Trim();
        if (parentId == Root) throw new IOException("Couldn't create the folder here");
        CheckName(clean);
        var target = Path.Combine(Normalize(parentId), clean);
        if (Directory.Exists(target) || File.Exists(target)) throw new IOException($"There's already something named \"{clean}\" here");
        try
        {
            Directory.CreateDirectory(target);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new IOException("Couldn't create the folder here", e);
        }
    }, ct);

    public Task<Stream> OpenRead(string account, string id, CancellationToken ct = default)
    {
        try
        {
            Stream s = new FileStream(Normalize(id), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            return Task.FromResult(s);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            throw new FileNotFoundException("This file isn't available", e);
        }
    }

    // ---- Recycle Bin (SHFileOperation with FOF_ALLOWUNDO) ----

    private const uint FO_DELETE = 0x0003;
    private const ushort FOF_SILENT = 0x0004;
    private const ushort FOF_NOCONFIRMATION = 0x0010;
    private const ushort FOF_ALLOWUNDO = 0x0040;
    private const ushort FOF_NOERRORUI = 0x0400;
    private const ushort FOF_WANTNUKEWARNING = 0x4000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT64
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 1)]
    private struct SHFILEOPSTRUCT32
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHFileOperationW")]
    private static extern int SHFileOperation64(ref SHFILEOPSTRUCT64 op);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHFileOperationW")]
    private static extern int SHFileOperation32(ref SHFILEOPSTRUCT32 op);

    private static void Recycle(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) throw new FileNotFoundException("This file isn't available");
        // Without FOF_WANTNUKEWARNING the shell would silently delete items too big for the bin (or on drives
        // without one); with FOF_NOCONFIRMATION it still deletes, which matches "Remove".
        var flags = (ushort)(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI);
        int result;
        bool aborted;
        if (IntPtr.Size == 8)
        {
            var op = new SHFILEOPSTRUCT64 { wFunc = FO_DELETE, pFrom = path + "\0\0", fFlags = flags };
            result = SHFileOperation64(ref op);
            aborted = op.fAnyOperationsAborted != 0;
        }
        else
        {
            var op = new SHFILEOPSTRUCT32 { wFunc = FO_DELETE, pFrom = path + "\0\0", fFlags = flags };
            result = SHFileOperation32(ref op);
            aborted = op.fAnyOperationsAborted != 0;
        }
        if (result != 0 || aborted || File.Exists(path) || Directory.Exists(path)) throw new IOException("Couldn't delete it");
    }
}

/// <summary>MIME types for local and network files, from the extension (Drive sends its own).</summary>
public static class MimeTypes
{
    private static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        ["mkv"] = "video/x-matroska", ["mp4"] = "video/mp4", ["m4v"] = "video/x-m4v", ["avi"] = "video/x-msvideo",
        ["mov"] = "video/quicktime", ["wmv"] = "video/x-ms-wmv", ["flv"] = "video/x-flv", ["webm"] = "video/webm",
        ["ts"] = "video/mp2t", ["m2ts"] = "video/mp2t", ["mts"] = "video/mp2t", ["mpg"] = "video/mpeg", ["mpeg"] = "video/mpeg",
        ["3gp"] = "video/3gpp", ["ogv"] = "video/ogg", ["vob"] = "video/dvd", ["divx"] = "video/divx", ["rmvb"] = "application/vnd.rn-realmedia-vbr",
        ["asf"] = "video/x-ms-asf", ["f4v"] = "video/x-f4v", ["mxf"] = "application/mxf",
        ["srt"] = "application/x-subrip", ["vtt"] = "text/vtt", ["ass"] = "text/x-ssa", ["ssa"] = "text/x-ssa",
        ["ttml"] = "application/ttml+xml", ["dfxp"] = "application/ttml+xml",
        ["zip"] = "application/zip", ["rar"] = "application/vnd.rar", ["7z"] = "application/x-7z-compressed",
        ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif", ["webp"] = "image/webp", ["bmp"] = "image/bmp",
        ["mp3"] = "audio/mpeg", ["m4a"] = "audio/mp4", ["aac"] = "audio/aac", ["flac"] = "audio/flac", ["wav"] = "audio/wav", ["ogg"] = "audio/ogg", ["opus"] = "audio/opus",
        ["txt"] = "text/plain", ["nfo"] = "text/plain", ["pdf"] = "application/pdf", ["json"] = "application/json",
    };

    public static string ForName(string name)
    {
        var ext = Path.GetExtension(name).TrimStart('.');
        return Map.TryGetValue(ext, out var mime) ? mime : "application/octet-stream";
    }
}
