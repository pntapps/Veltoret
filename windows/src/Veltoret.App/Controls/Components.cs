using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Veltoret.App.Services;
using VIcon = Veltoret.App.Controls.Icon;

namespace Veltoret.App.Controls;

/// <summary>Small factory helpers for building UI in code with the shared styles.</summary>
public static class UiKit
{
    public const double Gutter = 40;

    public static T Res<T>(string key) => (T)Application.Current.FindResource(key);
    public static Brush Brush(string key) => Res<Brush>("Brush." + key);
    public static Style Style(string key) => Res<Style>(key);

    public static TextBlock Text(string? text, string style = "Text.BodyMedium", string? brush = null, int maxLines = 0, bool wrap = true)
    {
        var t = new TextBlock { Text = text ?? "", Style = Style(style) };
        if (brush != null) t.Foreground = Brush(brush);
        if (!wrap || maxLines == 1)
        {
            t.TextWrapping = TextWrapping.NoWrap;
            t.TextTrimming = TextTrimming.CharacterEllipsis;
        }
        else
        {
            t.TextWrapping = TextWrapping.Wrap;
            if (maxLines > 1)
            {
                t.TextTrimming = TextTrimming.CharacterEllipsis;
                t.MaxHeight = t.LineHeight > 0 ? t.LineHeight * maxLines + 1 : t.FontSize * 1.5 * maxLines;
            }
        }
        return t;
    }

    public static VIcon Icon(string name, double size = 24, string brush = "Text") =>
        new() { Data = VIcon.Get(name), Size = size, Fill = Brush(brush), VerticalAlignment = VerticalAlignment.Center };

    public static Button Button(string text, string style = "Button.Primary", string? icon = null, Action? onClick = null)
    {
        var b = new Button { Content = text, Style = Style(style) };
        if (icon != null) ButtonAssist.SetIcon(b, VIcon.Get(icon));
        if (onClick != null) b.Click += (_, _) => onClick();
        return b;
    }

