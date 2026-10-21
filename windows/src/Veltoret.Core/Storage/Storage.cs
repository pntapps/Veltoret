namespace Veltoret.Core.Storage;

/// <summary>
/// One file or folder from any source (the Android app's DriveFile). <see cref="Id"/> is a Drive file id,
/// a local path, or smb://host/share/path.
/// </summary>
public sealed record StorageItem
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string MimeType { get; init; } = "";
    public bool IsFolder { get; init; }
    public long SizeBytes { get; init; }
    /// <summary>RFC 3339, as Drive sends it.</summary>
    public string? ModifiedTime { get; init; }
    public IReadOnlyList<string> Parents { get; init; } = Array.Empty<string>();
    public int? Width { get; init; }
    public int? Height { get; init; }
    public long? DurationMs { get; init; }
    public bool CanRename { get; init; } = true;
    public bool CanTrash { get; init; } = true;
    /// <summary>Drive: only the owner may delete permanently.</summary>
    public bool CanDelete { get; init; }
    public bool CanAddChildren { get; init; } = true;
}

/// <summary>
/// Space where a folder lives: the Google account's storage, the disk or the shared folder.
/// Total and Free are null when unknown or unlimited (some Google Workspace accounts).
/// </summary>
public sealed record StorageSpace(string Name, long Used, long? Total, long? Free);

/// <summary>
/// One kind of source: Google Drive, folders on this PC, or SMB network shares. Registered with <see cref="Storage"/>.
/// </summary>
public interface IFileSource
{
    /// <summary>True for the accounts this source serves (an email, <see cref="Accounts.Device"/>, or "smb://host").</summary>
    bool Handles(string account);
    string RootId(string account);
    string RootName(string account);
    Task<List<StorageItem>> List(string account, string folderId, CancellationToken ct = default);
    /// <summary>Drive searches the whole account; local and network sources filter <paramref name="currentFolder"/>.</summary>
    Task<List<StorageItem>> Search(string account, string query, string currentFolder, CancellationToken ct = default);
    /// <summary>Returns the item's id afterwards (it changes for local and SMB files).</summary>
    Task<string> Rename(string account, string id, string newName, CancellationToken ct = default);
    /// <summary>Drive: to trash (recoverable). This PC and network servers: deleted permanently.</summary>
    Task Remove(string account, string id, CancellationToken ct = default);
    /// <summary>Skips Drive's trash (owner only; a folder goes with everything in it). Others: same as Remove.</summary>
    Task DeletePermanently(string account, string id, CancellationToken ct = default);
    Task<StorageSpace?> Space(string account, string folderId, CancellationToken ct = default);
    /// <summary>Folders with the same key have the same space, so browsing between them needn't ask again.</summary>
    string? SpaceKey(string account, string folderId);
    Task Move(string account, string id, string? fromParent, string toParent, CancellationToken ct = default);
    Task CreateFolder(string account, string parentId, string name, CancellationToken ct = default);
    /// <summary>
    /// A readable stream for the file. For media it must be seekable (the player streams through it: Drive and
    /// SMB return range-reading streams).
    /// </summary>
    Task<Stream> OpenRead(string account, string id, CancellationToken ct = default);
}

public static class Accounts
{
    /// <summary>Pseudo-account for folders on this PC (Android: LocalStorage.ACCOUNT).</summary>
    public const string Device = "device";
    public const string DeviceDisplayName = "This PC";

    public static bool IsLocal(string? account) => account == Device;
    public static bool IsSmb(string? account) => account != null && account.StartsWith("smb://", StringComparison.OrdinalIgnoreCase);
    public static bool IsDrive(string? account) => account != null && !IsLocal(account) && !IsSmb(account);
}

/// <summary>
/// One front door for every file source. Code that must work for every source goes through here; check
/// <see cref="IsLocal"/> / <see cref="IsSmb"/> instead of assuming Drive.
/// </summary>
public sealed class Storage
{
    private readonly List<IFileSource> _sources = new();

    public void Register(IFileSource source) => _sources.Add(source);

    public bool IsLocal(string? account) => Accounts.IsLocal(account);
    public bool IsSmb(string? account) => Accounts.IsSmb(account);

    public IFileSource SourceFor(string account) =>
        _sources.FirstOrDefault(s => s.Handles(account))
        ?? throw new InvalidOperationException($"No file source for {account}");

    public string RootId(string account) => SourceFor(account).RootId(account);
    public string RootName(string account) => SourceFor(account).RootName(account);

    public Task<List<StorageItem>> List(string account, string folderId, CancellationToken ct = default) =>
        SourceFor(account).List(account, folderId, ct);

    public Task<List<StorageItem>> Search(string account, string query, string currentFolder, CancellationToken ct = default) =>
        SourceFor(account).Search(account, query, currentFolder, ct);

    public Task<string> Rename(string account, string id, string newName, CancellationToken ct = default) =>
        SourceFor(account).Rename(account, id, newName, ct);

    public Task Remove(string account, string id, CancellationToken ct = default) => SourceFor(account).Remove(account, id, ct);

    public Task DeletePermanently(string account, string id, CancellationToken ct = default) =>
        SourceFor(account).DeletePermanently(account, id, ct);

    public Task<StorageSpace?> Space(string account, string folderId, CancellationToken ct = default) =>
        SourceFor(account).Space(account, folderId, ct);

    public string? SpaceKey(string account, string folderId) => SourceFor(account).SpaceKey(account, folderId);

    public Task Move(string account, string id, string? fromParent, string toParent, CancellationToken ct = default) =>
        SourceFor(account).Move(account, id, fromParent, toParent, ct);

    public Task CreateFolder(string account, string parentId, string name, CancellationToken ct = default) =>
        SourceFor(account).CreateFolder(account, parentId, name, ct);

    public Task<Stream> OpenRead(string account, string id, CancellationToken ct = default) =>
        SourceFor(account).OpenRead(account, id, ct);

    /// <summary>Reads a whole (small) file, e.g. a subtitle.</summary>
    public async Task<byte[]> ReadAll(string account, string id, CancellationToken ct = default)
    {
        await using var s = await OpenRead(account, id, ct);
        using var ms = new MemoryStream();
        await s.CopyToAsync(ms, ct);
        return ms.ToArray();
    }
}
