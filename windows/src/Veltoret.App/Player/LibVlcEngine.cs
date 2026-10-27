using LibVLCSharp.Shared;

namespace Veltoret.App.Player;

/// <summary>
/// Loads LibVLC's plugins once, on a background thread at startup, and keeps them loaded while the app runs, so
/// opening the player doesn't load them on the UI thread (without a plugin cache that's ~300 DLLs: seconds of "not
/// responding" on a low-power tablet). Player windows still create their own LibVLC (per-window options); with the
/// plugins already loaded that is quick. The installer ships plugins.dat; when it's missing (dev builds, older
/// installs) it's written here if the folder is writable, so the next start is quick too.
/// </summary>
public static class LibVlcEngine
{
    private static readonly TaskCompletionSource ReadySource = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static LibVLC? _keepLoaded;

    /// <summary>Completes (never faults) once the plugins are loaded, or loading failed.</summary>
    public static Task Ready => ReadySource.Task;

    public static void Warm()
    {
        var thread = new Thread(() =>
        {
            try
            {
                var cache = Path.Combine(AppContext.BaseDirectory, "libvlc", "win-x64", "plugins", "plugins.dat");
                _keepLoaded = File.Exists(cache) ? new LibVLC(enableDebugLogs: false)
                    : new LibVLC(enableDebugLogs: false, "--reset-plugins-cache");
            }
            catch (Exception e) { App.Log(e); }
            finally { ReadySource.TrySetResult(); }
        }) { IsBackground = true, Name = "libvlc-warm", Priority = ThreadPriority.BelowNormal };
        thread.Start();
    }
}
