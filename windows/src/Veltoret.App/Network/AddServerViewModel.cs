using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Services;
using Veltoret.Core.Smb;

namespace Veltoret.App.Network;

/// <summary>One row of "On your network".</summary>
public sealed class FoundServerRow(FoundServer server)
{
    public FoundServer Server { get; } = server;
    public string Address => Server.Address;
    public string Label => Server.Name ?? (Server.IsRouter ? "Your router" : "File server");
    public string Subtitle => Server.IsRouter ? $"{Server.Address} · router" : Server.Address;
    public bool IsRouter => Server.IsRouter;
}

/// <summary>A folder on the server: one of the "breadcrumbs" the typed address pointed into.</summary>
public sealed record SmbCrumb(string Id, string Name);

/// <summary>
/// "Add network server" (port of Android's AddServerViewModel): finds servers on the network, checks the details by
/// signing in, then saves the server (password encrypted) and adds it as a library source. The dialog only holds the
/// text fields. Must be used from the UI thread (collections and properties are bound).
/// </summary>
public sealed partial class AddServerViewModel : ObservableObject
{
    public const string GuestRefused = "This server doesn't allow guests. Sign in with its username and password.";

    private CancellationTokenSource? _scan;

    /// <summary>Servers found on the network, routers and named ones first.</summary>
    public ObservableCollection<FoundServerRow> Found { get; } = new();

    [ObservableProperty] private bool _scanning;
    /// <summary>The found server the user chose; its name becomes the saved server's name.</summary>
    [ObservableProperty] private FoundServer? _picked;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private string? _error;

    /// <summary>Set once signed in and saved: the server and the folders the typed address pointed into.</summary>
    public SmbServer? AddedServer { get; private set; }
    public IReadOnlyList<SmbCrumb> AddedCrumbs { get; private set; } = Array.Empty<SmbCrumb>();

    /// <summary>Starts afresh (the dialog reuses nothing between openings, but keep parity with Android).</summary>
    public void Reset()
    {
        CancelScan();
        Found.Clear();
        Scanning = false;
        Picked = null;
        Busy = false;
        Error = null;
        AddedServer = null;
        AddedCrumbs = Array.Empty<SmbCrumb>();
    }

    public void CancelScan()
    {
        _scan?.Cancel();
        _scan = null;
    }

    public async void Scan()
    {
        CancelScan();
        var cts = new CancellationTokenSource();
        _scan = cts;
        Found.Clear();
        Scanning = true;
        try
        {
            await foreach (var server in AppServices.SmbDiscovery.Discover(cts.Token))
            {
                if (cts.IsCancellationRequested) break;
                Merge(server);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { App.Log(e); }
        finally
        {
            if (_scan == cts) Scanning = false;
        }
    }

    /// <summary>The sweep and the announcements can both find a server; keep one row, with the best name.</summary>
    internal void Merge(FoundServer server)
    {
        var list = Found.Select(r => r.Server).ToList();
        var i = list.FindIndex(s => s.Address == server.Address);
        if (i >= 0)
            list[i] = list[i] with { Name = list[i].Name ?? server.Name, IsRouter = list[i].IsRouter || server.IsRouter };
        else
            list.Add(server);
        var sorted = Sort(list);
        Found.Clear();
        foreach (var s in sorted) Found.Add(new FoundServerRow(s));
    }

    internal static List<FoundServer> Sort(IEnumerable<FoundServer> servers) => servers
        .OrderBy(s => s.IsRouter ? 0 : 1)
        .ThenBy(s => s.Name == null ? 1 : 0)
        .ThenBy(s => s.Address, StringComparer.Ordinal)
        .ToList();

    public void Pick(FoundServer server)
    {
        Picked = server;
        Error = null;
    }

    public void ShowError(string? message) => Error = message;

    /// <summary>
    /// Signs in and, on success, saves the server and sets <see cref="AddedServer"/>. Returns null on success or the
    /// sentence shown on screen. <paramref name="name"/> is the server's name when the caller already knows it.
    /// </summary>
    public async Task<string?> Attempt(string address, bool guest, string username, string password, string? name = null)
    {
        if (Busy) return null;
        var path = SmbPath.FromUserInput(address);
        if (path == null) return Fail("Enter the server's address, like 192.168.0.10 or \\\\192.168.0.10\\Movies");
        if (!guest && string.IsNullOrWhiteSpace(username))
            return Fail("Enter the username, or choose Guest if the server has no password");

        // "WORKGROUP\user" signs in to a Windows domain or workgroup.
        var trimmed = username.Trim();
        var slash = trimmed.IndexOf('\\');
        var (domain, user) = slash >= 0 ? (trimmed[..slash], trimmed[(slash + 1)..]) : ("", trimmed);
        var knownName = name ?? (Picked != null && string.Equals(Picked.Address, path.Host, StringComparison.OrdinalIgnoreCase) ? Picked.Name : null);
        var server = new SmbServer
        {
            Host = path.Host,
            Username = guest ? "" : user,
            Domain = guest ? "" : domain,
            Name = knownName ?? path.Host,
        };
        var secret = guest ? "" : password;
        Busy = true;
        Error = null;
        try
        {
            var shares = await AppServices.SmbFiles.Test(server, secret);
            // Match the typed share to the server's spelling ("movies" → "Movies").
            string? share = null;
            if (path.Share != null)
            {
                share = shares.FirstOrDefault(s => string.Equals(s, path.Share, StringComparison.OrdinalIgnoreCase))
                        ?? throw new SmbException(
                            $"There's no shared folder called \"{path.Share}\" on {server.Host}." +
                            (shares.Count == 0 ? "" : $" It shares: {string.Join(", ", shares)}"));
            }
            // A typed address gets the server's own name ("MYNAS") instead of its number, like a found one.
            if (knownName == null && path.Host.All(c => char.IsAsciiDigit(c) || c == '.'))
            {
                var netbios = await AppServices.SmbDiscovery.NameOf(path.Host);
                if (netbios != null) server = server with { Name = netbios };
            }
            AppServices.SmbFiles.Disconnect(server.Account);
            AppServices.SmbServers.Save(server, secret);
            await SmbAccounts.AddServerAccount(AppServices.AccountDao, server);

            var crumbs = new List<SmbCrumb>();
            if (share != null)
            {
                var crumb = new SmbPath(server.Host, null).Child(share);
                crumbs.Add(new SmbCrumb(crumb.Id, share));
                foreach (var segment in path.Segments)
                {
                    crumb = crumb.Child(segment);
                    crumbs.Add(new SmbCrumb(crumb.Id, segment));
                }
            }
            AddedServer = server;
            AddedCrumbs = crumbs;
            Busy = false;
            return null;
        }
        catch (OperationCanceledException)
        {
            Busy = false;
            throw;
        }
        catch (Exception e)
        {
            var message = e is SmbException ? e.Message : SmbErrors.Describe(e);
            // Servers refuse guests as a wrong login, or (Windows, whose Guest account is off) a disabled account.
            return Fail(guest && (message == SmbErrors.WrongLogin || message == SmbErrors.AccountDisabled) ? GuestRefused : message);
        }
    }

    private string Fail(string message)
    {
        Busy = false;
        Error = message;
        return message;
    }
}
