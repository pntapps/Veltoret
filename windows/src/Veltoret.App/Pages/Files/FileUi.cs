using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;
using VIcon = Veltoret.App.Controls.Icon;

namespace Veltoret.App.Pages.Files;

/// <summary>Small view helpers shared by the Files, Archives and account screens (built in code, styled from Themes).</summary>
internal static class FileUi
{
    public static Brush Brush(string name) => (Brush)Application.Current.FindResource("Brush." + name);
    public static Style Style(string key) => (Style)Application.Current.FindResource(key);

    /// <summary>Material Rounded paths the shared icon set doesn't have.</summary>
    public static class Icons
    {
        private static Geometry P(string d)
        {
            var g = Geometry.Parse(d);
            g.Freeze();
            return g;
        }

        public static readonly Geometry Upload = P("M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z");
        public static readonly Geometry CloudUpload = P("M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z");
        public static readonly Geometry Unarchive = P("M20.55 5.22l-1.39-1.68C18.88 3.21 18.47 3 18 3H6c-.47 0-.88.21-1.15.55L3.46 5.22C3.17 5.57 3 6.01 3 6.5V19c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V6.5c0-.49-.17-.93-.45-1.28zM12 9.5l5.5 5.5H14v2h-4v-2H6.5L12 9.5zM5.12 5l.82-1h12l.93 1H5.12z");
        public static readonly Geometry Subtitles = P("M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zM4 12h4v2H4v-2zm10 6H4v-2h10v2zm6 0h-4v-2h4v2zm0-4H10v-2h10v2z");
        public static readonly Geometry Image = P("M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z");
        public static readonly Geometry File = P("M6 2c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z");
        public static readonly Geometry Video = P("M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z");
        public static readonly Geometry DriveFileMove = P("M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 12v-3h-4v-4h4V8l5 5-5 5z");
        public static readonly Geometry DeleteForever = P("M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zm2.46-7.12l1.41-1.41L12 12.59l2.12-2.12 1.41 1.41L13.41 14l2.12 2.12-1.41 1.41L12 15.41l-2.12 2.12-1.41-1.41L10.59 14l-2.13-2.12zM15.5 4l-1-1h-5l-1 1H5v2h14V4z");
        public static readonly Geometry Error = P("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z");
        public static readonly Geometry Delete = P("M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z");
        public static readonly Geometry Google = P("M12 11v2.8h4.6c-.2 1.2-1.4 3.5-4.6 3.5-2.8 0-5-2.3-5-5.2s2.3-5.2 5-5.2c1.6 0 2.6.7 3.2 1.3l2.2-2.1C16 4.8 14.2 4 12 4 7.6 4 4 7.6 4 12s3.6 8 8 8c4.6 0 7.7-3.2 7.7-7.8 0-.5-.1-.9-.1-1.2H12z");
    }

    public static Geometry Geo(string name) => VIcon.Get(name) ?? Icons.File;

    public static VIcon IconOf(Geometry data, double size = 20, Brush? fill = null) =>
        new() { Data = data, Size = size, Fill = fill, VerticalAlignment = VerticalAlignment.Center };

