using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Plans;

namespace Veltoret.App.Pages.Settings;

/// <summary>Settings building blocks (Android: SettingRow, SwitchRow, ChoiceRow, group titles, panels).</summary>
internal static class SettingsRows
{
    /// <summary>Group title: UPPERCASE, amber, small label.</summary>
    public static TextBlock Group(string title)
    {
        var t = Ui.Text(title.ToUpperInvariant(), "Text.LabelMedium", "Brush.Amber");
        t.Margin = new Thickness(8, 28, 0, 10);
        return t;
    }

    /// <summary>A panel whose rows are separated by 1 px dividers (16 px inset).</summary>
    public static (Border Panel, StackPanel Rows) Panel()
    {
        var rows = new StackPanel();
        var b = new Border { Child = rows };
        Ui.Apply(b, "Panel");
        b.Padding = new Thickness(0);
        if (b.Style == null)
        {
            b.Background = Ui.Brush("Brush.Surface");
            b.BorderBrush = Ui.Brush("Brush.Outline");
            b.BorderThickness = new Thickness(1);
            b.CornerRadius = new CornerRadius(14);
        }
        return (b, rows);
    }

    public static Border PanelOf(params UIElement?[] rows)
    {
        var (panel, stack) = Panel();
        AddRows(stack, rows);
        return panel;
    }

    public static void AddRows(StackPanel stack, IEnumerable<UIElement?> rows)
    {
        foreach (var r in rows)
        {
            if (r == null) continue;
            if (stack.Children.Count > 0) stack.Children.Add(InsetDivider());
            stack.Children.Add(r);
        }
    }

    public static Border InsetDivider()
    {
        var d = Ui.Divider();
        d.Margin = new Thickness(16, 0, 16, 0);
        return d;
    }

    private static Button RowButton(UIElement content, Action? onClick)
    {
        var b = new Button
        {
            Content = content,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Focusable = onClick != null,
            IsHitTestVisible = onClick != null,
        };
        Ui.Apply(b, "Button.Row");
        if (b.Style == null) { b.Background = Brushes.Transparent; b.BorderThickness = new Thickness(0); }
        if (onClick != null) b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Title, optional subtitle and amber icon, and a chevron when clickable.</summary>
    public static (Button Row, TextBlock Subtitle) Setting(string title, string? subtitle, string? icon, Action? onClick, bool chevron = true)
    {
        var grid = new Grid { Margin = new Thickness(16, 14, 16, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon != null)
        {
            var i = Ui.Icon(icon, 22);
            i.Margin = new Thickness(0, 0, 16, 0);
            grid.Children.Add(i);
        }
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.Text(title, "Text.TitleSmall"));
        var sub = Ui.Text(subtitle ?? "", "Text.BodySmall", "Brush.TextMuted");
        sub.Margin = new Thickness(0, 2, 0, 0);
        sub.Visibility = string.IsNullOrEmpty(subtitle) ? Visibility.Collapsed : Visibility.Visible;
        texts.Children.Add(sub);
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        if (onClick != null && chevron)
        {
            var c = Ui.Icon("ChevronRight", 20, "Brush.TextMuted");
            c.Margin = new Thickness(12, 0, 0, 0);
            Grid.SetColumn(c, 2);
            grid.Children.Add(c);
        }
        return (RowButton(grid, onClick), sub);
    }

    /// <summary>Title, subtitle and a switch; the whole row toggles.</summary>
    public static Button Switch(string title, string subtitle, Func<bool> get, Action<bool> set)
    {
        var grid = new Grid { Margin = new Thickness(16, 12, 16, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        texts.Children.Add(Ui.Text(title, "Text.TitleSmall"));
        var sub = Ui.Text(subtitle, "Text.BodySmall", "Brush.TextMuted");
        sub.Margin = new Thickness(0, 2, 0, 0);
        texts.Children.Add(sub);
        grid.Children.Add(texts);
        var toggle = new ToggleButton { IsChecked = get(), IsHitTestVisible = false, Focusable = false, VerticalAlignment = VerticalAlignment.Center };
        Ui.Apply(toggle, "Toggle");
        Grid.SetColumn(toggle, 1);
        grid.Children.Add(toggle);
        var row = RowButton(grid, null);
        row.IsHitTestVisible = true;
        row.Focusable = true;
        row.Click += (_, _) =>
        {
            var next = !get();
            set(next);
            toggle.IsChecked = get();
        };
        System.Windows.Automation.AutomationProperties.SetName(row, title);
        return row;
    }

    /// <summary>Title on the left, the selected label in amber on the right ("—" if none); a click opens a dropdown.</summary>
    public static Button Choice<T>(string title, IReadOnlyList<(T Value, string Label)> options, Func<T> get, Action<T> set)
    {
        var grid = new Grid { Margin = new Thickness(16, 14, 16, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var t = Ui.Text(title, "Text.TitleSmall");
        t.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(t);
        var value = Ui.Text(Label(options, get()), "Text.LabelLarge", "Brush.Amber");
        value.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(value, 1);
        grid.Children.Add(value);
        var row = RowButton(grid, null);
        row.IsHitTestVisible = true;
        row.Focusable = true;
        row.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = value, Placement = PlacementMode.Bottom };
            Ui.Apply(menu, "ContextMenu");
            var current = get();
            foreach (var (v, label) in options)
            {
                var item = new MenuItem { Header = label };
                Ui.Apply(item, "MenuItem");
                if (EqualityComparer<T>.Default.Equals(v, current)) item.Foreground = Ui.Brush("Brush.Amber");
                var chosen = v;
                item.Click += (_, _) =>
                {
                    set(chosen);
                    value.Text = Label(options, get());
                };
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        };
        return row;
    }

    private static string Label<T>(IReadOnlyList<(T Value, string Label)> options, T v)
    {
        foreach (var o in options)
            if (EqualityComparer<T>.Default.Equals(o.Value, v)) return o.Label;
        return "—";
    }

    /// <summary>Plain text inside a panel (padding 16).</summary>
    public static TextBlock Note(string text, string brush = "Brush.TextMuted")
    {
        var t = Ui.Text(text, "Text.BodySmall", brush);
        t.Margin = new Thickness(16);
        return t;
    }

    /// <summary>A round avatar: an icon (This PC, network server) or the first letter of a Google account's name.</summary>
    public static FrameworkElement Avatar(string? icon, string? letter, double size = 40)
    {
        var b = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size / 2),
            Background = Ui.Brush("Brush.AmberDim"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (icon != null)
        {
            var i = Ui.Icon(icon, size * 0.5);
            i.HorizontalAlignment = HorizontalAlignment.Center;
            b.Child = i;
        }
        else
        {
            var t = Ui.Text(letter ?? "?", "Text.TitleMedium", "Brush.Amber");
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            b.Child = t;
        }
        return b;
    }

    public static Border Pill(string text)
    {
        var t = Ui.Text(text, "Text.Pill");
        var b = new Border { Child = t, VerticalAlignment = VerticalAlignment.Center };
        Ui.Apply(b, "Pill");
        if (b.Style == null)
        {
            b.BorderBrush = Ui.Brush("Brush.OutlineStrong");
            b.BorderThickness = new Thickness(1);
            b.CornerRadius = new CornerRadius(6);
            b.Padding = new Thickness(7, 3, 7, 3);
        }
        return b;
    }

    public static Controls.Spinner MakeSpinner(double size) => new() { Width = size, Height = size, Thickness = 2, VerticalAlignment = VerticalAlignment.Center };
}
