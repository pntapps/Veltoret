using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Veltoret.App.Controls;

/// <summary>
/// Drag-to-scroll with momentum for every ScrollViewer in the app, like a phone: one finger, axis decided after a
/// small slop, the innermost scroller that can move that way takes it (a vertical swipe over a Home row scrolls the
/// page, a horizontal one scrolls the row). A tap still clicks; a drag never does. A tap while a list is gliding just
/// stops it. Sliders, scroll bars, text selection inside fields and elements marked with <see cref="IsDisabledProperty"/>
/// (the player's video area) keep their own touch handling. <see cref="SwipeProperty"/> gives an element (the Home hero)
/// a horizontal swipe instead of a scroll.
/// </summary>
public static class TouchScroll
{
    private const double Slop = 10;
    /// <summary>Momentum fades with this time constant (ms), about what iOS and Android lists use.</summary>
    private const double FrictionMs = 325;
    private const double MaxVelocity = 6; // DIP per ms

    public static readonly DependencyProperty IsDisabledProperty = DependencyProperty.RegisterAttached(
        "IsDisabled", typeof(bool), typeof(TouchScroll), new PropertyMetadata(false));

    public static bool GetIsDisabled(DependencyObject o) => (bool)o.GetValue(IsDisabledProperty);
    public static void SetIsDisabled(DependencyObject o, bool v) => o.SetValue(IsDisabledProperty, v);

    /// <summary>Called with −1 (swipe right: previous) or +1 (swipe left: next) after a horizontal swipe on the element.</summary>
    public static readonly DependencyProperty SwipeProperty = DependencyProperty.RegisterAttached(
        "Swipe", typeof(Action<int>), typeof(TouchScroll), new PropertyMetadata(null));

    public static Action<int>? GetSwipe(DependencyObject o) => (Action<int>?)o.GetValue(SwipeProperty);
    public static void SetSwipe(DependencyObject o, Action<int>? v) => o.SetValue(SwipeProperty, v);

    private sealed class Gesture
    {
        public required TouchDevice Device;
        public required UIElement Root;
        public required Point Start;
        public required List<ScrollViewer> Scrollers;
        public FrameworkElement? SwipeTarget;
        public ScrollViewer? Target;
        public bool Horizontal;
        public bool Swiping;
        /// <summary>This touch stopped a glide: it mustn't click either.</summary>
        public bool SuppressClick;
        public double StartOffset;
        public long LastMs = Clock.ElapsedMilliseconds;
        public readonly Queue<(long Ms, double Pos)> Samples = new();
    }

    private static Gesture? _g;
    private static RoutedEventArgs? _last;
    private static readonly Stopwatch Clock = Stopwatch.StartNew();

