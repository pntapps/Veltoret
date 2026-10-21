using System.ComponentModel;
using System.Windows;
using Veltoret.App.Navigation;
using Veltoret.App.Pages.Settings;
using Veltoret.App.Plans;
using Veltoret.App.Tray;
using Veltoret.Core.Plans;

namespace Veltoret.App.Services;

// [plans] module wiring: watchlist and reminders, toasts, upcoming episodes, the notification-area icon, Settings.
public static partial class AppServices
{
    public static PlansRepository Plans { get; private set; } = null!;
    public static UpcomingService Upcoming { get; private set; } = null!;

    private static ReminderScheduler? _reminderAlarms;
    private static TrayIcon? _tray;
    private static bool _upcomingStarted;
    private static bool _quitting;

    static partial void InitPlans()
    {
        var notifier = new ToastNotifier();
        Plans = new PlansRepository(PlansDao) { Notifier = notifier };
        _reminderAlarms = new ReminderScheduler(id => Plans.Fire(id));
        Plans.Alarms = _reminderAlarms;
        Upcoming = new UpcomingService(Plans, CatalogDao, WatchDao, Settings,
            id => Tmdb.EnsureShow(id, new HashSet<int>(), UpcomingService.RefreshMs),
            () => Connectivity.IsOnline)
        {
            Notifier = notifier,
        };
        // Before any window shows: a toast click may be what started Veltoret.
        ToastNotifier.RegisterActivation();
        Navigator.Register<SettingsRoute>(_ => new SettingsPage());
    }

    static partial void StartPlans()
    {
        var app = Application.Current;
        Appearance.Apply(Settings.Current.OledBlack);
        var oled = Settings.Current.OledBlack;
        Settings.Changed += s =>
        {
            if (s.OledBlack != oled)
            {
                oled = s.OledBlack;
                app?.Dispatcher.BeginInvoke(() => Appearance.Apply(s.OledBlack));
            }
            if (s.OnboardingComplete) StartUpcoming();
        };

        // "Start with Windows" follows the exe if it moved; a stale entry is removed.
        StartupRegistration.Set(Settings.Current.StartWithWindows);

        if (app != null)
        {
            try
            {
                _tray = new TrayIcon();
                _tray.OpenRequested += () => App.ShowMainWindow();
                _tray.ScanRequested += () => _ = Scans.RunNow();
                _tray.QuitRequested += () => { _quitting = true; app.Shutdown(); };
                app.SessionEnding += (_, _) => _quitting = true;
                _tray.Resumed += () => _ = RestoreReminders();
                app.Exit += (_, _) => { _tray?.Dispose(); _tray = null; _reminderAlarms?.Dispose(); Upcoming.Dispose(); };
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
            HookMainWindow(app.MainWindow);
        }

        Connectivity.OnlineChanged += online => { if (online) Upcoming.OnOnline(); };
        if (Settings.Current.OnboardingComplete) StartUpcoming();
        _ = RestoreReminders();
    }

    private static void StartUpcoming()
    {
        if (_upcomingStarted) return;
        _upcomingStarted = true;
        Upcoming.Start();
    }

    private static async Task RestoreReminders()
    {
        try { await Plans.Restore(); }
        catch (Exception ex) { App.Log(ex); }
    }

    /// <summary>Closing the window hides it to the notification area while "Keep running in the notification area" is on.</summary>
    private static void HookMainWindow(Window? window)
    {
        if (window == null) return;
        window.Closing += (_, e) => OnMainWindowClosing(window, e);
        window.Closed += (_, _) =>
        {
            if (!Settings.Current.RunInBackground) Application.Current?.Shutdown();
        };
    }

    private static void OnMainWindowClosing(Window window, CancelEventArgs e)
    {
        if (e.Cancel || _quitting || !Settings.Current.RunInBackground || _tray == null) return;
        if (Application.Current?.Dispatcher.HasShutdownStarted == true) return;
        e.Cancel = true;
        window.Hide();
    }
}
