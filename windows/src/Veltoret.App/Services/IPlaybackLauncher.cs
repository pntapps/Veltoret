using Veltoret.Core.Data;

namespace Veltoret.App.Services;

/// <summary>
/// What "Play" buttons call (Home, details, Search, Files, reminders). Implemented by the player module, which
/// resolves the best copy (device first; offline only local copies), the resume position and the episode list.
/// </summary>
public interface IPlaybackLauncher
{
    /// <summary>Plays the best copy of a movie. <paramref name="startOver"/> ignores saved progress.</summary>
    Task PlayMovie(int movieId, bool startOver = false);

    /// <summary>Plays what "Play" on a show means: the next episode (PlayTargets), or episode 1 once all are watched.</summary>
    Task PlayShow(int showId);

    Task PlayEpisode(int showId, int season, int episode, bool startOver = false);

    /// <summary>Plays one specific file (Files screen, "Versions", unmatched files).</summary>
    Task PlayFile(MediaFileEntity file, bool startOver = false);

    /// <summary>Plays any file from a source by id, even if it isn't in the library (Files screen).</summary>
    Task PlayItem(string account, string fileId, string name);
}
