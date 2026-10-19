using System.Windows;
using Veltoret.App.Services;
using Veltoret.Core.Data;

namespace Veltoret.App.Player;

/// <summary>
/// What Play buttons call. Picks the best copy (device first; offline only This PC copies, via PlaybackResolver),
/// then opens it in the player window — reusing the open one, which saves the current video's progress first.
/// Resume position, next/previous episodes and the episode list are worked out by the player.
/// </summary>
public sealed class PlaybackLauncher : IPlaybackLauncher
{
    public async Task PlayMovie(int movieId, bool startOver = false)
    {
        var file = await AppServices.Resolver.MovieFile(movieId);
        if (file != null) Open(new PlayerArgs(file.DriveId, file.AccountEmail, null, startOver));
        else Unavailable();
    }

    public async Task PlayShow(int showId)
    {
        var target = await AppServices.Resolver.ShowPlayTarget(showId);
        if (target != null) Open(new PlayerArgs(target.File.DriveId, target.File.AccountEmail, null, FromStart: false));
        else Unavailable();
    }

    public async Task PlayEpisode(int showId, int season, int episode, bool startOver = false)
    {
        var file = await AppServices.Resolver.EpisodeFile(showId, season, episode);
        if (file != null) Open(new PlayerArgs(file.DriveId, file.AccountEmail, null, startOver));
        else Unavailable();
    }

    public Task PlayFile(MediaFileEntity file, bool startOver = false)
    {
        Open(new PlayerArgs(file.DriveId, file.AccountEmail, null, startOver));
        return Task.CompletedTask;
    }

    public Task PlayItem(string account, string fileId, string name)
    {
        Open(new PlayerArgs(fileId, account, name, FromStart: false));
        return Task.CompletedTask;
    }

    /// <summary>Opens in the existing player window, or a new one.</summary>
    public static void Open(PlayerArgs args)
    {
        var dispatcher = Application.Current.Dispatcher;
        if (!dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => Open(args));
            return;
        }
        var current = PlayerWindow.Current;
        if (current != null)
        {
            current.Open(args);
            current.BringToFront();
            return;
        }
        var window = new PlayerWindow(args);
        window.Show();
        window.Activate();
    }

    private static void Unavailable()
    {
        // Nothing playable (offline with no copy on This PC, or the files were removed): tell the user in-app.
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            try { Controls.Toast.Show("This video isn't available right now"); }
            catch (Exception) { }
        });
    }
}
