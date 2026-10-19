using Veltoret.Core;
using Veltoret.Core.Smb;

namespace Veltoret.App.Services;

/// <summary>Network shares (SMB): saved servers, the file source, and discovery (network module).</summary>
public static partial class AppServices
{
    /// <summary>Saved SMB servers and their DPAPI-encrypted passwords.</summary>
    public static SmbServerStore SmbServers { get; private set; } = null!;

    /// <summary>The SMB <c>IFileSource</c> (also registered with <see cref="Storage"/> for "smb://host" accounts).</summary>
    public static SmbFileSource SmbFiles { get; private set; } = null!;

    /// <summary>Finds SMB servers on the local network (mDNS + subnet sweep).</summary>
    public static SmbDiscovery SmbDiscovery { get; private set; } = null!;

    static partial void InitSmb()
    {
        SmbServers = new SmbServerStore(Path.Combine(AppPaths.Secrets, "smb_servers.json"));
        SmbFiles = new SmbFileSource(SmbServers);
        SmbDiscovery = new SmbDiscovery();
        Storage.Register(SmbFiles);
        // Back-fill library account rows for saved servers (Android: ensureServerAccounts at app start).
        _ = Task.Run(async () =>
        {
            try { await SmbAccounts.EnsureServerAccounts(AccountDao, SmbServers); }
            catch (Exception e) { App.Log(e); }
        });
    }
}