    public static Button IconButton(string icon, string tooltip, Action? onClick = null, double size = 42, bool onImage = false, string? tint = null)
    {
        var b = new Button
        {
            Style = Style(onImage ? "Button.IconOnImage" : "Button.Icon"),
            Width = size,
            Height = size,
            ToolTip = tooltip,
        };
        ButtonAssist.SetIcon(b, VIcon.Get(icon));
        ButtonAssist.SetIconSize(b, size / 2);
        System.Windows.Automation.AutomationProperties.SetName(b, tooltip);
        if (tint != null) b.Foreground = Brush(tint);
        if (onClick != null) b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Pill(text, solid, accent): uppercased labelSmall in a corner-6 bordered box.</summary>
    public static Border Pill(string text, bool solid = false, bool accent = false)
    {
        var t = new TextBlock { Text = text.ToUpperInvariant(), Style = Style("Text.LabelSmall"), TextWrapping = TextWrapping.NoWrap };
        var b = new Border { Style = Style(accent ? "Pill.Accent" : solid ? "Pill.Solid" : "Pill"), Child = t };
        t.Foreground = accent ? Brush("AmberSoft") : Brush("Text");
        return b;
    }

    /// <summary>RatingText: star 15 Amber, 3 gap, "%.1f" labelLarge. Null when rating ≤ 0.</summary>
    public static FrameworkElement? Rating(double rating)
    {
        if (rating <= 0) return null;
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(Icon("Star", 15, "Amber"));
        var t = Text(Formats.Rating(rating), "Text.LabelLarge", wrap: false);
        t.Margin = new Thickness(3, 0, 0, 0);
        t.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(t);
        return p;
    }

    /// <summary>MetaLine: drops blanks, joins with "  ·  ", bodyMedium TextMuted, max 2 lines.</summary>
    public static TextBlock MetaLine(params string?[] parts)
    {
        var t = Text(Formats.Join(parts), "Text.BodyMedium", "TextMuted", maxLines: 2);
        t.VerticalAlignment = VerticalAlignment.Center;
        return t;
    }

    public static Border Divider() => new() { Style = Style("Divider") };

    public static Border Panel(UIElement child, Thickness? padding = null) => new()
    {
        Style = Style("Panel"),
        Padding = padding ?? new Thickness(16),
        Child = child,
    };

    /// <summary>A panel that reacts like a button (corner 14, hover tint).</summary>
    public static Button ClickPanel(UIElement child, Action onClick, Thickness? padding = null)
    {
        var inner = new Border
        {
            Background = Brush("Surface"),
            BorderBrush = Brush("Outline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = padding ?? new Thickness(16),
            Child = child,
        };
        var b = new Button { Style = Style("Button.Plain"), Content = inner, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        b.MouseEnter += (_, _) => inner.BorderBrush = Brush("OutlineStrong");
        b.MouseLeave += (_, _) => inner.BorderBrush = Brush("Outline");
        b.Click += (_, _) => onClick();
        Motion.SetPressScale(b, 0.98);
        return b;
    }

    public static StackPanel Row(double spacing, params UIElement?[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        var first = true;
        foreach (var c in children)
        {
            if (c == null) continue;
            if (!first && c is FrameworkElement fe) fe.Margin = new Thickness(fe.Margin.Left + spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(c);
            first = false;
        }
        return p;
    }

    /// <summary>Opens a context menu under <paramref name="anchor"/>.</summary>
    public static void ShowMenu(FrameworkElement anchor, ContextMenu menu)
    {
        menu.PlacementTarget = anchor;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    public static MenuItem MenuItem(string header, string? icon, Action onClick, bool isChecked = false)
    {
        var m = new MenuItem { Header = header, IsChecked = isChecked };
        if (icon != null) ButtonAssist.SetIcon(m, VIcon.Get(icon));
        m.Click += (_, _) => onClick();
        return m;
    }

    public static void OpenUrl(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { App.Log(ex); Toast.Show("Couldn't open the browser"); }
    }

    public static Window? OwnerOf(DependencyObject? d) => d == null ? null : Window.GetWindow(d) ?? Application.Current.MainWindow;
}

/// <summary>SectionHeader(title, actionLabel?, onAction?): headlineSmall title, amber text action.</summary>
public sealed class SectionHeader : DockPanel
{
    public SectionHeader(string title, string? actionLabel = null, Action? onAction = null, double gutter = UiKit.Gutter)
    {
        Margin = new Thickness(gutter, 0, gutter - 8, 0);
        LastChildFill = true;
        if (actionLabel != null && onAction != null)
        {
            var b = UiKit.Button(actionLabel, "Button.Text", onClick: onAction);
            SetDock(b, Dock.Right);
            Children.Add(b);
        }
        var t = UiKit.Text(title, "Text.HeadlineSmall", maxLines: 1);
        t.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(t);
    }
}

/// <summary>ScreenHeader(title, subtitle?, onBack?, actions): headlineLarge, padding start gutter (12 with Back).</summary>
public sealed class ScreenHeader : DockPanel
{
    private readonly TextBlock _title;
    private readonly TextBlock _subtitle;
    private readonly StackPanel _actions = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };

    public ScreenHeader(string title, string? subtitle = null, bool back = false)
    {
        Margin = new Thickness(back ? 12 : UiKit.Gutter, 12, 12, 8);
        LastChildFill = true;
        if (back)
        {
            var b = UiKit.IconButton("ArrowBack", "Back", () => AppServices.Navigator.GoBack());
            b.Margin = new Thickness(0, 0, 12, 0);
            SetDock(b, Dock.Left);
            Children.Add(b);
        }
        SetDock(_actions, Dock.Right);
        Children.Add(_actions);
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _title = UiKit.Text(title, "Text.HeadlineLarge", maxLines: 1);
        _subtitle = UiKit.Text(subtitle, "Text.BodySmall", "TextMuted", maxLines: 1);
        col.Children.Add(_title);
        col.Children.Add(_subtitle);
        Children.Add(col);
        Subtitle = subtitle;
    }

    public string Title { set => _title.Text = value; }

    public string? Subtitle
    {
        set
        {
            _subtitle.Text = value ?? "";
            _subtitle.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    public void AddAction(UIElement action)
    {
        if (action is FrameworkElement fe && _actions.Children.Count > 0) fe.Margin = new Thickness(8, 0, 0, 0);
        _actions.Children.Add(action);
    }
}

/// <summary>EmptyState(icon, title, message, action?): 72 px disc with a 32 px amber icon, centered.</summary>
public sealed class EmptyState : StackPanel
{
    public EmptyState(string icon, string title, string message, string? actionLabel = null, Action? onAction = null)
    {
        Margin = new Thickness(32);
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        MaxWidth = 520;
        var disc = new Grid { Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center };
        disc.Children.Add(new Ellipse { Fill = UiKit.Brush("Surface"), Stroke = UiKit.Brush("Outline"), StrokeThickness = 1 });
        var i = UiKit.Icon(icon, 32, "Amber");
        i.HorizontalAlignment = HorizontalAlignment.Center;
        disc.Children.Add(i);
        Children.Add(disc);
        var t = UiKit.Text(title, "Text.HeadlineSmall");
        t.TextAlignment = TextAlignment.Center;
        t.Margin = new Thickness(0, 20, 0, 0);
        Children.Add(t);
        var m = UiKit.Text(message, "Text.BodyMedium", "TextMuted");
        m.TextAlignment = TextAlignment.Center;
        m.Margin = new Thickness(0, 8, 0, 0);
        Children.Add(m);
        if (actionLabel != null && onAction != null)
        {
            var b = UiKit.Button(actionLabel, "Button.Primary", onClick: onAction);
            b.Margin = new Thickness(0, 24, 0, 0);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            Children.Add(b);
        }
    }
}

/// <summary>LoadingBox: centered 32 px amber spinner.</summary>
public sealed class LoadingBox : Grid
{
    public LoadingBox(double height = double.NaN)
    {
        Height = height;
        MinHeight = 120;
        Children.Add(new Spinner { Width = 32, Height = 32, Thickness = 2.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
    }
}

/// <summary>"Veltoret" + amber dot (a period near the baseline).</summary>
public sealed class Wordmark : StackPanel
{
    public Wordmark(bool large = false)
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        var t = UiKit.Text("Veltoret", large ? "Text.DisplayMedium" : "Text.HeadlineMedium", wrap: false);
        Children.Add(t);
        var d = large ? 9 : 6;
        Children.Add(new Ellipse
        {
            Width = d,
            Height = d,
            Fill = UiKit.Brush("Amber"),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(3, 0, 0, large ? 10 : 7),
        });
    }
}

/// <summary>
/// TMDB attribution (required by TMDB's terms): their logo (flat XAML rendition, 273.42:35.52, height 12), 8 gap,
/// then the notice. Used by onboarding and Settings → About.
/// </summary>
public sealed class TmdbAttribution : StackPanel
{
    public const string Notice = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.";

    public TmdbAttribution()
    {
        Children.Add(Logo(12));
        var t = UiKit.Text(Notice, "Text.BodySmall", "TextFaint");
        t.Margin = new Thickness(0, 8, 0, 0);
        Children.Add(t);
    }

    /// <summary>
    /// TMDB's wordmark logo: "TMDB" lettering beside a rounded bar. TMDB's official logo uses their gradient
    /// (#90CEA1 → #3CBEC9 → #01B4E4), which is the one allowed exception to the no-gradient rule.
    /// </summary>
    public static FrameworkElement Logo(double height)
    {
        var width = height * 273.42 / 35.52;
        var brush = new LinearGradientBrush(
            new GradientStopCollection
            {
                new(Color.FromRgb(0x90, 0xCE, 0xA1), 0),
                new(Color.FromRgb(0x3C, 0xBE, 0xC9), 0.56),
                new(Color.FromRgb(0x01, 0xB4, 0xE4), 1),
            }, 0);
        brush.Freeze();
        var grid = new Grid { Width = width, Height = height, HorizontalAlignment = HorizontalAlignment.Left, ToolTip = "The Movie Database (TMDB)" };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = new TextBlock
        {
            Text = "TMDB",
            FontFamily = new FontFamily("Arial Black, Segoe UI Black, Segoe UI"),
            FontWeight = FontWeights.Black,
            FontSize = height * 1.08,
            LineHeight = height,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, height * 0.4, 0),
        };
        grid.Children.Add(text);
        var bar = new Border { Background = brush, CornerRadius = new CornerRadius(height / 2), Height = height * 0.72, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(bar, 1);
        grid.Children.Add(bar);
        return grid;
    }
}

/// <summary>A horizontal row of cards (Home rows, "More like this", cast): wheel scrolls the page, Shift+wheel the row; arrow buttons on hover.</summary>
public sealed class HorizontalRow : Grid
{
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _panel;
    private readonly Button _left;
    private readonly Button _right;
    private double _target;

    public HorizontalRow(double spacing = 16, double gutter = UiKit.Gutter)
    {
        Spacing = spacing;
        _panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(gutter, 0, gutter, 0) };
        _scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            CanContentScroll = false,
            Content = _panel,
            Focusable = false,
        };
        Children.Add(_scroll);
        _left = UiKit.IconButton("ChevronLeft", "Scroll left", () => Page(-1), 40);
        _right = UiKit.IconButton("ChevronRight", "Scroll right", () => Page(1), 40);
        foreach (var b in new[] { _left, _right })
        {
            b.VerticalAlignment = VerticalAlignment.Center;
            b.Visibility = Visibility.Collapsed;
            b.Background = UiKit.Brush("SurfaceHighest");
            Children.Add(b);
        }
        _left.HorizontalAlignment = HorizontalAlignment.Left;
        _left.Margin = new Thickness(8, 0, 0, 0);
        _right.HorizontalAlignment = HorizontalAlignment.Right;
        _right.Margin = new Thickness(0, 0, 8, 0);
        MouseEnter += (_, _) => UpdateArrows(true);
        MouseLeave += (_, _) => UpdateArrows(false);
        _scroll.ScrollChanged += (_, _) => UpdateArrows(IsMouseOver);
        _scroll.PreviewMouseWheel += OnWheel;
    }

    public double Spacing { get; }

    /// <summary>Offset of the vertical center of the arrows from the row top (e.g. the image center); NaN = middle.</summary>
    public double ArrowCenter
    {
        set
        {
            if (double.IsNaN(value)) return;
            foreach (var b in new[] { _left, _right })
            {
                b.VerticalAlignment = VerticalAlignment.Top;
                b.Margin = new Thickness(b == _left ? 8 : 0, Math.Max(0, value - 20), b == _right ? 8 : 0, 0);
            }
        }
    }

    public void SetItems(IEnumerable<UIElement> items)
    {
        _panel.Children.Clear();
        foreach (var item in items) Add(item);
    }

    public void Add(UIElement item)
    {
        if (item is FrameworkElement fe && _panel.Children.Count > 0) fe.Margin = new Thickness(Spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
        _panel.Children.Add(item);
    }

    private void UpdateArrows(bool hover)
    {
        _left.Visibility = hover && _scroll.HorizontalOffset > 1 ? Visibility.Visible : Visibility.Collapsed;
        _right.Visibility = hover && _scroll.HorizontalOffset < _scroll.ScrollableWidth - 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Page(int dir)
    {
        _target = Math.Clamp(_scroll.HorizontalOffset + dir * Math.Max(200, _scroll.ViewportWidth * 0.8), 0, _scroll.ScrollableWidth);
        SmoothScroll.AnimateHorizontal(_scroll, _target);
    }

    private void OnWheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            e.Handled = true;
            var to = Math.Clamp(_scroll.HorizontalOffset - e.Delta, 0, _scroll.ScrollableWidth);
            SmoothScroll.AnimateHorizontal(_scroll, to);
            return;
        }
        // Let the page scroll vertically.
        e.Handled = true;
        var parent = VisualTreeHelper.GetParent(this) as UIElement;
        parent?.RaiseEvent(new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta) { RoutedEvent = MouseWheelEvent, Source = this });
    }
}
