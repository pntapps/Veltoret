using System.Windows;
using System.Windows.Threading;
using Veltoret.App.Player;
using Veltoret.App.Services;
using Veltoret.Core.Cast;

namespace Veltoret.App.Network;

/// <summary>
/// Optional: a player (window or view model) that can describe what it plays for the TV, with its real track list,
/// selected audio, subtitle cues and sync. Without it, the cast UI builds the description from the library
/// (sidecar subtitles, MKV audio tracks, the preferred languages).
/// </summary>
public interface ICastMediaSource
{
    Task<CastMedia?> BuildCastMedia();
}

/// <summary>
/// Hands the open video to the TV and back (Android PlayerViewModel's cast collector): connecting casts what the
/// player shows (it pauses here); a video opened while connected goes to the TV too; disconnecting brings it back
/// to the player, paused at the TV's position.
/// </summary>
public static class CastPlayerBridge
{
    private static bool _wasConnected;
    private static PlayerWindow? _castFrom;
    private static string? _seenFileId;
    private static readonly HashSet<string> AudioChosen = new();
    private static DispatcherTimer? _timer;
    private static bool _busy;

    public static void Start()
    {
        var dispatcher = Application.Current.Dispatcher;
        AppServices.Cast.StateChanged += s => dispatcher.BeginInvoke(() => OnState(s));
        _timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => WatchPlayer();
        // Every player window gets the cast button in its top bar placeholder.
        EventManager.RegisterClassHandler(typeof(PlayerWindow), FrameworkElement.LoadedEvent, new RoutedEventHandler((sender, _) =>
        {
            if (sender is PlayerWindow w) PlaceButton(w);
        }));
        if (PlayerWindow.Current is { IsLoaded: true } open) PlaceButton(open);
    }

    private static void PlaceButton(PlayerWindow w)
    {
        try
        {
            if (w.CastButtonHost is { Content: null } host) host.Content = new CastButton(onImage: true);
        }
        catch (Exception e)
        {
            App.Log(e);
        }
    }

    private static void OnState(CastState s)
    {
        if (s.Connected && !_wasConnected)
        {
            _wasConnected = true;
            _seenFileId = null;
            _timer?.Start();
            _ = CastCurrentPlayer(ask: true);
        }
        else if (!s.Connected && _wasConnected)
        {
            _wasConnected = false;
            _timer?.Stop();
            ResumeLocally(s);
        }
    }

    /// <summary>A video opened in the player while connected goes to the TV.</summary>
    private static void WatchPlayer()
    {
        var w = PlayerWindow.Current;
        if (w == null || !w.IsLoaded || string.IsNullOrEmpty(w.FileId)) return;
        if (w.FileId == _seenFileId) return;
        var st = AppServices.Cast.State;
        if (!st.Connected || st.Connecting) return;
        _seenFileId = w.FileId;
        if (st.Media?.FileId == w.FileId && _castFrom == w) return;
        _ = CastCurrentPlayer(ask: true);
    }

    /// <summary>Sends the open video to the TV at the player's position; the player pauses.</summary>
    public static async Task CastCurrentPlayer(bool ask)
    {
        var w = PlayerWindow.Current;
        if (w == null || string.IsNullOrEmpty(w.FileId) || _busy) return;
        _busy = true;
        try
        {
            w.PauseForCast();
            var fileId = w.FileId;
            _seenFileId = fileId;
            var startMs = (long)(w.PositionSeconds * 1000);
            var media = await Describe(w);
            if (media == null || PlayerWindow.Current != w || w.FileId != fileId) return;
            var cast = AppServices.Cast;
            // Veltoret on a TV plays every track itself; only a Chromecast needs the audio chosen first.
            if (ask && cast.State.Link == null && media.AudioOptions.Count > 1 && !AudioChosen.Contains(fileId))
            {
                var track = CastAudioDialog.Ask(w, cast.State.DeviceName, media.AudioOptions, media.AudioTrack);
                AudioChosen.Add(fileId);
                if (track != null && track != media.AudioTrack)
                {
                    var codec = media.AudioOptions.FirstOrDefault(o => o.Track == track)?.Codec;
                    media = media with { AudioTrack = track, AudioWarning = CastFormats.AudioWarning(codec, media.Name) };
                }
            }
            if (!cast.State.Connected) return;
            _castFrom = w;
            await cast.Load(media, startMs);
        }
        catch (Exception e)
        {
            App.Log(e);
        }
        finally
        {
            _busy = false;
        }
    }

    /// <summary>Casts a library file without the player (e.g. from a page): the TV starts at the saved position.</summary>
    public static async Task CastFile(Veltoret.Core.Data.MediaFileEntity file, long startMs)
    {
        var media = await AppServices.Cast.Media.ForFile(file);
        await AppServices.Cast.Load(media, startMs);
    }

    private static async Task<CastMedia?> Describe(PlayerWindow w)
    {
        CastMedia? media = null;
        if (w is ICastMediaSource source) media = await source.BuildCastMedia();
        else if (w.DataContext is ICastMediaSource vm) media = await vm.BuildCastMedia();
        if (media != null) return media;
        var factory = AppServices.Cast.Media;
        if (w.CurrentFile is { } file) media = await factory.ForFile(file);
        else if (w.Account is { } account) media = await factory.ForItem(account, w.FileId, string.IsNullOrEmpty(w.VideoTitle) ? Path.GetFileName(w.FileId) : w.VideoTitle);
        if (media == null) return null;
        if (media.File == null && !string.IsNullOrWhiteSpace(w.VideoTitle)) media = media with { Title = w.VideoTitle, Subtitle = w.VideoSubtitle ?? media.Subtitle };
        return media;
    }

    /// <summary>The cast ended: the player takes over, paused at the TV's position.</summary>
    private static void ResumeLocally(CastState s)
    {
        var w = _castFrom;
        _castFrom = null;
        if (w == null || PlayerWindow.Current != w || !w.IsLoaded) return;
        try
        {
            if (s.Media == null || s.Media.FileId == w.FileId)
            {
                w.ResumeAfterCast(s.Media != null ? s.PositionMs : 0);
            }
            else
            {
                // The TV moved on to another episode: open that one here (its progress was saved while casting).
                w.ResumeAfterCast(0);
                if (s.Media.File is { } next) _ = AppServices.Playback.PlayFile(next);
            }
        }
        catch (Exception e)
        {
            App.Log(e);
        }
    }
}
