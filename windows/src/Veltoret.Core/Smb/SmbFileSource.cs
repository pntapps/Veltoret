using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using SMBLibrary;
using SMBLibrary.Client;
using Veltoret.Core.Storage;
using FileAttributes = SMBLibrary.FileAttributes;

namespace Veltoret.Core.Smb;

/// <summary>
/// File access on SMB servers (Windows sharing, Samba on routers and NAS boxes) through SMBLibrary, SMB 2 and 3
/// (Android: SmbStorage). One signed-in session per server is kept and reused; a dropped connection is reopened
/// once per call. Requests time out after 20 s, but there's no idle read timeout: the player stops reading for
/// minutes once its buffer is full, and the connection must survive that.
/// </summary>
public sealed class SmbFileSource : IFileSource
{
    public const string FolderMime = "application/vnd.google-apps.folder";
    internal const int RequestTimeoutMs = 20_000;
    private const int ConnectTimeoutMs = 8_000;

    private readonly SmbServerStore _servers;
    private readonly ConcurrentDictionary<string, HostSlot> _hosts = new(StringComparer.Ordinal);

    public SmbFileSource(SmbServerStore servers) => _servers = servers;

    public SmbServerStore Servers => _servers;

    // ---------------------------------------------------------------------------------------------
    // IFileSource

    public bool Handles(string account) => SmbPath.IsSmb(account);

    public string RootId(string account) => SmbPath.Parse(account).Account;

    public string RootName(string account) => _servers.Server(SmbPath.Parse(account).Account)?.DisplayName ?? SmbPath.Parse(account).Host;

    public Task<List<StorageItem>> List(string account, string folderId, CancellationToken ct = default) =>
        Io(() => ListSync(SmbPath.Parse(folderId)), ct);