    public static TextBlock Text(string text, string style = "Text.BodyMedium", Brush? color = null, bool wrap = true) => new()
    {
        Text = text,
        Style = Style(style),
        Foreground = color ?? Brush("Text"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    public static Button Button(string text, string style = "Button.Secondary", Geometry? icon = null, Action? click = null)
    {
        var b = new Button { Content = text, Style = Style(style) };
        if (icon != null) ButtonAssist.SetIcon(b, icon);
        if (click != null) b.Click += (_, _) => click();
        return b;
    }

    public static Button IconButton(Geometry icon, string tooltip, Action click, string style = "Button.Icon")
    {
        var b = new Button { Style = Style(style), ToolTip = tooltip };
        ButtonAssist.SetIcon(b, icon);
        System.Windows.Automation.AutomationProperties.SetName(b, tooltip);
        b.Click += (_, _) => click();
        return b;
    }

    public static ToggleButton Chip(string text, bool selected, Action click)
    {
        var c = new ToggleButton { Content = text, Style = Style("Chip"), IsChecked = selected, Margin = new Thickness(0, 0, 8, 0) };
        c.Click += (_, _) => { c.IsChecked = selected; click(); };
        return c;
    }

    public static MenuItem Item(string header, Action click, Geometry? icon = null, bool danger = false, bool enabled = true)
    {
        var m = new MenuItem { Header = header, Style = Style("MenuItem"), IsEnabled = enabled };
        if (icon != null) m.Icon = IconOf(icon, 18, danger ? Brush("Danger") : null);
        if (danger) m.Foreground = Brush("Danger");
        m.Click += (_, _) => click();
        return m;
    }

    public static ContextMenu Menu(params MenuItem[] items)
    {
        var menu = new ContextMenu { Style = Style("ContextMenu") };
        foreach (var i in items) menu.Items.Add(i);
        return menu;
    }

    public static void ShowMenu(ContextMenu menu, UIElement target)
    {
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    // ---- items ---------------------------------------------------------------------------------------------

    public static bool IsVideo(StorageItem f) =>
        !f.IsFolder && (FilenameParser.IsVideo(f.Name, f.MimeType) || f.MimeType.StartsWith("video/", StringComparison.Ordinal));

    public static bool IsZip(StorageItem f) => !f.IsFolder && FilenameParser.IsArchive(f.Name);

    public static bool IsImage(StorageItem f) => f.MimeType.StartsWith("image/", StringComparison.Ordinal);

    /// <summary>The Files screen lists folders, videos, subtitles and ZIPs only.</summary>
    public static bool IsUseful(StorageItem f) => f.IsFolder || IsVideo(f) || FilenameParser.IsSubtitle(f.Name) || IsZip(f);

    public static (Geometry Icon, Brush Color) Look(StorageItem f)
    {
        if (f.IsFolder) return (Geo("Folder"), Brush("Amber"));
        if (IsVideo(f)) return (Icons.Video, Brush("Text"));
        if (FilenameParser.IsSubtitle(f.Name)) return (Icons.Subtitles, Brush("TextMuted"));
        if (IsZip(f)) return (Geo("FolderZip"), Brush("AmberSoft"));
        if (IsImage(f)) return (Icons.Image, Brush("TextMuted"));
        return (Icons.File, Brush("TextMuted"));
    }

    /// <summary>44×44 rounded tile with the item's icon (a check-circle when selected).</summary>
    public static Border Tile(Geometry icon, Brush color, bool selected = false, double size = 44) => new()
    {
        Width = size,
        Height = size,
        CornerRadius = new CornerRadius(12),
        Background = selected ? Brush("Amber") : Brush("SurfaceHigh"),
        Child = new VIcon
        {
            Data = selected ? Geo("CheckCircle") : icon,
            Size = size * 0.5,
            Fill = selected ? Brush("OnAmber") : color,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        },
    };

    // ---- accounts ------------------------------------------------------------------------------------------

    public static string AccountName(AccountEntity a) =>
        Accounts.IsLocal(a.Email) ? Accounts.DeviceDisplayName : string.IsNullOrWhiteSpace(a.DisplayName) ? a.Email : a.DisplayName;

    /// <summary>The switcher's text: "This PC" / server name / email.</summary>
    public static string SwitcherName(AccountEntity a) =>
        Accounts.IsLocal(a.Email) ? Accounts.DeviceDisplayName : Accounts.IsSmb(a.Email) ? AccountName(a) : a.Email;

    public static string AccountSubtitle(AccountEntity a) =>
        Accounts.IsLocal(a.Email) ? "Folders on this PC, external drives and USB"
        : Accounts.IsSmb(a.Email) ? "Network server · " + a.Email["smb://".Length..]
        : a.Email;

    /// <summary>Google = first letter in a circle (or the profile photo); This PC = computer; SMB = server.</summary>
    public static FrameworkElement Avatar(AccountEntity a, double size = 36)
    {
        var circle = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size / 2),
            Background = Brush("SurfaceHighest"),
            BorderBrush = Brush("Outline"),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (Accounts.IsLocal(a.Email) || Accounts.IsSmb(a.Email))
        {
            circle.Child = new VIcon
            {
                Data = Geo(Accounts.IsLocal(a.Email) ? "Computer" : "Dns"),
                Size = size * 0.5,
                Fill = Brush("Amber"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            return circle;
        }
        var name = AccountName(a);
        var letter = new TextBlock
        {
            Text = name.Length > 0 ? char.ToUpperInvariant(name[0]).ToString() : "?",
            FontFamily = (FontFamily)Application.Current.FindResource("Font.Sans"),
            FontWeight = FontWeights.SemiBold,
            FontSize = size * 0.42,
            Foreground = Brush("Amber"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (string.IsNullOrEmpty(a.PhotoUrl))
        {
            circle.Child = letter;
            return circle;
        }
        var grid = new Grid();
        grid.Children.Add(letter);
        var photo = new AsyncImage { Url = a.PhotoUrl, Stretch = Stretch.UniformToFill, DecodeWidth = (int)(size * 2) };
        grid.Children.Add(photo);
        grid.Clip = new EllipseGeometry(new Point(size / 2 - 1, size / 2 - 1), size / 2 - 1, size / 2 - 1);
        circle.Child = grid;
        return circle;
    }

    /// <summary>Exception text for a snackbar (e.Message ?? fallback).</summary>
    public static string Message(Exception e, string fallback = "Something went wrong") =>
        string.IsNullOrWhiteSpace(e.Message) ? fallback : e.Message;
}
