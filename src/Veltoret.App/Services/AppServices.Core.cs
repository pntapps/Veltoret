using Veltoret.Core;
using Veltoret.Core.Images;
using Veltoret.Core.Library;
using Veltoret.Core.Local;
using Veltoret.Core.Net;
using Veltoret.Core.Tmdb;
using WinNet = Windows.Networking.Connectivity;

namespace Veltoret.App.Services;

// [core] module wiring: TMDB, library scanner and repositories, connectivity, image cache, "This PC" file source.
public static partial class AppServices
{
    public static TmdbRepository Tmdb { get; private set; } = null!;
    public static LibraryScanner Scanner { get; private set; } = null!;
    public static LibraryRepository Library { get; private set; } = null!;
    public static WatchRepository Watch { get; private set; } = null!;
    public static PlaybackResolver Resolver { get; private set; } = null!;
    public static Connectivity Connectivity { get; private set; } = null!;
    public static ImageCache Images { get; private set; } = null!;
    public static ScanScheduler Scans { get; private set; } = null!;
    /// <summary>"This PC" (also reachable as <c>Storage.SourceFor(Accounts.Device)</c>).</summary>
    public static LocalFileSource LocalFiles { get; private set; } = null!;
    public static ArtworkPrefetch Artwork { get; private set; } = null!;

    static partial void InitCore()
    {
        Connectivity = new Connectivity
        {
            SystemCheck = SystemOnline,
            MeteredCheck = SystemMetered,
        };
        var tmdbClient = new TmdbClient(TmdbClient.CreateHttpClient(), () => Settings.Current.TmdbKey);
        Tmdb = new TmdbRepository(tmdbClient, CatalogDao);
        Images = new ImageCache(AppPaths.ImageCache);
        Watch = new WatchRepository(WatchDao);
        Resolver = new PlaybackResolver(MediaFileDao, WatchDao, () => Connectivity.IsOnline);
        Library = new LibraryRepository(CatalogDao, MediaFileDao, AccountDao, Connectivity);
        LocalFiles = new LocalFileSource();
        Storage.Register(LocalFiles);
        Scanner = new LibraryScanner(AccountDao, MediaFileDao, CatalogDao, Storage, Tmdb, Settings, Connectivity);
        Artwork = new ArtworkPrefetch(CatalogDao, Images);
        Scans = new ScanScheduler(Scanner, Connectivity, Settings, Artwork);
    }

    static partial void StartCore()
    {
        Connectivity.Start();
        Scans.Start();
    }

    /// <summary>
    /// Windows' own (NCSI-validated) answer when it says "internet access"; no profile means offline. Anything else
    /// falls back to Connectivity's HTTP probe, since NCSI can be wrong behind some proxies.
    /// </summary>
    private static bool? SystemOnline()
    {
        var profile = WinNet.NetworkInformation.GetInternetConnectionProfile();
        if (profile == null) return false;
        return profile.GetNetworkConnectivityLevel() == WinNet.NetworkConnectivityLevel.InternetAccess ? true : null;
    }

    /// <summary>"Only on Wi-Fi" maps to unmetered networks: anything but an unrestricted (or unknown) cost is metered.</summary>
    private static bool SystemMetered()
    {
        var cost = WinNet.NetworkInformation.GetInternetConnectionProfile()?.GetConnectionCost();
        if (cost == null) return false;
        return cost.NetworkCostType is not (WinNet.NetworkCostType.Unrestricted or WinNet.NetworkCostType.Unknown);
    }
}