    public async Task<List<StorageItem>> Search(string account, string query, string currentFolder, CancellationToken ct = default)
    {
        var q = query.Trim();
        var items = await List(account, currentFolder, ct).ConfigureAwait(false);
        return q.Length == 0 ? items : items.Where(i => i.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    public Task<string> Rename(string account, string id, string newName, CancellationToken ct = default) => Io(() =>
    {
        var path = SmbPath.Parse(id);
        if (path.Segments.Count == 0) throw new SmbException("Shared folders can't be renamed from here");
        var target = path.Parent!.Child(newName);
        WithShare(path, (_, store) => MoveEntry(store, path, target));
        return target.Id;
    }, ct);

    public Task Remove(string account, string id, CancellationToken ct = default) => Delete(id, ct);

    public Task DeletePermanently(string account, string id, CancellationToken ct = default) => Delete(id, ct);

    public Task<StorageSpace?> Space(string account, string folderId, CancellationToken ct = default) => Io(() =>
    {
        var path = SmbPath.Parse(folderId);
        if (path.Share == null) return null;
        return WithShare(path, (_, store) =>
        {
            var status = store.GetFileSystemInformation(out var info, FileSystemInformationClass.FileFsFullSizeInformation);
            Check(status, "Space");
            var full = (FileFsFullSizeInformation)info;
            var unit = (long)full.SectorsPerAllocationUnit * full.BytesPerSector;
            var total = full.TotalAllocationUnits * unit;
            var free = full.ActualAvailableAllocationUnits * unit;
            // Caller free space respects per-user quotas, so it's what can actually be written.
            return (StorageSpace?)new StorageSpace(path.Share, Math.Max(0, total - free), total, full.CallerAvailableAllocationUnits * unit);
        });
    }, ct);

    public string? SpaceKey(string account, string folderId)
    {
        var path = SmbPath.Parse(folderId);
        return path.Share == null ? null : $"{path.Host}/{path.Share}";
    }

    public Task Move(string account, string id, string? fromParent, string toParent, CancellationToken ct = default) => Io(() =>
    {
        var path = SmbPath.Parse(id);
        var folder = SmbPath.Parse(toParent);
        if (path.Segments.Count == 0) throw new SmbException("Shared folders can't be moved from here");
        if (folder.Host != path.Host || folder.Share != path.Share) throw new SmbException("Files can only be moved within the same shared folder");
        var target = folder.Child(path.Name);
        WithShare(path, (_, store) => MoveEntry(store, path, target));
        return target.Id;
    }, ct);

    public Task CreateFolder(string account, string parentId, string name, CancellationToken ct = default) => Io(() =>
    {
        var path = SmbPath.Parse(parentId).Child(name);
        if (path.Segments.Count == 0) throw new SmbException("Shared folders can't be created from here");
        WithShare(path, (conn, store) =>
        {
            var status = store.CreateFile(out var handle, out _, path.SharePath,
                AccessMask.GENERIC_READ | AccessMask.SYNCHRONIZE, FileAttributes.Directory,
                ShareAccess.Read | ShareAccess.Write, CreateDisposition.FILE_CREATE,
                CreateOptions.FILE_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
            Check(status, "Create folder");
            store.CloseFile(handle);
            return true;
        });
        return true;
    }, ct);

    /// <summary>A seekable, thread-safe, read-only stream doing positioned reads (the player streams through it).</summary>
    public async Task<Stream> OpenRead(string account, string id, CancellationToken ct = default)
    {
        var path = SmbPath.Parse(id);
        var stream = new SmbReadStream(this, path);
        try
        {
            await Io(() => { stream.Open(); return true; }, ct).ConfigureAwait(false);
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Server-level operations used by "Add network server" and Settings.

    /// <summary>
    /// Signs in to <paramref name="server"/> with <paramref name="password"/> without saving anything, and lists its
    /// shares. Used by "Add network server" to check the details before they're stored. Throws <see cref="SmbException"/>.
    /// </summary>
    public Task<List<string>> Test(SmbServer server, string password, CancellationToken ct = default) => Io(() =>
    {
        var conn = OpenConnection(server, password);
        try
        {
            return ShareNames(conn.Client);
        }
        finally
        {
            conn.Close();
        }
    }, ct);

    /// <summary>Forgets the open session, e.g. after the server was removed or its password changed.</summary>
    public void Disconnect(string account)
    {
        var host = SmbPath.Parse(account).Host;
        if (_hosts.TryRemove(host, out var slot))
            lock (slot.ConnectLock) { slot.Connection?.Close(); slot.Connection = null; }
    }

    /// <summary>Closes every connection (app exit).</summary>
    public void DisconnectAll()
    {
        foreach (var host in _hosts.Keys.ToList()) Disconnect(SmbPath.Scheme + host);
    }

    // ---------------------------------------------------------------------------------------------

    private List<StorageItem> ListSync(SmbPath path)
    {
        if (path.Share == null)
            return WithSession(path.Host, conn => ShareNames(conn.Client)).Select(s => Folder(path.Child(s), null)).ToList();

        return WithShare(path, (_, store) =>
        {
            var entries = QueryDirectory(store, path.SharePath);
            return entries
                .Where(info => info.FileName != "." && info.FileName != ".." &&
                               (info.FileAttributes & (FileAttributes.Hidden | FileAttributes.System)) == 0)
                .Select(info =>
                {
                    var child = path.Child(info.FileName);
                    if ((info.FileAttributes & FileAttributes.Directory) != 0) return Folder(child, path.Id);
                    return new StorageItem
                    {
                        Id = child.Id,
                        Name = info.FileName,
                        MimeType = SmbMime.For(info.FileName),
                        IsFolder = false,
                        SizeBytes = info.EndOfFile,
                        ModifiedTime = Iso(info.LastWriteTime),
                        Parents = new[] { path.Id },
                        CanRename = true, CanTrash = true, CanDelete = true, CanAddChildren = true,
                    };
                })
                .OrderBy(i => i.IsFolder ? 0 : 1)
                .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        });
    }

    private static StorageItem Folder(SmbPath path, string? parent) => new()
    {
        Id = path.Id,
        Name = path.Name,
        MimeType = FolderMime,
        IsFolder = true,
        Parents = parent == null ? Array.Empty<string>() : new[] { parent },
        CanRename = true, CanTrash = true, CanDelete = true, CanAddChildren = true,
    };

    private static string? Iso(DateTime time)
    {
        if (time == default) return null;
        var utc = time.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(time, DateTimeKind.Utc) : time.ToUniversalTime();
        if (utc <= DateTime.UnixEpoch) return null;
        return utc.Millisecond == 0
            ? utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture)
            : utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture);
    }

    private static List<FileDirectoryInformation> QueryDirectory(ISMBFileStore store, string sharePath)
    {
        var status = store.CreateFile(out var handle, out _, sharePath,
            (AccessMask)DirectoryAccessMask.FILE_LIST_DIRECTORY | AccessMask.SYNCHRONIZE, FileAttributes.Directory,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN,
            CreateOptions.FILE_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
        Check(status, "Open folder");
        try
        {
            status = store.QueryDirectory(out var list, handle, "*", FileInformationClass.FileDirectoryInformation);
            if (status != NTStatus.STATUS_NO_MORE_FILES) Check(status, "List folder");
            return (list ?? new()).OfType<FileDirectoryInformation>().ToList();
        }
        finally
        {
            store.CloseFile(handle);
        }
    }

    private Task Delete(string id, CancellationToken ct) => Io(() =>
    {
        var path = SmbPath.Parse(id);
        if (path.Segments.Count == 0) throw new SmbException("Shared folders can't be deleted from here");
        WithShare(path, (_, store) => { DeleteEntry(store, path.SharePath); return true; });
        return true;
    }, ct);

    /// <summary>Deletes permanently (network shares have no trash); folders with everything in them.</summary>
    private static void DeleteEntry(ISMBFileStore store, string sharePath)
    {
        var status = store.CreateFile(out var handle, out _, sharePath,
            AccessMask.DELETE | (AccessMask)FileAccessMask.FILE_READ_ATTRIBUTES | AccessMask.SYNCHRONIZE, 0,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN,
            CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
        Check(status, "Open");
        bool isDirectory;
        try
        {
            Check(store.GetFileInformation(out var info, handle, FileInformationClass.FileBasicInformation), "Read attributes");
            isDirectory = (((FileBasicInformation)info).FileAttributes & FileAttributes.Directory) != 0;
            if (!isDirectory)
            {
                Check(store.SetFileInformation(handle, new FileDispositionInformation { DeletePending = true }), "Delete");
                return;
            }
        }
        finally
        {
            store.CloseFile(handle);
        }
        foreach (var child in QueryDirectory(store, sharePath))
        {
            if (child.FileName is "." or "..") continue;
            DeleteEntry(store, sharePath.Length == 0 ? child.FileName : sharePath + "\\" + child.FileName);
        }
        status = store.CreateFile(out handle, out _, sharePath,
            AccessMask.DELETE | AccessMask.SYNCHRONIZE, FileAttributes.Directory,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN,
            CreateOptions.FILE_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
        Check(status, "Open folder");
        try
        {
            Check(store.SetFileInformation(handle, new FileDispositionInformation { DeletePending = true }), "Delete folder");
        }
        finally
        {
            store.CloseFile(handle);
        }
    }

    private static bool MoveEntry(ISMBFileStore store, SmbPath from, SmbPath to)
    {
        var status = store.CreateFile(out var handle, out _, from.SharePath,
            AccessMask.DELETE | AccessMask.GENERIC_READ | AccessMask.SYNCHRONIZE, 0,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN,
            CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
        Check(status, "Open");
        try
        {
            Check(store.SetFileInformation(handle, new FileRenameInformationType2 { ReplaceIfExists = false, FileName = to.SharePath }), "Rename");
        }
        finally
        {
            store.CloseFile(handle);
        }
        return true;
    }

    /// <summary>Disk shares people can browse: no printers, IPC$ or hidden admin shares (ending in $).</summary>
    private static List<string> ShareNames(SMB2Client client)
    {
        var shares = client.ListShares(out var status);
        Check(status, "List shared folders");
        return (shares ?? new())
            .Where(s => !s.EndsWith('$'))
            .OrderBy(s => s, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    internal static void Check(NTStatus status, string operation)
    {
        if (status != NTStatus.STATUS_SUCCESS) throw new SmbStatusException(status, operation);
    }

    // ---------------------------------------------------------------------------------------------
    // Connections

    private sealed class HostSlot
    {
        public readonly object ConnectLock = new();
        public SmbConnection? Connection;
    }

    private SmbConnection OpenConnection(SmbServer server, string password)
    {
        var ip = ResolveHost(server.Host);
        // SMB2Client.Connect blocks for the OS connect timeout (~21 s) on a dead address; probe first so
        // "server off" answers quickly and isn't mistaken for "doesn't speak SMB 2".
        using (var probe = new TcpClient(ip.AddressFamily))
        {
            var connect = probe.ConnectAsync(ip, server.Port <= 0 ? 445 : server.Port);
            _ = connect.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            if (!connect.Wait(ConnectTimeoutMs)) throw new TimeoutException("Connect timed out");
            connect.GetAwaiter().GetResult();
        }
        // Response timeout per request; SMBLibrary never sets a socket read timeout.
        var client = new SMB2Client(RequestTimeoutMs, true);
        if (!client.Connect(ip, SMBTransportType.DirectTCPTransport))
            throw new SmbStatusException(NTStatus.STATUS_NOT_SUPPORTED, "Connect");
        try
        {
            // Guest is the "Guest" account with an empty password (not anonymous, which is "").
            var status = server.Guest ? client.Login("", "Guest", "") : client.Login(server.Domain, server.Username, password);
            Check(status, "Sign in");
            return new SmbConnection(server.Host, client);
        }
        catch
        {
            try { client.Disconnect(); } catch { }
            throw;
        }
    }

    private static IPAddress ResolveHost(string host)
    {
        if (IPAddress.TryParse(host, out var ip)) return ip;
        var addresses = Dns.GetHostAddresses(host);
        return addresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)
               ?? addresses.FirstOrDefault()
               ?? throw new SocketException((int)SocketError.HostNotFound);
    }

    /// <summary>The host's signed-in connection, reconnecting when it's gone, broken or <paramref name="fresh"/> is asked for.</summary>
    internal SmbConnection Connection(string host, bool fresh)
    {
        var slot = _hosts.GetOrAdd(host, _ => new HostSlot());
        lock (slot.ConnectLock)
        {
            var existing = slot.Connection;
            if (!fresh && existing is { Alive: true }) return existing;
            existing?.Close();
            slot.Connection = null;
            var account = SmbPath.AccountOf(host);
            var server = _servers.Server(account) ?? throw new SmbException("This network server was removed from Veltoret");
            var password = _servers.Password(account) ?? throw new SmbException($"Sign in to {server.DisplayName} again");
            slot.Connection = OpenConnection(server, password);
            return slot.Connection;
        }
    }

    /// <summary>Runs <paramref name="block"/> with a signed-in session, reconnecting once if the old connection went stale.</summary>
    internal T WithSession<T>(string host, Func<SmbConnection, T> block)
    {
        var conn = Connection(host, fresh: false);
        try
        {
            lock (conn.Gate) return block(conn);
        }
        catch (Exception e) when (SmbErrors.IsDropped(e))
        {
            conn.Broken = true;
            conn = Connection(host, fresh: true);
            lock (conn.Gate) return block(conn);
        }
    }

    internal T WithShare<T>(SmbPath path, Func<SmbConnection, ISMBFileStore, T> block)
    {
        var shareName = path.Share ?? throw new SmbException($"Pick a shared folder on {path.Host} first");
        return WithSession(path.Host, conn => block(conn, conn.Tree(shareName)));
    }

    /// <summary>Runs synchronous SMB work off the caller's thread and words any failure for people.</summary>
    private static async Task<T> Io<T>(Func<T> block, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        try
        {
            return await Task.Run(block, ct).ConfigureAwait(false);
        }
        catch (SmbException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw new SmbException(SmbErrors.Describe(e), e);
        }
    }
}

/// <summary>
/// One signed-in SMB2 session. SMBLibrary's client isn't safe for concurrent requests, so every request on it
/// holds <see cref="Gate"/>.
/// </summary>
internal sealed class SmbConnection(string host, SMB2Client client)
{
    public string Host { get; } = host;
    public SMB2Client Client { get; } = client;
    public object Gate { get; } = new();
    /// <summary>Set when a request on it failed as "dropped": the next call reconnects.</summary>
    public volatile bool Broken;
    private readonly Dictionary<string, ISMBFileStore> _trees = new(StringComparer.Ordinal);
    private bool _closed;

    public bool Alive => !Broken && !_closed && Client.IsConnected;

    /// <summary>The open share (call while holding <see cref="Gate"/>).</summary>
    public ISMBFileStore Tree(string share)
    {
        if (_trees.TryGetValue(share, out var tree)) return tree;
        var store = Client.TreeConnect(share, out var status);
        if (status == NTStatus.STATUS_SUCCESS && store == null) throw new SmbException($"\"{share}\" isn't a shared folder");
        SmbFileSource.Check(status, "Open shared folder");
        _trees[share] = store!;
        return store!;
    }

    public void Close()
    {
        _closed = true;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            lock (Gate)
            {
                try { if (Client.IsConnected) Client.Logoff(); } catch { }
                try { Client.Disconnect(); } catch { }
            }
        });
    }
}
