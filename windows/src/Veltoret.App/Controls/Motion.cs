using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Veltoret.App.Controls;

/// <summary>
/// Android ui/components/Motion.kt: press scale (cards 0.96, buttons 0.97, springy) and the one-time entrance
/// (fade in + rise 18 px after index × 70 ms). Use as attached properties:
/// <c>c:Motion.PressScale="0.96"</c>, <c>c:Motion.Entrance="1"</c>.
/// </summary>
public static class Motion
{
    private static readonly IEasingFunction Spring = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut };
    private static readonly IEasingFunction FastOutSlowIn = new CubicEase { EasingMode = EasingMode.EaseOut };

    // ---------- Press scale ----------

    public static readonly DependencyProperty PressScaleProperty = DependencyProperty.RegisterAttached(
        "PressScale", typeof(double), typeof(Motion), new PropertyMetadata(1.0, OnPressScaleChanged));

    public static double GetPressScale(DependencyObject o) => (double)o.GetValue(PressScaleProperty);
    public static void SetPressScale(DependencyObject o, double v) => o.SetValue(PressScaleProperty, v);

    private static void OnPressScaleChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not UIElement el) return;
        el.PreviewMouseLeftButtonDown -= OnDown;
        el.PreviewMouseLeftButtonUp -= OnUp;
        el.MouseLeave -= OnLeave;
        el.LostMouseCapture -= OnLeave;
        if ((double)e.NewValue >= 1.0) return;
        el.RenderTransformOrigin = new Point(0.5, 0.5);
        el.PreviewMouseLeftButtonDown += OnDown;
        el.PreviewMouseLeftButtonUp += OnUp;
        el.MouseLeave += OnLeave;
        el.LostMouseCapture += OnLeave;
    }

    private static ScaleTransform ScaleOf(UIElement el)
    {
        // Entrance and press share one TransformGroup: [scale, translate].
        var group = GroupOf(el);
        return (ScaleTransform)group.Children[0];
    }

    private static TransformGroup GroupOf(UIElement el)
    {
        if (el.RenderTransform is TransformGroup g && g.Children.Count == 2 && g.Children[0] is ScaleTransform && !g.IsFrozen) return g;
        g = new TransformGroup();
        g.Children.Add(new ScaleTransform());
        g.Children.Add(new TranslateTransform());
        el.RenderTransform = g;
        return g;
    }

    private static void AnimateScale(UIElement el, double to, int ms)
    {
        var s = ScaleOf(el);
        var a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = Spring };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
    }

    private static void OnDown(object sender, MouseButtonEventArgs e)
    {
        var el = (UIElement)sender;
        if (!el.IsEnabled) return;
        AnimateScale(el, GetPressScale(el), 150);
    }

    private static void OnUp(object sender, MouseButtonEventArgs e) => AnimateScale((UIElement)sender, 1.0, 220);
    private static void OnLeave(object sender, EventArgs e) => AnimateScale((UIElement)sender, 1.0, 220);

    // ---------- Entrance (plays once per element) ----------

    private static readonly ConditionalWeakTable<object, object> Played = new();

    public static readonly DependencyProperty EntranceProperty = DependencyProperty.RegisterAttached(
        "Entrance", typeof(int), typeof(Motion), new PropertyMetadata(-1, OnEntranceChanged));

    public static int GetEntrance(DependencyObject o) => (int)o.GetValue(EntranceProperty);
    public static void SetEntrance(DependencyObject o, int v) => o.SetValue(EntranceProperty, v);

    /// <summary>Extra delay (ms) added before index × 70 ms.</summary>
    public static readonly DependencyProperty EntranceDelayProperty = DependencyProperty.RegisterAttached(
        "EntranceDelay", typeof(int), typeof(Motion), new PropertyMetadata(0));

    public static int GetEntranceDelay(DependencyObject o) => (int)o.GetValue(EntranceDelayProperty);
    public static void SetEntranceDelay(DependencyObject o, int v) => o.SetValue(EntranceDelayProperty, v);

    private static void OnEntranceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement el || (int)e.NewValue < 0) return;
        if (Played.TryGetValue(el, out _)) return;
        el.Opacity = 0;
        el.Loaded += OnEntranceLoaded;
    }

    private static void OnEntranceLoaded(object sender, RoutedEventArgs e)
    {
        var el = (FrameworkElement)sender;
        el.Loaded -= OnEntranceLoaded;
        Play(el, GetEntrance(el), GetEntranceDelay(el));
    }

    /// <summary>Plays the entrance now (once): used for elements created in code.</summary>
    public static void Play(UIElement el, int index, int baseDelayMs = 0)
    {
        if (Played.TryGetValue(el, out _)) { el.Opacity = 1; return; }
        Played.Add(el, true);
        var delay = TimeSpan.FromMilliseconds(baseDelayMs + index * 70);
        var t = (TranslateTransform)GroupOf(el).Children[1];
        el.Opacity = 0;
        el.BeginAnimation(UIElement.OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(420)) { BeginTime = delay, EasingFunction = FastOutSlowIn });
        t.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(18, 0, TimeSpan.FromMilliseconds(500))
            {
                BeginTime = delay,
                EasingFunction = new BackEase { Amplitude = 0.15, EasingMode = EasingMode.EaseOut },
            });
    }
}
