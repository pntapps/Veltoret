using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace Veltoret.App.Controls;

/// <summary>
/// App-wide touchscreen support, installed once at startup: touch scrolling (<see cref="TouchScroll"/>), room for the
/// touch keyboard (<see cref="TouchKeyboard"/>), and Enter in a text field moving to the next field (the touch keyboard
/// has no Tab key). Also tells mouse events that Windows or WPF made from a touch apart from real mouse input.
/// </summary>
public static class TouchInput
{
    private static long _lastTouchTicks;

    public static void Install()
    {
        foreach (var ev in new[] { UIElement.PreviewTouchDownEvent, UIElement.PreviewTouchMoveEvent, UIElement.PreviewTouchUpEvent })
            EventManager.RegisterClassHandler(typeof(UIElement), ev, new EventHandler<TouchEventArgs>((_, _) => _lastTouchTicks = Environment.TickCount64), true);
        EventManager.RegisterClassHandler(typeof(TextBox), UIElement.PreviewKeyDownEvent, new KeyEventHandler(OnFieldKeyDown));
        EventManager.RegisterClassHandler(typeof(PasswordBox), UIElement.PreviewKeyDownEvent, new KeyEventHandler(OnFieldKeyDown));
        TouchScroll.Install();
        TouchKeyboard.Install();
    }

    // The same routed event reaches the class handler once per element on its route; count each event once.
    private static RoutedEventArgs? _lastEvent;

    /// <summary>True within a moment of the last touch event.</summary>
    public static bool RecentTouch => Environment.TickCount64 - _lastTouchTicks < 700;

    [DllImport("user32.dll")]
    private static extern IntPtr GetMessageExtraInfo();

    /// <summary>
    /// True when this mouse event was made from a touch (WPF's promotion, or Windows' when it delivers pointer input
    /// as mouse messages): pages and the player handle touches themselves and skip these.
    /// </summary>
    public static bool IsFromTouch(MouseEventArgs e)
    {
        if (e.StylusDevice != null) return true;
        // MI_WP_SIGNATURE: mouse messages synthesized from pen or touch carry it in their extra info.
        if (((long)GetMessageExtraInfo() & 0xFFFFFF00) == 0xFF515700) return true;
        return RecentTouch;
    }

    /// <summary>Enter in a single-line field moves to the next field; on the last one it presses the default button.</summary>
    private static void OnFieldKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || ReferenceEquals(e, _lastEvent) || Keyboard.Modifiers != ModifierKeys.None) return;
        _lastEvent = e;
        if (sender is TextBox { AcceptsReturn: true }) return;
        if (sender is not Control field || NextField(field) is not { } next) return;
        e.Handled = true;
        next.Focus();
        if (next is TextBox t) t.SelectAll();
    }

    /// <summary>
    /// The next visible, enabled, editable text field after <paramref name="field"/> in the same window, in layout
    /// order (Veltoret builds its forms top to bottom, so that is the Tab order). Null on the last field.
    /// </summary>
    private static Control? NextField(Control field)
    {
        if (Window.GetWindow(field) is not { } window) return null;
        var fields = new List<Control>();
        Collect(window, fields);
        var i = fields.IndexOf(field);
        return i >= 0 && i + 1 < fields.Count ? fields[i + 1] : null;
    }

    private static void Collect(DependencyObject d, List<Control> fields)
    {
        if (d is UIElement { IsVisible: false }) return;
        if (d is TextBox { IsReadOnly: false, IsEnabled: true } or PasswordBox { IsEnabled: true })
        {
            fields.Add((Control)d);
            return; // a field's own template holds no further fields
        }
        var n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++) Collect(System.Windows.Media.VisualTreeHelper.GetChild(d, i), fields);
    }
}
