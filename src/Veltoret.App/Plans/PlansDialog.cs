using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Veltoret.App.Controls;

namespace Veltoret.App.Plans;

/// <summary>
/// A borderless dark modal (Material AlertDialog look: SurfaceHigh, corner 14, hairline) used by the reminder
/// dialog and Settings' small choices. Esc or clicking "Cancel" closes it.
/// </summary>
internal class PlansDialog : Window
{
    private readonly TextBlock _title;
    private readonly ContentControl _body;
    private readonly StackPanel _buttons;

    public PlansDialog(Window? owner)
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        Background = Ui.Brush("Brush.SurfaceHigh");
        BorderBrush = Ui.Brush("Brush.OutlineStrong");
        BorderThickness = new Thickness(1);
        UseLayoutRounding = true;
        FontFamily = Application.Current.TryFindResource("Font.Sans") as FontFamily ?? FontFamily;
        if (owner is { IsVisible: true })
        {
            Owner = owner;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;
        }

        _title = Ui.Text("", "Text.HeadlineSmall");
        _title.Margin = new Thickness(0, 0, 0, 14);
        _body = new ContentControl();
        _buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var root = new StackPanel { Margin = new Thickness(24, 22, 24, 18), MinWidth = 340, MaxWidth = 460, Background = Brushes.Transparent };
        root.Children.Add(_title);
        root.Children.Add(_body);
        root.Children.Add(_buttons);
        Content = root;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource != root && e.OriginalSource != _title) return;
            try { DragMove(); } catch (InvalidOperationException) { }
        };
    }

    public string Heading
    {
        get => _title.Text;
        set { _title.Text = value; _title.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible; }
    }

    public object? Body { get => _body.Content; set => _body.Content = value; }

    public void ClearButtons() => _buttons.Children.Clear();

    public Button AddButton(string text, Action onClick, bool accent = false)
    {
        var b = new Button { Content = text, Margin = new Thickness(8, 0, 0, 0) };
        Ui.Apply(b, accent ? "Button.Text" : "Button.TextMuted");
        if (!accent) b.Foreground = Ui.Brush("Brush.Text");
        b.Click += (_, _) => onClick();
        _buttons.Children.Add(b);
        return b;
    }
}

/// <summary>Small helpers for building the plans and settings UI in code with the shared styles.</summary>
internal static class Ui
{
    public static Brush Brush(string key) =>
        Application.Current.TryFindResource(key) as Brush ?? Brushes.Transparent;

    public static void Apply(FrameworkElement e, string styleKey)
    {
        if (Application.Current.TryFindResource(styleKey) is Style s && s.TargetType.IsInstanceOfType(e)) e.Style = s;
    }

    public static TextBlock Text(string text, string style = "Text.BodyMedium", string? brush = null)
    {
        var t = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        Apply(t, style);
        if (brush != null) t.Foreground = Brush(brush);
        return t;
    }

    public static TextBlock OneLine(string text, string style = "Text.TitleSmall", string? brush = null)
    {
        var t = Text(text, style, brush);
        t.TextWrapping = TextWrapping.NoWrap;
        t.TextTrimming = TextTrimming.CharacterEllipsis;
        return t;
    }

    public static Icon Icon(string name, double size = 20, string brush = "Brush.Amber") =>
        new() { Data = Controls.Icon.Get(name), Size = size, Fill = Brush(brush), VerticalAlignment = VerticalAlignment.Center };

    /// <summary>A round flat icon button (close "×" in lists, scan).</summary>
    public static Button IconButton(string icon, string tooltip, Action onClick, double size = 34, string brush = "Brush.TextMuted")
    {
        var b = new Button
        {
            Content = Icon(icon, size * 0.5, brush),
            ToolTip = tooltip,
            Width = size,
            Height = size,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Apply(b, "Button.IconFlat");
        System.Windows.Automation.AutomationProperties.SetName(b, tooltip);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Button Button(string text, string style, Action onClick, string? icon = null)
    {
        var b = new Button { Content = text };
        Apply(b, style);
        if (icon != null && Controls.Icon.Get(icon) is { } g) ButtonAssist.SetIcon(b, g);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Border Divider()
    {
        var d = new Border { Height = 1, Background = Brush("Brush.Outline"), SnapsToDevicePixels = true };
        Apply(d, "Divider");
        return d;
    }

    /// <summary>Opens a link in the browser; false when there's none.</summary>
    public static bool OpenUrl(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static Window? Owner() =>
        Application.Current.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive) ?? Application.Current.MainWindow;
}
