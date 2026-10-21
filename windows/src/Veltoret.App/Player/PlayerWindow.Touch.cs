using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Veltoret.App.Controls;
using Veltoret.Core.Player;

namespace Veltoret.App.Player;

/// <summary>
/// Touchscreen gestures on the video (Android player): tap shows or hides the controls; double-tap in the left or
/// right third seeks (further taps on that side keep adding), in the middle toggles full screen; press and hold plays
/// at 2×; a horizontal swipe scrubs (full width = 3 minutes), a vertical swipe on the right half changes the volume;
/// two fingers pinch to zoom (1×–5×) and drag the zoomed picture. The mini player: tap shows its buttons, double-tap
/// expands it, drag moves it. Mouse events Windows makes from these touches are ignored by the mouse handlers.
/// </summary>
public partial class PlayerWindow
{
    private enum TouchMode { None, Pending, Hold, Seek, Volume, Pan, Pinch, MoveWindow }

    private const double TouchSlop = 12;
    private const double DoubleTapMs = 300;

    private readonly Dictionary<TouchDevice, Point> _touches = new();
    /// <summary>When each finger last reported (a finger on the screen reports many times a second, even holding still).</summary>
    private readonly Dictionary<TouchDevice, long> _touchSeen = new();
    private readonly DispatcherTimer _tapTimer = new() { Interval = TimeSpan.FromMilliseconds(DoubleTapMs) };
    private readonly DispatcherTimer _touchHoldTimer = new() { Interval = TimeSpan.FromMilliseconds(450) };
    private TouchMode _touchMode;
    private Point _touchStart;
    private Point _touchLast;
    private long _swipeFrom;
    private long _swipeTarget;
    private int _swipeVolumeFrom;
    private double _pinchDistance;
    private double _pinchZoom;
    private Point _pinchCenter;
    private long _lastTapAt;
    private Point _lastTapPoint;

    private void HookTouch()
    {
        Overlay.PreviewTouchDown += OnVideoTouchDown;
        Overlay.PreviewTouchMove += OnVideoTouchMove;
        Overlay.PreviewTouchUp += OnVideoTouchUp;
        Overlay.LostTouchCapture += (_, e) =>
        {
            if (_touches.Remove(e.TouchDevice) && _touches.Count == 0) EndTouchGesture(cancelled: true);
        };
        // Hold is 2× speed here, not the system's right-click ring.
        Stylus.SetIsPressAndHoldEnabled(Overlay, false);
        Stylus.SetIsFlicksEnabled(Overlay, false);
        _tapTimer.Tick += (_, _) =>
        {
            _tapTimer.Stop();
            ToggleControls();
        };
        _touchHoldTimer.Tick += (_, _) =>
        {
            _touchHoldTimer.Stop();
            if (_touchMode == TouchMode.Pending && !_locked && !_mini && IsActuallyPlaying)
            {
                _touchMode = TouchMode.Hold;
                _tapTimer.Stop();
                BeginHold();
            }
        };
    }

    private void OnVideoTouchDown(object? sender, TouchEventArgs e)
    {
        DropSilentTouches();
        // Buttons, the seek bar, panels and cards get the touch as a normal click or drag.
        if (_touches.Count == 0 && !IsVideoHit(e.OriginalSource)) return;
        var p = e.GetTouchPoint(Overlay).Position;
        _touches[e.TouchDevice] = p;
        _touchSeen[e.TouchDevice] = Environment.TickCount64;
        e.TouchDevice.Capture(Overlay);
        e.Handled = true;
        BumpInteraction();
        if (_touches.Count == 1)
        {
            _touchMode = TouchMode.Pending;
            _touchStart = _touchLast = p;
            if (!_locked && !_mini && _playWhenReady && IsActuallyPlaying) _touchHoldTimer.Start();
            return;
        }
        // Second finger: pinch to zoom (not while locked or in the mini player).
        _touchHoldTimer.Stop();
        _tapTimer.Stop();
        if (_touchMode == TouchMode.Hold) EndHold();
        // The first finger may already have started a swipe: a second one means pinch, so undo it.
        if (_touchMode == TouchMode.Seek) _scrubbing = false;
        if (_touchMode == TouchMode.Volume)
        {
            _volume = _swipeVolumeFrom;
            _mp.Volume = _volume;
        }
        if (_touchMode is TouchMode.Seek or TouchMode.Volume) Fade(Hud, 0, 120);
        if (_locked || _mini || _touches.Count != 2)
        {
            _touchMode = TouchMode.None;
            return;
        }
        _touchMode = TouchMode.Pinch;
        var (a, b) = TwoTouches();
        _pinchDistance = Math.Max(1, (a - b).Length);
        _pinchZoom = _zoom;
        _pinchCenter = Mid(a, b);
    }

