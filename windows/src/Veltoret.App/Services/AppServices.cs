using Veltoret.Core;
using Veltoret.Core.Data;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;

namespace Veltoret.App.Services;

/// <summary>
/// Creates and wires every repository, API and service (Android: AppContainer). Manual DI, no container.
///
/// Each module adds its own services in its own partial file (AppServices.Drive.cs, AppServices.Player.cs …)
/// and implements its Init hook there, so modules never edit each other's wiring. Init order matters:
/// Core first (database, TMDB, library), then file sources, then features.
/// </summary>
public static partial class AppServices
{
    public static VeltoretDb Db { get; private set; } = null!;
    public static AccountDao AccountDao { get; private set; } = null!;
    public static MediaFileDao MediaFileDao { get; private set; } = null!;
    public static CatalogDao CatalogDao { get; private set; } = null!;
    public static PlansDao PlansDao { get; private set; } = null!;
    public static WatchDao WatchDao { get; private set; } = null!;
    public static SettingsStore Settings { get; private set; } = null!;
    public static Storage Storage { get; private set; } = null!;
    public static Navigation.Navigator Navigator { get; private set; } = null!;

    /// <summary>Starts the player for movies, episodes or files. Set by the player module (InitPlayer).</summary>
    public static IPlaybackLauncher Playback { get; set; } = null!;

    public static void Init()
    {
        Directory.CreateDirectory(AppPaths.Root);
        Db = new VeltoretDb(AppPaths.Database);
        AccountDao = new AccountDao(Db);
        MediaFileDao = new MediaFileDao(Db);
        CatalogDao = new CatalogDao(Db);
        PlansDao = new PlansDao(Db);
        WatchDao = new WatchDao(Db);
        Settings = new SettingsStore(AppPaths.Settings);
        Storage = new Storage();
        Navigator = new Navigation.Navigator();

        InitCore();      // TMDB, library scanner, repositories, local file source, images
        InitDrive();     // Google sign-in, Drive file source, uploads, ZIP extraction
        InitSmb();       // network shares file source and server store
        InitPlayer();    // LibVLC, Playback launcher
        InitPlans();     // Watchlist, reminders, toasts, upcoming episodes
        InitCast();      // Chromecast and Play on TV
        InitUi();        // pages registered with the Navigator
    }

    /// <summary>Runs after the main window is shown (Android: VeltoretApp.onCreate work): scans, reminders, etc.</summary>
    public static void Start()
    {
        StartCore();
        StartDrive();
        StartPlans();
        StartCast();
    }

    /// <summary>Called when the app exits: stop servers, flush progress.</summary>
    public static void Shutdown()
    {
        ShutdownPlayer();
        ShutdownCast();
    }

    static partial void InitCore();
    static partial void InitDrive();
    static partial void InitSmb();
    static partial void InitPlayer();
    static partial void InitPlans();
    static partial void InitCast();
    static partial void InitUi();
    static partial void StartCore();
    static partial void StartDrive();
    static partial void StartPlans();
    static partial void StartCast();
    static partial void ShutdownPlayer();
    static partial void ShutdownCast();
}