    internal static void Install()
    {
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewTouchDownEvent, new EventHandler<TouchEventArgs>(OnDown), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewTouchMoveEvent, new EventHandler<TouchEventArgs>(OnMove), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewTouchUpEvent, new EventHandler<TouchEventArgs>(OnUp), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.LostTouchCaptureEvent, new EventHandler<TouchEventArgs>(OnLost), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewMouseWheelEvent, new MouseWheelEventHandler((_, _) => StopFling()), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewMouseDownEvent, new MouseButtonEventHandler(SwallowClick), true);
        EventManager.RegisterClassHandler(typeof(UIElement), UIElement.PreviewMouseUpEvent, new MouseButtonEventHandler(SwallowClick), true);
    }

    /// <summary>Until when mouse buttons made from the last touch are ignored (that touch scrolled or swiped).</summary>
    private static long _swallowUntil;

    /// <summary>
    /// With WM_POINTER input, Windows sends the mouse down/up for a touch after the finger lifts, at the lift point:
    /// after a drag that would click whatever ended up under the finger. Drags therefore swallow their mouse clicks.
    /// </summary>
    private static void SwallowClick(object sender, MouseButtonEventArgs e)
    {
        if (Environment.TickCount64 < _swallowUntil && TouchInput.IsFromTouch(e)) e.Handled = true;
    }

    /// <summary>Each routed event reaches a UIElement class handler once per element on its route: act on the first.</summary>
    private static bool Seen(RoutedEventArgs e)
    {
        if (ReferenceEquals(e, _last)) return true;
        _last = e;
        return false;
    }

    private static DependencyObject? Parent(DependencyObject d) =>
        d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);

    private static void OnDown(object? sender, TouchEventArgs e)
    {
        if (Seen(e)) return;
        // A gesture that went quiet (its lift was missed: WPF can drop one when two fingers lift together) is over.
        if (_g != null && Clock.ElapsedMilliseconds - _g.LastMs > 500) _g = null;
        // A drag that ended without its lift reported must not keep swallowing clicks.
        if (_g == null && _swallowUntil == long.MaxValue) _swallowUntil = 0;
        if (_g != null)
        {
            // A second finger: leave pinches and two-finger gestures alone.
            if (_g.Target == null && !_g.Swiping) _g = null;
            return;
        }
        var root = (UIElement)sender!;
        var scrollers = new List<ScrollViewer>();
        FrameworkElement? swipe = null;
        for (var d = e.OriginalSource as DependencyObject; d != null; d = Parent(d))
        {
            if (GetIsDisabled(d) || d is ScrollBar or Thumb or Slider) return;
            // A drag that starts inside a focused text field selects text there instead of scrolling.
            if (d is TextBoxBase or PasswordBox && ((UIElement)d).IsKeyboardFocusWithin) return;
            if (d is ScrollViewer sv && sv.PanningMode == PanningMode.None && sv.TemplatedParent is not (TextBoxBase or PasswordBox)) scrollers.Add(sv);
            if (swipe == null && d is FrameworkElement fe && GetSwipe(fe) != null) swipe = fe;
        }
        if (scrollers.Count == 0 && swipe == null) return;
        // Touching a gliding list stops it, and that touch doesn't click what's under the finger.
        if (_fling is { } f && scrollers.Contains(f.Scroller))
        {
            StopFling();
            e.Handled = true;
            _swallowUntil = long.MaxValue;
        }
        _g = new Gesture { Device = e.TouchDevice, Root = root, Start = e.GetTouchPoint(root).Position, Scrollers = scrollers, SwipeTarget = swipe, SuppressClick = e.Handled };
    }

    private static void OnMove(object? sender, TouchEventArgs e)
    {
        if (Seen(e) || _g is not { } g || e.TouchDevice != g.Device) return;
        g.LastMs = Clock.ElapsedMilliseconds;
        var p = e.GetTouchPoint(g.Root).Position;
        var dx = p.X - g.Start.X;
        var dy = p.Y - g.Start.Y;
        if (g.Target == null && !g.Swiping)
        {
            if (Math.Abs(dx) < Slop && Math.Abs(dy) < Slop) return;
            g.Horizontal = Math.Abs(dx) > Math.Abs(dy);
            var delta = g.Horizontal ? dx : dy;
            g.Target = Pick(g.Scrollers, g.Horizontal, delta);
            // A horizontal drag on the hero swipes it, unless a row inside it scrolls sideways.
            if (g.Horizontal && g.SwipeTarget != null && (g.Target == null || !IsAncestor(g.SwipeTarget, g.Target))) g.Target = null;
            if (g.Target == null)
            {
                if (g.Horizontal && g.SwipeTarget != null) g.Swiping = true;
                else
                {
                    _g = null;
                    return;
                }
            }
            // From here it's a drag: whatever the finger pressed (a card, a button) must not click.
            Mouse.Captured?.ReleaseMouseCapture();
            _swallowUntil = long.MaxValue;
            e.TouchDevice.Capture(g.Target ?? (IInputElement)g.SwipeTarget!);
            if (g.Target is { } t)
            {
                SmoothScroll.Stop(t);
                // Start from where the finger is now so the content doesn't jump by the slop.
                g.Start = p;
                g.StartOffset = g.Horizontal ? t.HorizontalOffset : t.VerticalOffset;
            }
        }
        e.Handled = true;
        if (g.Swiping) return;
        var target = g.Target!;
        var pos = g.Horizontal ? p.X - g.Start.X : p.Y - g.Start.Y;
        var scale = UnitsPerDip(target, g.Horizontal);
        var to = g.StartOffset - pos * scale;
        if (g.Horizontal) target.ScrollToHorizontalOffset(Math.Clamp(to, 0, target.ScrollableWidth));
        else target.ScrollToVerticalOffset(Math.Clamp(to, 0, target.ScrollableHeight));
        var now = Clock.ElapsedMilliseconds;
        g.Samples.Enqueue((now, pos));
        while (g.Samples.Count > 2 && now - g.Samples.Peek().Ms > 100) g.Samples.Dequeue();
    }

    private static void OnUp(object? sender, TouchEventArgs e)
    {
        if (Seen(e) || _g is not { } g || e.TouchDevice != g.Device) return;
        _g = null;
        if (g.Target != null || g.Swiping || g.SuppressClick) _swallowUntil = Environment.TickCount64 + 400;
        if (g.Target == null && !g.Swiping) return;
        e.Handled = true;
        e.TouchDevice.Capture(null);
        if (g.Swiping)
        {
            var dx = e.GetTouchPoint(g.Root).Position.X - g.Start.X;
            if (Math.Abs(dx) > 48) GetSwipe(g.SwipeTarget!)?.Invoke(dx < 0 ? 1 : -1);
            return;
        }
        var samples = g.Samples.ToArray();
        if (samples.Length < 2) return;
        var (t0, p0) = samples[0];
        var (t1, p1) = samples[^1];
        // A finger that stopped before lifting doesn't fling.
        if (t1 - t0 < 8 || Clock.ElapsedMilliseconds - t1 > 60) return;
        var v = Math.Clamp((p1 - p0) / (t1 - t0), -MaxVelocity, MaxVelocity);
        if (Math.Abs(v) > 0.15) StartFling(g.Target!, g.Horizontal, v);
    }

    private static void OnLost(object? sender, TouchEventArgs e)
    {
        // Capture taken away mid-drag (the window lost focus): end the gesture.
        if (_g is { } g && e.TouchDevice == g.Device && ReferenceEquals(sender, g.Target ?? (object?)g.SwipeTarget))
        {
            _g = null;
            _swallowUntil = Environment.TickCount64 + 400;
        }
    }

    /// <summary>The innermost scroller that can move along the axis in the drag's direction, else the innermost that scrolls on it at all.</summary>
    private static ScrollViewer? Pick(List<ScrollViewer> scrollers, bool horizontal, double delta)
    {
        ScrollViewer? any = null;
        foreach (var sv in scrollers)
        {
            var range = horizontal ? sv.ScrollableWidth : sv.ScrollableHeight;
            var disabled = horizontal ? sv.HorizontalScrollBarVisibility == ScrollBarVisibility.Disabled : sv.VerticalScrollBarVisibility == ScrollBarVisibility.Disabled;
            if (range <= 0.5 || disabled) continue;
            any ??= sv;
            var offset = horizontal ? sv.HorizontalOffset : sv.VerticalOffset;
            // Finger moving down/right reveals what's above/left.
            if (delta > 0 ? offset > 0.5 : offset < range - 0.5) return sv;
        }
        return any;
    }

    private static bool IsAncestor(DependencyObject ancestor, DependencyObject d)
    {
        for (var x = d; x != null; x = Parent(x)) if (ReferenceEquals(x, ancestor)) return true;
        return false;
    }

    /// <summary>Offsets are pixels, except lists that scroll by item: convert the finger's movement.</summary>
    private static double UnitsPerDip(ScrollViewer sv, bool horizontal)
    {
        if (!sv.CanContentScroll || sv.TemplatedParent is not ItemsControl owner) return 1;
        if (!VirtualizingPanel.GetIsVirtualizing(owner) || VirtualizingPanel.GetScrollUnit(owner) == ScrollUnit.Pixel) return 1;
        // Viewport is measured in items here; the scroller's size is in DIPs.
        var size = horizontal ? sv.ViewportWidth : sv.ViewportHeight;
        var actual = horizontal ? sv.ActualWidth : sv.ActualHeight;
        return actual > 0 ? size / actual : 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Momentum

    private sealed class Fling
    {
        public required ScrollViewer Scroller;
        public required bool Horizontal;
        public double Velocity;
        public double Offset;
        public long LastMs;
    }

    private static Fling? _fling;

    private static void StartFling(ScrollViewer sv, bool horizontal, double velocity)
    {
        StopFling();
        _fling = new Fling
        {
            Scroller = sv, Horizontal = horizontal, Velocity = velocity,
            Offset = horizontal ? sv.HorizontalOffset : sv.VerticalOffset, LastMs = Clock.ElapsedMilliseconds,
        };
        CompositionTarget.Rendering += OnFrame;
    }

    public static void StopFling()
    {
        if (_fling == null) return;
        _fling = null;
        CompositionTarget.Rendering -= OnFrame;
    }

    private static void OnFrame(object? sender, EventArgs e)
    {
        if (_fling is not { } f) return;
        var now = Clock.ElapsedMilliseconds;
        var dt = Math.Clamp(now - f.LastMs, 1, 50);
        f.LastMs = now;
        var sv = f.Scroller;
        var range = f.Horizontal ? sv.ScrollableWidth : sv.ScrollableHeight;
        f.Offset -= f.Velocity * dt * UnitsPerDip(sv, f.Horizontal);
        f.Velocity *= Math.Exp(-dt / FrictionMs);
        var clamped = Math.Clamp(f.Offset, 0, range);
        if (f.Horizontal) sv.ScrollToHorizontalOffset(clamped);
        else sv.ScrollToVerticalOffset(clamped);
        if (Math.Abs(f.Velocity) < 0.02 || clamped != f.Offset || !sv.IsVisible) StopFling();
    }
}
