using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;

namespace Veltoret.App.Controls;

/// <summary>
/// Animated scrolling for ScrollViewers (offsets aren't dependency properties, so animate attached proxies).
/// <c>c:SmoothScroll.IsEnabled="True"</c> on a pixel-scrolling ScrollViewer makes the mouse wheel glide.
/// </summary>
public static class SmoothScroll
{
    private static readonly IEasingFunction Ease = new CubicEase { EasingMode = EasingMode.EaseOut };

    public static readonly DependencyProperty HorizontalProperty = DependencyProperty.RegisterAttached(
        "Horizontal", typeof(double), typeof(SmoothScroll), new PropertyMetadata(0.0, (d, e) => ((ScrollViewer)d).ScrollToHorizontalOffset((double)e.NewValue)));

    public static readonly DependencyProperty VerticalProperty = DependencyProperty.RegisterAttached(
        "Vertical", typeof(double), typeof(SmoothScroll), new PropertyMetadata(0.0, (d, e) => ((ScrollViewer)d).ScrollToVerticalOffset((double)e.NewValue)));

    private static readonly DependencyProperty TargetProperty = DependencyProperty.RegisterAttached(
        "Target", typeof(double), typeof(SmoothScroll), new PropertyMetadata(double.NaN));

    public static void AnimateHorizontal(ScrollViewer sv, double to)
    {
        sv.BeginAnimation(HorizontalProperty, null);
        sv.SetValue(HorizontalProperty, sv.HorizontalOffset);
        sv.BeginAnimation(HorizontalProperty, new DoubleAnimation(sv.HorizontalOffset, to, TimeSpan.FromMilliseconds(320)) { EasingFunction = Ease });
    }

    public static void AnimateVertical(ScrollViewer sv, double to, int ms = 260)
    {
        var from = sv.VerticalOffset;
        sv.BeginAnimation(VerticalProperty, null);
        sv.SetValue(VerticalProperty, from);
        var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = Ease };
        a.Completed += (_, _) => sv.SetValue(TargetProperty, double.NaN);
        sv.BeginAnimation(VerticalProperty, a);
    }

    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(SmoothScroll), new PropertyMetadata(false, (d, e) =>
        {
            if (d is not ScrollViewer sv) return;
            sv.PreviewMouseWheel -= OnWheel;
            if ((bool)e.NewValue) sv.PreviewMouseWheel += OnWheel;
        }));

    public static bool GetIsEnabled(DependencyObject o) => (bool)o.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject o, bool v) => o.SetValue(IsEnabledProperty, v);

    private static void OnWheel(object sender, MouseWheelEventArgs e)
    {
        var sv = (ScrollViewer)sender;
        if (Keyboard.Modifiers != ModifierKeys.None || sv.ScrollableHeight <= 0) return;
        // A nested vertical scroller under the mouse (a list in a panel) gets the wheel first.
        if (e.OriginalSource is DependencyObject src && NestedScrollerHandles(sv, src, e.Delta)) return;
        e.Handled = true;
        var target = (double)sv.GetValue(TargetProperty);
        var start = double.IsNaN(target) ? sv.VerticalOffset : target;
        var to = Math.Clamp(start - e.Delta * 1.2, 0, sv.ScrollableHeight);
        sv.SetValue(TargetProperty, to);
        AnimateVertical(sv, to);
    }

    private static bool NestedScrollerHandles(ScrollViewer outer, DependencyObject src, int delta)
    {
        for (var d = src; d != null && d != outer; d = System.Windows.Media.VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d))
        {
            if (d is ScrollViewer inner && inner.ScrollableHeight > 0 && inner.VerticalScrollBarVisibility != ScrollBarVisibility.Disabled)
            {
                return delta > 0 ? inner.VerticalOffset > 0 : inner.VerticalOffset < inner.ScrollableHeight;
            }
        }
        return false;
    }
}
