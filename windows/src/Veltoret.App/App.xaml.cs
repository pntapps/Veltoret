using System.IO.Pipes;
using System.Windows;
using System.Windows.Threading;
using Veltoret.App.Services;
using Veltoret.Core;

namespace Veltoret.App;

public partial class App : Application
{
    private const string InstanceName = "Veltoret.SingleInstance";
    private Mutex? _instanceMutex;

    /// <summary>Started with --background (Start with Windows): stay in the notification area until opened.</summary>
    public static bool StartedInBackground { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        // One Veltoret per user: a second launch asks the first to show its window, then exits.
        _instanceMutex = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            SignalFirstInstance();
            Shutdown();
            return;
        }

        // A toast click that launched us opens the window itself (Play, open) or stays hidden (Snooze).
        StartedInBackground = e.Args.Contains("--background") ||
            Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat.WasCurrentProcessToastActivated();
        DispatcherUnhandledException += OnUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log(args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) => { Log(args.Exception); args.SetObserved(); };

        base.OnStartup(e);
        Controls.TouchInput.Install();
        AppServices.Init();
        var window = new MainWindow();
        MainWindow = window;
        if (!StartedInBackground) window.Show();
        ListenForOtherInstances();
        AppServices.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { AppServices.Shutdown(); }
        catch (Exception ex) { Log(ex); }
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }

    /// <summary>Shows and focuses the main window (from the tray, a toast, or a second launch).</summary>
    public static void ShowMainWindow()
    {
        var w = Current.MainWindow;
        if (w == null) return;
        if (!w.IsVisible) w.Show();
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Activate();
        w.Topmost = true;
        w.Topmost = false;
        w.Focus();
    }

    private static void SignalFirstInstance()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out);
            pipe.Connect(2000);
            pipe.WriteByte(1);
        }
        catch (Exception) { }
    }

    private void ListenForOtherInstances()
    {
        var thread = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var pipe = new NamedPipeServerStream(InstanceName, PipeDirection.In, 1);
                    pipe.WaitForConnection();
                    pipe.ReadByte();
                    Dispatcher.BeginInvoke(ShowMainWindow);
                }
                catch (Exception) { Thread.Sleep(500); }
            }
        }) { IsBackground = true, Name = "single-instance" };
        thread.Start();
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log(e.Exception);
        // Keep running: one failing screen shouldn't close the player or lose progress.
        e.Handled = true;
    }

    public static void Log(Exception? ex)
    {
        if (ex == null) return;
        try
        {
            Directory.CreateDirectory(AppPaths.Logs);
            File.AppendAllText(Path.Combine(AppPaths.Logs, "errors.log"), $"[{DateTime.Now:O}] {ex}\n\n");
        }
        catch (Exception) { }
    }
}
