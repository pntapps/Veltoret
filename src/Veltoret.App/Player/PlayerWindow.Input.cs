using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.Core.Player;

namespace Veltoret.App.Player;

public partial class PlayerWindow
{
    private KeyEventArgs? _lastKey;
    private int _keyRepeat;
    private (bool Forward, int Total, DateTime At)? _ripple;

    private Point _pressPoint;
    private bool _pressOnVideo;
    private bool _holding;
    private bool _panning;
    private float _speedBeforeHold = 1f;
    private Point _lastMouse = new(double.NaN, double.NaN);

    // ---------------------------------------------------------------------------------------------
    // Keyboard
    // ---------------------------------------------------------------------------------------------

    private void OnAnyKeyDown(object sender, KeyEventArgs e)
    {
        if (ReferenceEquals(e, _lastKey) || _closing) return;
        _lastKey = e;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        _keyRepeat = e.IsRepeat ? _keyRepeat + 1 : 0;

        if (key == Key.Escape)
        {
            e.Handled = true;
            if (PanelOpen) ClosePanel();
            else if (_mini) ExitMini();
            else if (_fullscreen) ExitFullscreen();
            else if (!_locked) Close();
            return;
        }
        if (_locked)
        {
            // While locked only the unlock shortcut works (a key press shows the Unlock button).
            if (ctrl && key == Key.L) Unlock();
            else
            {
                _controlsVisible = true;
                ApplyChromeVisibility();
                BumpInteraction();
            }
            e.Handled = true;
            return;
        }

        var seekStep = _settings.SeekSeconds * (_keyRepeat > 20 ? 6 : _keyRepeat > 6 ? 3 : 1);
        var handled = true;
        switch (key)
        {
            case Key.Space or Key.K or Key.MediaPlayPause or Key.Play:
                TogglePlay();
                if (!_playWhenReady) ShowControls();
                break;
            case Key.Enter when !PanelOpen:
                TogglePlay();
                if (!_playWhenReady) ShowControls();
                break;
            case Key.Pause or Key.MediaStop:
                Pause();
                ShowControls();
                break;
            case Key.J or Key.Left:
                SeekWithRipple(false, seekStep);
                break;
            case Key.L when ctrl:
                OnLockClick(this, new RoutedEventArgs());
                break;
            case Key.L or Key.Right:
                SeekWithRipple(true, seekStep);
                break;
            case Key.Up:
                ChangeVolume(5);
                break;
            case Key.Down:
                ChangeVolume(-5);
                break;
            case Key.M or Key.VolumeMute:
                ToggleMute();
                break;
            case Key.N or Key.MediaNextTrack:
                PlayNext();
                break;
            case Key.P:
                PlayPrevious();
                break;
            case Key.MediaPreviousTrack:
                if (_previous != null) PlayPrevious();
                else SeekTo(0);
                break;
            case Key.F or Key.F11:
                ToggleFullscreen();
                break;
            case Key.OemOpenBrackets:
                SetSpeed(PlayerMath.StepSpeed(_speed, -1));
                ShowHud(PlayerFormat.SpeedOption(_speed), "P.Icon.Speed");
                break;
            case Key.OemCloseBrackets:
                SetSpeed(PlayerMath.StepSpeed(_speed, 1));
                ShowHud(PlayerFormat.SpeedOption(_speed), "P.Icon.Speed");
                break;
            case Key.S or Key.C or Key.V:
                CycleSubtitles();
                break;
            case Key.A:
                CycleAudio();
                break;
            case Key.G:
                NudgeSync(-100);
                break;
            case Key.H:
                NudgeSync(100);
                break;
            case Key.Z:
                CycleAspect();
                ShowHud(_resize, "P.Icon.Aspect");
                break;
            case Key.I:
                if (_panel == PanelKind.Info) ClosePanel();
                else OpenPanel(PanelKind.Info);
                break;
            case Key.Home:
                StartOver();
                break;
            case Key.Tab when _isEpisode && PlayerMath.SkipIntroVisible(_isEpisode, _introSkipped, false, false, Position):
                SkipIntro();
                break;
            default:
                handled = false;
                break;
        }
        if (handled)
        {
            e.Handled = true;
            BumpInteraction();
        }
    }

    private void OnAnyKeyUp(object sender, KeyEventArgs e)
    {
        if (!e.IsRepeat) _keyRepeat = 0;
    }

