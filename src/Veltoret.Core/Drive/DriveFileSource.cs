using Veltoret.Core.Storage;

namespace Veltoret.Core.Drive;

/// <summary>
/// Google Drive behind the <see cref="Storage.Storage"/> facade: every account that isn't This PC or a network
/// server. Root "root" = "My Drive"; the pseudo-folder <see cref="SharedRoot"/> lists "Shared with me".
/// Remove = trash (recoverable); DeletePermanently = files.delete. Rename keeps the id.
/// </summary>
public sealed class DriveFileSource(DriveRepository drive) : IFileSource
{
    public const string RootFolder = "root";
    public const string SharedRoot = "shared";

    public bool Handles(string account) => Accounts.IsDrive(account);

    public string RootId(string account) => RootFolder;

    public string RootName(string account) => "My Drive";

    public async Task<List<StorageItem>> List(string account, string folderId, CancellationToken ct = default)
    {
        var files = folderId == SharedRoot
            ? await drive.ListSharedWithMe(account, ct).ConfigureAwait(false)
            : await drive.ListChildren(account, folderId, "folder,name_natural", ct).ConfigureAwait(false);
        return files.Select(f => f.ToItem()).ToList();
    }

    public async Task<List<StorageItem>> Search(string account, string query, string currentFolder, CancellationToken ct = default) =>
        (await drive.Search(account, query, ct).ConfigureAwait(false)).Select(f => f.ToItem()).ToList();

    public async Task<string> Rename(string account, string id, string newName, CancellationToken ct = default) =>
        (await drive.Rename(account, id, newName, ct).ConfigureAwait(false)).Id is { Length: > 0 } newId ? newId : id;

    public Task Remove(string account, string id, CancellationToken ct = default) => drive.Trash(account, id, ct);

    public Task DeletePermanently(string account, string id, CancellationToken ct = default) => drive.DeletePermanently(account, id, ct);

    public Task<StorageSpace?> Space(string account, string folderId, CancellationToken ct = default) => drive.Space(account, ct);

    /// <summary>Every folder of an account shares the account's Google storage.</summary>
    public string? SpaceKey(string account, string folderId) => account;

    public async Task Move(string account, string id, string? fromParent, string toParent, CancellationToken ct = default) =>
        await drive.Move(account, id, fromParent, toParent, ct).ConfigureAwait(false);

    public async Task CreateFolder(string account, string parentId, string name, CancellationToken ct = default) =>
        await drive.CreateFolder(account, parentId, name, ct).ConfigureAwait(false);

    /// <summary>A seekable range-reading stream (the player streams Drive files through it).</summary>
    public async Task<Stream> OpenRead(string account, string id, CancellationToken ct = default)
    {
        var file = await drive.Get(account, id, ct).ConfigureAwait(false);
        long length = file.Size != null ? file.SizeBytes : -1;
        return new DriveRangeStream(drive, account, id, length);
    }
}
