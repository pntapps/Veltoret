using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Veltoret.App.Controls;

/// <summary>
/// In-app snackbar (Android Toast / Snackbar) at the bottom of the main window. Safe to call from any thread.
/// The shell calls <see cref="Attach"/> with its overlay panel.
/// </summary>
public static class Toast
{
    private static Panel? _host;
    private static Border? _current;
    private static DispatcherTimer? _timer;

    public static void Attach(Panel host) => _host = host;

    public static void Show(string message, string? actionText = null, Action? action = null)
    {
        var app = Application.Current;
        if (app == null) return;
        if (!app.Dispatcher.CheckAccess())
        {
            app.Dispatcher.BeginInvoke(() => Show(message, actionText, action));
            return;
        }
        var host = _host;
        if (host == null) return;
        HideNow();

        var text = new TextBlock
        {
            Text = message,
            Style = (Style)app.FindResource("Text.BodyMedium"),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 520,
        };
        var row = new DockPanel();
        Border toast = null!;
        if (actionText != null && action != null)
        {
            var btn = new Button { Content = actionText, Style = (Style)app.FindResource("Button.Text"), Margin = new Thickness(16, -4, -8, -4) };
            btn.Click += (_, _) => { Hide(toast); action(); };
            DockPanel.SetDock(btn, Dock.Right);
            row.Children.Add(btn);
        }
        row.Children.Add(text);
        toast = new Border
        {
            Background = (Brush)app.FindResource("Brush.SurfaceHighest"),
            BorderBrush = (Brush)app.FindResource("Brush.OutlineStrong"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(24, 0, 24, 28),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            MinWidth = 280,
            Child = row,
            Opacity = 0,
            RenderTransform = new TranslateTransform(0, 12),
        };
        host.Children.Add(toast);
        _current = toast;
        var d = TimeSpan.FromMilliseconds(200);
        toast.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, d));
        ((TranslateTransform)toast.RenderTransform).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, d) { EasingFunction = new CubicEase() });

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(action != null ? 6 : 3.5) };
        _timer.Tick += (_, _) => Hide(toast);
        _timer.Start();
    }

    private static void Hide(Border toast)
    {
        _timer?.Stop();
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
        fade.Completed += (_, _) => (_host)?.Children.Remove(toast);
        toast.BeginAnimation(UIElement.OpacityProperty, fade);
        if (_current == toast) _current = null;
    }

    private static void HideNow()
    {
        _timer?.Stop();
        if (_current != null) _host?.Children.Remove(_current);
        _current = null;
    }
}
