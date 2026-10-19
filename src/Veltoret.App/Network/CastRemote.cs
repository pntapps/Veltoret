using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Cast;
using Veltoret.Core.TvLink;

namespace Veltoret.App.Network;

/// <summary>
/// The remote while casting (Android CastingScreen): artwork, what's playing on which TV, a seek bar, ±10 s,
/// play/pause, next episode, volume (Chromecast), audio and subtitle choice, and "Stop casting".
/// </summary>
public sealed class CastRemote : UserControl
{
    private readonly AsyncImage _art = new() { Width = 96, Height = 144, Stretch = Stretch.UniformToFill, DecodeWidth = 200 };
    private readonly TextBlock _playingOn = UiKit.Text("", "Text.LabelLarge", "Amber", wrap: false);
    private readonly TextBlock _title = UiKit.Text("", "Text.TitleLarge", maxLines: 2);
    private readonly TextBlock _subtitle = UiKit.Text("", "Text.BodyMedium", "TextMuted", maxLines: 1);
    private readonly TextBlock _source = UiKit.Text("", "Text.BodySmall", "TextMuted");
    private readonly TextBlock _message = UiKit.Text("", "Text.BodyMedium");
    private readonly Slider _seek = new() { Minimum = 0, Maximum = 1 };
    private readonly TextBlock _position = UiKit.Text("0:00", "Text.LabelMedium", "TextMuted", wrap: false);
    private readonly TextBlock _duration = UiKit.Text("", "Text.LabelMedium", "TextMuted", wrap: false);
    private readonly Button _playPause;
    private readonly Button _next;
    private readonly StackPanel _volumeRow = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) };
    private readonly Button _mute;
    private readonly Slider _volume = new() { Minimum = 0, Maximum = 1, Width = 180, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _audio;
    private readonly Button _subtitles;
    private readonly Spinner _spinner = new() { Width = 30, Height = 30, Thickness = 3 };
    private readonly Icon _playIcon;
    private bool _scrubbing;
    private bool _settingVolume;
    private bool _changingVolume;
    private CastState? _last;

    public CastRemote()
    {
        _seek.Style = UiKit.Style("Slider");
        _volume.Style = UiKit.Style("Slider");
        _spinner.Stroke = UiKit.Brush("OnAmber");
        Width = 460;

        // Header: artwork + what's playing.
        var artFrame = new Border { CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = _art, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Top };
        _art.CornerRadius = new CornerRadius(10);
        var playingRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        playingRow.Children.Add(new Icon { Data = CastIcons.CastConnected, Size = 16, Fill = UiKit.Brush("Amber"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        playingRow.Children.Add(_playingOn);
        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(playingRow);
        info.Children.Add(_title);
        _subtitle.Margin = new Thickness(0, 4, 0, 0);
        info.Children.Add(_subtitle);
        _source.Margin = new Thickness(0, 6, 0, 0);
        info.Children.Add(_source);
        var header = new DockPanel();
        DockPanel.SetDock(artFrame, Dock.Left);
        header.Children.Add(artFrame);
        header.Children.Add(info);

        _message.Margin = new Thickness(0, 12, 0, 0);
        _message.TextWrapping = TextWrapping.Wrap;

        // Seek bar.
        _seek.Margin = new Thickness(0, 18, 0, 0);
        _seek.PreviewMouseLeftButtonDown += (_, _) => _scrubbing = true;
        _seek.PreviewMouseLeftButtonUp += (_, _) => FinishScrub();
        _seek.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => FinishScrub()));
        _seek.ValueChanged += (_, _) => { if (_scrubbing) _position.Text = Clock((long)_seek.Value); };
        _seek.LostMouseCapture += (_, _) => { if (_scrubbing && Mouse.LeftButton != MouseButtonState.Pressed) FinishScrub(); };
        var times = new DockPanel { Margin = new Thickness(0, 2, 0, 0) };
        DockPanel.SetDock(_duration, Dock.Right);
        times.Children.Add(_duration);
        times.Children.Add(_position);

        // Transport.
        var back = Round(CastIcons.Back10, "Back 10 seconds", 48, () => AppServices.Cast.SeekBy(-10_000));
        var forward = Round(CastIcons.Forward10, "Forward 10 seconds", 48, () => AppServices.Cast.SeekBy(10_000));
        _playPause = Round(CastIcons.Play, "Play", 68, () => AppServices.Cast.TogglePlay());
        _playIcon = (Icon)_playPause.Content;
        _playPause.Background = UiKit.Brush("Amber");
        _playPause.Foreground = UiKit.Brush("OnAmber");
        _playPause.BorderThickness = new Thickness(0);
        ((Icon)_playPause.Content).Size = 34;
        _next = Round(CastIcons.SkipNext, "Next episode", 44, () => _ = AppServices.Cast.PlayNext());
        var transport = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        back.Margin = new Thickness(0, 0, 20, 0);
        forward.Margin = new Thickness(20, 0, 0, 0);
        _next.Margin = new Thickness(20, 0, 0, 0);
        transport.Children.Add(back);
        transport.Children.Add(_playPause);
        transport.Children.Add(forward);
        transport.Children.Add(_next);

        // Volume (Chromecast).
        _mute = Round(CastIcons.VolumeUp, "Mute", 36, () => AppServices.Cast.SetMuted(!AppServices.Cast.State.Muted));
        _mute.Margin = new Thickness(0, 0, 10, 0);
        _volume.ValueChanged += (_, _) =>
        {
            if (_settingVolume) return;
            _changingVolume = true;
            AppServices.Cast.SetVolume(_volume.Value);
        };
        _volume.PreviewMouseLeftButtonUp += (_, _) => _changingVolume = false;
        _volumeRow.Children.Add(_mute);
        _volumeRow.Children.Add(_volume);

        // Tracks + stop.
        _audio = UiKit.Button("Audio", "Button.Ghost");
        ButtonAssist.SetIcon(_audio, CastIcons.Audiotrack);
        _audio.Click += (_, _) => ShowAudioMenu();
        _subtitles = UiKit.Button("Subtitles off", "Button.Ghost");
        ButtonAssist.SetIcon(_subtitles, CastIcons.Subtitles);
        _subtitles.Click += (_, _) => ShowSubtitleMenu();
        var stop = UiKit.Button("Stop casting", "Button.Ghost");
        ButtonAssist.SetIcon(stop, CastIcons.Cast);
        stop.Click += async (_, _) =>
        {
            try { await AppServices.Cast.Disconnect(); }
            catch (Exception e) { App.Log(e); }
        };
        var tracks = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 18, 0, 0) };
        foreach (var b in new[] { _audio, _subtitles, stop })
        {
            b.Margin = new Thickness(4);
            tracks.Children.Add(b);
        }

        var root = new StackPanel();
        root.Children.Add(header);
        root.Children.Add(_message);
        root.Children.Add(_seek);
        root.Children.Add(times);
        root.Children.Add(transport);
        root.Children.Add(_volumeRow);
        root.Children.Add(tracks);
        Content = root;

        Loaded += (_, _) =>
        {
            AppServices.Cast.StateChanged += OnState;
            Apply(AppServices.Cast.State);
        };
        Unloaded += (_, _) => AppServices.Cast.StateChanged -= OnState;
    }

    private void OnState(CastState s) => Dispatcher.BeginInvoke(() => Apply(s));

    private static Button Round(Geometry icon, string tip, double size, Action onClick)
    {
        // The icon is the content (an Icon follows the button's Foreground).
        var b = new Button { Style = UiKit.Style("Button.Icon"), Width = size, Height = size, ToolTip = tip, Content = new Icon { Data = icon, Size = size * 0.5 } };
        System.Windows.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => onClick();
        return b;
    }

    private void FinishScrub()
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        AppServices.Cast.SeekTo((long)_seek.Value);
    }

    private void Apply(CastState s)
    {
        _last = s;
        var media = s.Media;
        _playingOn.Text = $"Playing on {s.DeviceName ?? "TV"}";
        _title.Text = media?.Title ?? PlayerTitle() ?? "";
        _subtitle.Text = media?.Subtitle ?? "";
        _subtitle.Visibility = string.IsNullOrWhiteSpace(media?.Subtitle) ? Visibility.Collapsed : Visibility.Visible;
        var art = media?.PosterUrl ?? media?.BackdropUrl;
        if (_art.Url != art) _art.Url = art;
        _art.FallbackText = media?.Title;

        _source.Text = s.Link != null && s.LinkSource != null
            ? s.LinkSource == LinkStatus.SourcePhone ? "Streaming from this PC · keep it on the network" : "Playing the TV's own copy"
            : "";
        _source.Visibility = _source.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        var warning = s.Link == null ? media?.AudioWarning : null;
        _message.Text = s.Error ?? warning ?? (s.Finished ? "Finished" : "");
        _message.Foreground = s.Error != null ? UiKit.Brush("Danger") : UiKit.Brush("AmberSoft");
        _message.Visibility = _message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        var duration = Math.Max(1, s.DurationMs);
        if (!_scrubbing)
        {
            _seek.Maximum = duration;
            _seek.Value = Math.Clamp(s.PositionMs, 0, duration);
            _position.Text = Clock(s.PositionMs);
        }
        _duration.Text = s.DurationMs > 0 ? Clock(s.DurationMs) : "";

        _playIcon.Data = s.Playing ? CastIcons.Pause : CastIcons.Play;
        _playPause.Content = s.Buffering ? _spinner : _playIcon;
        _playPause.ToolTip = s.Playing ? "Pause" : "Play";
        _next.Visibility = s.HasNext ? Visibility.Visible : Visibility.Collapsed;

        _volumeRow.Visibility = s.Link == null && s.Volume != null ? Visibility.Visible : Visibility.Collapsed;
        ((Icon)_mute.Content).Data = s.Muted ? CastIcons.VolumeOff : CastIcons.VolumeUp;
        _mute.ToolTip = s.Muted ? "Unmute" : "Mute";
        if (s.Volume is { } v && !_changingVolume && !_volume.IsMouseCaptureWithin)
        {
            _settingVolume = true;
            _volume.Value = v;
            _settingVolume = false;
        }

        if (s.Link != null)
        {
            _audio.Visibility = s.LinkAudio.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            _audio.Content = s.LinkAudio.FirstOrDefault(t => t.Id == s.LinkAudioSelected)?.Label ?? "Audio";
            _subtitles.Visibility = s.LinkSubtitles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            _subtitles.Content = s.LinkSubtitles.FirstOrDefault(t => t.Id == s.LinkSubtitleSelected)?.Label ?? "Subtitles off";
        }
        else
        {
            var options = media?.AudioOptions ?? Array.Empty<CastAudioOption>();
            _audio.Visibility = options.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            _audio.Content = options.FirstOrDefault(o => o.Track == media?.AudioTrack)?.Label ?? "Audio";
            var subs = media?.Subtitles ?? Array.Empty<CastSubtitle>();
            _subtitles.Visibility = subs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            _subtitles.Content = subs.FirstOrDefault(x => x.Id == s.ActiveSubtitle)?.Label ?? "Subtitles off";
        }
    }

    private static string? PlayerTitle() => Player.PlayerWindow.Current?.VideoTitle;

    private void ShowAudioMenu()
    {
        var s = _last;
        if (s == null) return;
        var menu = new ContextMenu();
        if (s.Link != null)
        {
            foreach (var t in s.LinkAudio)
            {
                var id = t.Id;
                menu.Items.Add(Item(t.Label, t.Detail, t.Id == s.LinkAudioSelected, () => AppServices.Cast.SelectLinkAudio(id)));
            }
        }
        else if (s.Media != null)
        {
            foreach (var o in s.Media.AudioOptions)
            {
                var track = o.Track;
                menu.Items.Add(Item(o.Label, o.Detail, o.Track == s.Media.AudioTrack, () => _ = AppServices.Cast.SwitchAudio(track)));
            }
        }
        UiKit.ShowMenu(_audio, menu);
    }

    private void ShowSubtitleMenu()
    {
        var s = _last;
        if (s == null) return;
        var menu = new ContextMenu();
        if (s.Link != null)
        {
            menu.Items.Add(Item("Off", null, s.LinkSubtitleSelected == null, () => AppServices.Cast.SelectLinkSubtitle(null)));
            foreach (var t in s.LinkSubtitles)
            {
                var id = t.Id;
                menu.Items.Add(Item(t.Label, t.Detail, t.Id == s.LinkSubtitleSelected, () => AppServices.Cast.SelectLinkSubtitle(id)));
            }
        }
        else if (s.Media != null)
        {
            menu.Items.Add(Item("Off", null, s.ActiveSubtitle == null, () => AppServices.Cast.SelectSubtitle(null)));
            foreach (var sub in s.Media.Subtitles)
            {
                var id = sub.Id;
                menu.Items.Add(Item(sub.Label, null, sub.Id == s.ActiveSubtitle, () => AppServices.Cast.SelectSubtitle(id)));
            }
        }
        UiKit.ShowMenu(_subtitles, menu);
    }

    private static MenuItem Item(string label, string? detail, bool selected, Action onClick)
    {
        var header = new StackPanel();
        header.Children.Add(UiKit.Text(label, "Text.BodyLarge", selected ? "Amber" : "Text", wrap: false));
        if (!string.IsNullOrWhiteSpace(detail)) header.Children.Add(UiKit.Text(detail, "Text.BodySmall", "TextMuted", wrap: false));
        var item = new MenuItem { Header = header, IsChecked = selected };
        item.Click += (_, _) => onClick();
        return item;
    }

    /// <summary>"1:02:03" or "2:03".</summary>
    public static string Clock(long ms)
    {
        var t = TimeSpan.FromMilliseconds(Math.Max(0, ms));
        return t.TotalHours >= 1
            ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", (int)t.TotalHours, t.Minutes, t.Seconds)
            : string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}", t.Minutes, t.Seconds);
    }
}
