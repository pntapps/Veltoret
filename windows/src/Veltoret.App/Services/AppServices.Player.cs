using Veltoret.App.Player;

namespace Veltoret.App.Services;

// [player] module wiring: LibVLC and the Playback launcher.
public static partial class AppServices
{
    static partial void InitPlayer()
    {
        // Loads libvlc from the VideoLAN.LibVLC.Windows package (libvlc\win-x64 next to the app).
        LibVLCSharp.Shared.Core.Initialize();
        LibVlcEngine.Warm();
        Playback = new PlaybackLauncher();
    }

    static partial void ShutdownPlayer()
    {
        // Save progress before the process goes away, then close the window (which frees LibVLC).
        try
        {
            if (PlayerWindow.Current is { } player)
            {
                player.SaveProgress().Wait(TimeSpan.FromSeconds(3));
                player.Close();
            }
        }
        catch (Exception) { }
    }
}