    /// <summary>Seek with the double-tap style feedback; same direction within 1.2 s adds up ("30 seconds").</summary>
    private void SeekWithRipple(bool forward, int stepSeconds)
    {
        var now = DateTime.UtcNow;
        var since = _ripple is { } r ? (long)(now - r.At).TotalMilliseconds : long.MaxValue;
        var total = PlayerMath.AccumulateSeek(_ripple?.Total, _ripple?.Forward == forward, since, stepSeconds);
        _ripple = (forward, total, now);
        SeekBy((forward ? 1 : -1) * stepSeconds * 1000L);
        if (_mini) return;
        var show = forward ? RippleRight : RippleLeft;
        var hide = forward ? RippleLeft : RippleRight;
        (forward ? RippleRightText : RippleLeftText).Text = $"{total} seconds";
        hide.BeginAnimation(OpacityProperty, null);
        hide.Opacity = 0;
        show.BeginAnimation(OpacityProperty, null);
        show.Opacity = 1;
        _rippleTimer.Stop();
        _rippleTimer.Start();
    }

    private void CycleAudio()
    {
        var tracks = AudioTracks();
        if (tracks.Count == 0)
        {
            ShowHud("No audio tracks", "P.Icon.Audio");
            return;
        }
        var titles = MediaFormats.TrackTitles(tracks.Select(t => (t.Language, t.Label)).ToList(), "Track");
        var i = tracks.FindIndex(t => t.Id == _mp.AudioTrack);
        var next = (i + 1) % tracks.Count;
        SelectAudio(tracks[next]);
        ShowHud("Audio: " + titles[next], "P.Icon.Audio");
    }

    private void CycleSubtitles()
    {
        var embedded = EmbeddedSubtitleTracks();
        var titles = MediaFormats.TrackTitles(embedded.Select(t => (t.Language, t.Label)).ToList(), "Subtitle");
        // Off, then the video's tracks, then files.
        var options = new List<(string Title, Action Select, bool Current)> { ("Off", DisableSubtitles, false) };
        var spu = _mp.Spu;
        for (var n = 0; n < embedded.Count; n++)
        {
            var t = embedded[n];
            options.Add((titles[n], () => SelectEmbeddedSubtitle(t), _selectedExternal == null && t.Id == spu));
        }
        foreach (var x in _externals)
        {
            var id = x.Id;
            options.Add((x.Label, () => SelectExternal(id), _selectedExternal == id));
        }
        var current = options.FindIndex(o => o.Current);
        if (current < 0) current = 0;
        var next = options[(current + 1) % options.Count];
        next.Select();
        ShowHud(next.Title == "Off" ? "Subtitles off" : "Subtitles: " + next.Title, "P.Icon.Subtitles");
        RefreshPanelIfOpen();
    }

    private void NudgeSync(long delta)
    {
        if (_selectedExternal == null)
        {
            ShowHud("Sync works with subtitle files", "P.Icon.Subtitles");
            return;
        }
        SetSubtitleOffset(_subtitleOffsetMs + delta);
        ShowHud("Sync: " + PlayerFormat.SyncLabel(_subtitleOffsetMs), "P.Icon.Subtitles");
        RefreshPanelIfOpen();
    }

    // ---------------------------------------------------------------------------------------------
    // Mouse on the video
    // ---------------------------------------------------------------------------------------------

    /// <summary>True when the click landed on the video itself rather than a control, card or panel.</summary>
    private bool IsVideoHit(object source)
    {
        for (var d = source as DependencyObject; d != null && d != Overlay; d = ParentOf(d))
        {
            if (d is ButtonBase or ScrollBar or Thumb or TextBox) return false;
            if (d is FrameworkElement { Tag: "ui" }) return false;
        }
        return true;
    }

