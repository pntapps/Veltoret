using Veltoret.Core;
using Veltoret.Core.Cast;
using Veltoret.Core.TvLink;

namespace Veltoret.App.Services;

/// <summary>Chromecast and "Play on TV" (network module).</summary>
public static partial class AppServices
{
    /// <summary>Chromecast + Play on TV behind one state (device list, connect, load, remote commands).</summary>
    public static CastController Cast { get; private set; } = null!;

    /// <summary>"Play on TV" pairings (DPAPI-encrypted secrets) and this PC's link id.</summary>
    public static TvLinkStore TvLinks { get; private set; } = null!;

    static partial void InitCast()
    {
        TvLinks = new TvLinkStore(Path.Combine(AppPaths.Secrets, "tv_link.json"));
        var tvLink = new TvLinkClient(TvLinks, () => Environment.MachineName);
        var factory = new CastMediaFactory(
            MediaFileDao, CatalogDao,
            (account, id, ct) => Storage.OpenRead(account, id, ct),
            () => Settings.Current.PreferredSubtitleLanguage,
            () => Settings.Current.PreferredAudioLanguage);
        Cast = new CastController(
            (account, id, ct) => Storage.OpenRead(account, id, ct),
            tvLink,
            Watch ?? new Veltoret.Core.Library.WatchRepository(WatchDao),
            factory,
            () => Settings.Current.AutoPlayNext);
    }

    static partial void StartCast()
    {
        Network.CastPlayerBridge.Start();
        Network.CastFirewall.Watch(Cast);
    }

    static partial void ShutdownCast()
    {
        try { Cast?.Shutdown(); }
        catch (Exception e) { App.Log(e); }
    }
}