    private void OnVideoTouchMove(object? sender, TouchEventArgs e)
    {
        if (!_touches.ContainsKey(e.TouchDevice)) return;
        var p = e.GetTouchPoint(Overlay).Position;
        _touches[e.TouchDevice] = p;
        _touchSeen[e.TouchDevice] = Environment.TickCount64;
        e.Handled = true;
        var w = Math.Max(1, Overlay.ActualWidth);
        var h = Math.Max(1, Overlay.ActualHeight);
        switch (_touchMode)
        {
            case TouchMode.Pending:
            {
                var d = p - _touchStart;
                if (Math.Abs(d.X) < TouchSlop && Math.Abs(d.Y) < TouchSlop) return;
                _touchHoldTimer.Stop();
                _touchMode = DecideSwipe(d, w, h);
                _touchLast = p;
                if (_touchMode == TouchMode.Seek)
                {
                    _swipeFrom = _swipeTarget = Position;
                    _scrubbing = true; // keeps the controls from hiding while scrubbing
                }
                else if (_touchMode == TouchMode.Volume) _swipeVolumeFrom = _volume;
                // Start from the finger's current spot so the value doesn't jump by the slop.
                _touchStart = p;
                return;
            }
            case TouchMode.Seek:
            {
                var (delta, target) = PlayerMath.SwipeSeek(_swipeFrom, Duration, p.X - _touchStart.X, w);
                _swipeTarget = target;
                ShowHud(PlayerFormat.SwipeSeek(delta, target), delta < 0 ? "P.Icon.Rewind" : "P.Icon.Forward");
                break;
            }
            case TouchMode.Volume:
            {
                _volume = PlayerMath.SwipeVolume(_swipeVolumeFrom, p.Y - _touchStart.Y, h);
                _mp.Volume = _volume;
                if (_mp.Mute && _volume > 0) _mp.Mute = false;
                ShowHud(PlayerFormat.Volume(_volume), "P.Icon.Volume");
                break;
            }
            case TouchMode.Pan:
                PanBy(p - _touchLast, w, h);
                _touchLast = p;
                break;
            case TouchMode.MoveWindow:
                // The window follows the finger, so the touch point stays put relative to it.
                Left += p.X - _touchStart.X;
                Top += p.Y - _touchStart.Y;
                break;
            case TouchMode.Pinch when _touches.Count == 2:
            {
                var (a, b) = TwoTouches();
                _zoom = Math.Clamp(_pinchZoom * (a - b).Length / _pinchDistance, 1, 5);
                var center = Mid(a, b);
                if (_zoom > 1.001) PanBy(center - _pinchCenter, w, h);
                _pinchCenter = center;
                ApplyAspect();
                UpdateAspectChip();
                ShowHud(PlayerFormat.Zoom(_zoom), "P.Icon.Zoom");
                break;
            }
        }
        BumpInteraction();
    }

    private void OnVideoTouchUp(object? sender, TouchEventArgs e)
    {
        if (!_touches.Remove(e.TouchDevice)) return;
        e.Handled = true;
        e.TouchDevice.Capture(null);
        if (_touchMode == TouchMode.Pinch || _touches.Count > 0 && _touchMode == TouchMode.None)
        {
            // Lifting one finger ends a pinch; the other is ignored from now on. (WPF can miss the second lift when
            // both fingers come up in the same frame, so don't wait for it.)
            foreach (var other in _touches.Keys.ToList()) other.Capture(null);
            _touches.Clear();
        }
        if (_touches.Count > 0) return;
        if (_touchMode == TouchMode.Pending) OnVideoTap(e.GetTouchPoint(Overlay).Position);
        EndTouchGesture(cancelled: false);
    }