    private static DependencyObject? ParentOf(DependencyObject d) =>
        d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);

    private void OnOverlayMouseMove(object sender, MouseEventArgs e)
    {
        // A tap moves the pointer to the finger: that isn't the mouse moving (it would show the controls the tap hides).
        if (TouchInput.IsFromTouch(e)) return;
        var p = e.GetPosition(Overlay);
        var moved = double.IsNaN(_lastMouse.X) || Math.Abs(p.X - _lastMouse.X) + Math.Abs(p.Y - _lastMouse.Y) > 2;
        _lastMouse = p;
        if (_mini)
        {
            if (moved)
            {
                Fade(MiniControls, 1, 180);
                BumpInteraction();
            }
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed && _pressOnVideo)
        {
            var dx = p.X - _pressPoint.X;
            var dy = p.Y - _pressPoint.Y;
            if (!_panning && Math.Abs(dx) + Math.Abs(dy) > 6)
            {
                _holdTimer.Stop();
                if (_zoom > 1.001 && !_locked) _panning = true;
            }
            if (_panning)
            {
                var w = Math.Max(1, Overlay.ActualWidth);
                var h = Math.Max(1, Overlay.ActualHeight);
                _panX = Math.Clamp(_panX - 2 * dx / w / (_zoom - 1), -1, 1);
                _panY = Math.Clamp(_panY - 2 * dy / h / (_zoom - 1), -1, 1);
                _pressPoint = p;
                ApplyAspect();
            }
            return;
        }
        if (moved) ShowControls();
    }

    private void OnOverlayMouseDown(object sender, MouseButtonEventArgs e)
    {
        // Touches on the video are handled as gestures (PlayerWindow.Touch); on buttons they click as usual.
        if (TouchInput.IsFromTouch(e))
        {
            if (IsVideoHit(e.OriginalSource)) e.Handled = true;
            else BumpInteraction();
            return;
        }
        if (!IsVideoHit(e.OriginalSource))
        {
            _pressOnVideo = false;
            BumpInteraction();
            return;
        }
        _pressOnVideo = true;
        _pressPoint = e.GetPosition(Overlay);
        _panning = false;
        if (_mini)
        {
            e.Handled = true;
            if (e.ClickCount >= 2) ExitMini();
            else NativeMethods.BeginDrag(this);
            return;
        }
        if (e.ClickCount == 1)
        {
            if (!_locked && _playWhenReady && IsActuallyPlaying) _holdTimer.Start();
            return;
        }
        // Double-click (and each further click): left third back, right third forward, middle full screen.
        _clickTimer.Stop();
        _holdTimer.Stop();
        e.Handled = true;
        if (_locked) return;
        var third = Overlay.ActualWidth / 3;
        var x = _pressPoint.X;
        if (x < third) SeekWithRipple(false, _settings.SeekSeconds);
        else if (x > 2 * third) SeekWithRipple(true, _settings.SeekSeconds);
        else if (e.ClickCount == 2) ToggleFullscreen();
        _pressOnVideo = false;
    }

    private void OnOverlayMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (TouchInput.IsFromTouch(e))
        {
            if (IsVideoHit(e.OriginalSource)) e.Handled = true;
            return;
        }
        _holdTimer.Stop();
        if (_holding)
        {
            EndHold();
            e.Handled = true;
            _pressOnVideo = false;
            return;
        }
        if (_panning)
        {
            _panning = false;
            _pressOnVideo = false;
            return;
        }
        if (_pressOnVideo && !_mini)
        {
            // Wait for a possible double-click before toggling the controls.
            _clickTimer.Stop();
            _clickTimer.Start();
        }
        _pressOnVideo = false;
    }

    private void StartHold()
    {
        if (_locked || !_pressOnVideo || _panning || !IsActuallyPlaying) return;
        BeginHold();
    }

    /// <summary>2× while the mouse button or finger stays down.</summary>
    private void BeginHold()
    {
        _holding = true;
        _speedBeforeHold = _speed;
        _mp.SetRate(2f);
        HudText.Text = "2× speed";
        HudIcon.Data = (Geometry)Overlay.FindResource("P.Icon.Forward");
        _hudTimer.Stop();
        Hud.BeginAnimation(OpacityProperty, null);
        Fade(Hud, 1, 150);
    }

    private void EndHold()
    {
        _holding = false;
        SetSpeed(Math.Abs(_speedBeforeHold - 2f) < 0.001f ? 1f : _speedBeforeHold);
        Fade(Hud, 0, 220);
    }

    private void OnOverlayWheel(object sender, MouseWheelEventArgs e)
    {
        if (!IsVideoHit(e.OriginalSource) && PanelOpen) return;
        if (!IsVideoHit(e.OriginalSource) && e.OriginalSource is DependencyObject d && FindScrollViewer(d)) return;
        e.Handled = true;
        var notches = e.Delta / 120.0;
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            if (_locked || _mini) return;
            SetZoom(_zoom * Math.Pow(1.1, notches));
        }
        else ChangeVolume((int)Math.Round(5 * notches));
        BumpInteraction();
    }

    private bool FindScrollViewer(DependencyObject d)
    {
        for (var x = d; x != null && x != Overlay; x = ParentOf(x))
            if (x is ScrollViewer) return true;
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // Seek bar: click seeks, drag previews and seeks on release (also when the drag is cancelled)
    // ---------------------------------------------------------------------------------------------

    private void OnSeekDown(object sender, MouseButtonEventArgs e)
    {
        if (Duration <= 0) return;
        _scrubbing = true;
        _scrubFraction = Fraction(e);
        SeekArea.CaptureMouse();
        e.Handled = true;
        BumpInteraction();
        UpdateUi();
    }

    private void OnSeekMove(object sender, MouseEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubFraction = Fraction(e);
        UpdateUi();
    }

    private void OnSeekUp(object sender, MouseButtonEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubFraction = Fraction(e);
        FinishScrub();
        SeekArea.ReleaseMouseCapture();
        e.Handled = true;
    }

    private void OnSeekLostCapture(object sender, MouseEventArgs e)
    {
        if (_scrubbing) FinishScrub();
    }

    private void FinishScrub()
    {
        _scrubbing = false;
        var duration = Duration;
        if (duration > 0) SeekTo((long)(_scrubFraction * duration));
        BumpInteraction();
    }

    private double Fraction(MouseEventArgs e) =>
        SeekArea.ActualWidth > 0 ? Math.Clamp(e.GetPosition(SeekArea).X / SeekArea.ActualWidth, 0, 1) : 0;
}