    /// <summary>
    /// WPF sometimes never reports a finger lifting (seen when fingers lift together, or after a long hold). A finger
    /// that has gone quiet is treated as lifted, so 2× or a scrub never sticks. Checked on each touch and every 100 ms.
    /// </summary>
    private void DropSilentTouches()
    {
        if (_touches.Count == 0) return;
        var now = Environment.TickCount64;
        foreach (var d in _touches.Keys.ToList())
        {
            if (now - _touchSeen.GetValueOrDefault(d) < 300) continue;
            _touches.Remove(d);
            d.Capture(null);
        }
        if (_touches.Count > 0) return;
        // No tap from a finger whose lift we never saw.
        if (_touchMode == TouchMode.Pending) _touchMode = TouchMode.None;
        EndTouchGesture(cancelled: false);
    }

    private void EndTouchGesture(bool cancelled)
    {
        _touchHoldTimer.Stop();
        switch (_touchMode)
        {
            case TouchMode.Hold:
                EndHold();
                break;
            case TouchMode.Seek:
                _scrubbing = false;
                if (!cancelled) SeekTo(_swipeTarget);
                break;
            case TouchMode.Pinch:
                if (_zoom < 1.05) SetZoom(1);
                break;
        }
        _touchMode = TouchMode.None;
        _touches.Clear();
        _touchSeen.Clear();
        BumpInteraction();
    }

    /// <summary>What a one-finger drag does, decided once it passes the slop.</summary>
    private TouchMode DecideSwipe(Vector d, double w, double h)
    {
        if (_mini) return TouchMode.MoveWindow;
        if (_locked) return TouchMode.None;
        if (_zoom > 1.001) return TouchMode.Pan;
        // Edges belong to Windows' own swipes (Action Center, task view, app bar).
        if (_touchStart.X < 28 || _touchStart.X > w - 28 || _touchStart.Y < 56 || _touchStart.Y > h - 56) return TouchMode.None;
        if (Math.Abs(d.X) > Math.Abs(d.Y)) return Duration > 0 ? TouchMode.Seek : TouchMode.None;
        // Right half: volume. Left half was brightness on Android; Windows has no per-window brightness.
        return _touchStart.X > w / 2 ? TouchMode.Volume : TouchMode.None;
    }

    private void OnVideoTap(Point p)
    {
        var now = Environment.TickCount64;
        var isDouble = now - _lastTapAt < DoubleTapMs && (p - _lastTapPoint).Length < 80;
        _lastTapAt = isDouble ? 0 : now;
        _lastTapPoint = p;
        if (_mini)
        {
            if (isDouble) ExitMini();
            else
            {
                Fade(MiniControls, 1, 180);
                BumpInteraction();
            }
            return;
        }
        if (_locked)
        {
            ToggleControls();
            return;
        }
        var third = Overlay.ActualWidth / 3;
        var side = p.X < third ? -1 : p.X > 2 * third ? 1 : 0;
        // After a double-tap seek, each further tap on that side seeks again (the ripple adds up).
        if (!isDouble && side != 0 && _ripple is { } r && r.Forward == (side > 0) && (DateTime.UtcNow - r.At).TotalMilliseconds < 900)
        {
            _tapTimer.Stop();
            SeekWithRipple(side > 0, _settings.SeekSeconds);
            return;
        }
        if (!isDouble)
        {
            // Wait for a possible second tap before showing or hiding the controls.
            _tapTimer.Stop();
            _tapTimer.Start();
            return;
        }
        _tapTimer.Stop();
        if (side == 0) ToggleFullscreen();
        else SeekWithRipple(side > 0, _settings.SeekSeconds);
    }

    private void PanBy(Vector d, double w, double h)
    {
        if (_zoom <= 1.001) return;
        _panX = Math.Clamp(_panX - 2 * d.X / w / (_zoom - 1), -1, 1);
        _panY = Math.Clamp(_panY - 2 * d.Y / h / (_zoom - 1), -1, 1);
        ApplyAspect();
    }

    private (Point A, Point B) TwoTouches()
    {
        var v = _touches.Values.Take(2).ToArray();
        return (v[0], v[1]);
    }

    private static Point Mid(Point a, Point b) => new((a.X + b.X) / 2, (a.Y + b.Y) / 2);
}
