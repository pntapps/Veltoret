using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Details;

using Accounts = Veltoret.Core.Storage.Accounts;

/// <summary>Pieces shared by the movie, show and collection pages (Android DetailCommon.kt / DetailActions.kt).</summary>
public static class DetailCommon
{
    public static bool Online
    {
        get
        {
            try { return AppServices.Connectivity.IsOnline; }
            catch (Exception) { return true; }
        }
    }

    public static bool CanPlayNow(MediaFileEntity f) => Online || Accounts.IsLocal(f.AccountEmail);

    /// <summary>
    /// DetailHeader (Expanded): left column = Back + info; right = framed 16:9 backdrop (corner 24) with the poster
    /// hanging 48 px below its bottom-left corner. Entrance: backdrop 1, poster 2 (once).
    /// </summary>
    public static FrameworkElement Header(FrameworkElement info, string? backdropUrl, string? posterUrl, string title, bool entrance)
    {
        var grid = new Grid { Margin = new Thickness(40, 16, 40, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.1, GridUnitType.Star) });

        var left = new StackPanel { Margin = new Thickness(0, 0, 40, 0) };
        var back = UiKit.IconButton("ArrowBack", "Back", () => AppServices.Navigator.GoBack());
        back.HorizontalAlignment = HorizontalAlignment.Left;
        left.Children.Add(back);
        info.Margin = new Thickness(0, 24, 0, 0);
        left.Children.Add(info);
        grid.Children.Add(left);

        var right = new Grid { Margin = new Thickness(0, 58, 0, 48), VerticalAlignment = VerticalAlignment.Top };
        Grid.SetColumn(right, 1);
        var backdrop = new AspectBox
        {
            Ratio = 9.0 / 16.0,
            Child = new AsyncImage
            {
                Url = backdropUrl, FallbackText = title, DecodeWidth = 1280,
                CornerRadius = new CornerRadius(24), BorderThickness = new Thickness(1), BorderBrush = UiKit.Brush("Outline"),
            },
        };
        right.Children.Add(backdrop);
        var poster = new Border
        {
            Width = 124 + 4,
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(2),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(20, 0, 0, 0),
            RenderTransform = new TranslateTransform(0, 48),
            Child = new AspectBox
            {
                Ratio = 1.5,
                Child = new AsyncImage { Url = posterUrl, FallbackText = title, DecodeWidth = 300, CornerRadius = new CornerRadius(12) },
            },
        };
        poster.SetResourceReference(Border.BorderBrushProperty, "Brush.Background");
        poster.SetResourceReference(Border.BackgroundProperty, "Brush.Background");
        var posterHost = new Grid { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Children = { poster } };
        right.Children.Add(posterHost);
        grid.Children.Add(right);
        // Narrow windows (a tablet held upright): one column, the artwork under the info.
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.SizeChanged += (_, e) =>
        {
            var narrow = e.NewSize.Width < 720;
            grid.ColumnDefinitions[1].Width = narrow ? new GridLength(0) : new GridLength(1.1, GridUnitType.Star);
            left.Margin = new Thickness(0, 0, narrow ? 0 : 40, 0);
            Grid.SetRow(right, narrow ? 1 : 0);
            Grid.SetColumn(right, narrow ? 0 : 1);
            right.Margin = new Thickness(0, narrow ? 24 : 58, 0, 48);
        };
        if (entrance)
        {
            Motion.Play(backdrop, 1);
            Motion.Play(posterHost, 2);
        }
        return grid;
    }

    /// <summary>Title (displaySmall) + optional tagline (serif titleMedium italic, TextMuted).</summary>
    public static void AddTitle(Panel info, string title, string? tagline)
    {
        info.Children.Add(UiKit.Text(title, "Text.DisplaySmall"));
        if (!string.IsNullOrWhiteSpace(tagline))
        {
            var t = UiKit.Text(tagline, "Text.TitleMedium", "TextMuted");
            t.FontFamily = UiKit.Res<FontFamily>("Font.Serif");
            t.FontStyle = FontStyles.Italic;
            t.Margin = new Thickness(0, 6, 0, 0);
            info.Children.Add(t);
        }
    }

    /// <summary>RatingText + MetaLine row (12 gap above).</summary>
    public static void AddMeta(Panel info, double rating, params string?[] meta)
    {
        var row = new DockPanel { Margin = new Thickness(0, 12, 0, 0), LastChildFill = true };
        if (UiKit.Rating(rating) is { } r)
        {
            r.Margin = new Thickness(0, 0, 12, 0);
            DockPanel.SetDock(r, Dock.Left);
            row.Children.Add(r);
        }
        row.Children.Add(UiKit.MetaLine(meta));
        info.Children.Add(row);
    }

    /// <summary>TagRow: accent quality pills (max 4) then plain genre pills, wrap spacing 6.</summary>
    public static void AddTags(Panel info, IEnumerable<string> quality, IEnumerable<string> genres)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var q in quality.Take(4)) { var p = UiKit.Pill(q, accent: true); p.Margin = new Thickness(0, 0, 6, 6); wrap.Children.Add(p); }
        foreach (var g in genres) { var p = UiKit.Pill(g); p.Margin = new Thickness(0, 0, 6, 6); wrap.Children.Add(p); }
        if (wrap.Children.Count > 0) info.Children.Add(wrap);
    }

    /// <summary>CreditLine: label (labelLarge TextMuted, 96 wide) + value; hidden if blank.</summary>
    public static void AddCredit(Panel info, string label, string? value, Action? onClick = null)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var l = UiKit.Text(label, "Text.LabelLarge", "TextMuted", maxLines: 1);
        l.Width = 96;
        DockPanel.SetDock(l, Dock.Left);
        row.Children.Add(l);
        if (onClick != null)
        {
            var b = new Button
            {
                Style = UiKit.Style("Button.Plain"),
                Content = UiKit.Text(value + "  ›", "Text.BodyMedium", "Amber"),
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            b.Click += (_, _) => onClick();
            row.Children.Add(b);
        }
        else row.Children.Add(UiKit.Text(value, "Text.BodyMedium"));
        info.Children.Add(row);
    }

    public static void AddOverview(Panel info, string? overview)
    {
        if (string.IsNullOrWhiteSpace(overview)) return;
        var t = UiKit.Text(overview, "Text.BodyLarge");
        t.Opacity = 0.88;
        t.Margin = new Thickness(0, 20, 0, 0);
        info.Children.Add(t);
    }

    // ---------------- Watchlist & reminders ----------------

    public static async Task<bool> IsSaved(string type, int id)
    {
        try { return await AppServices.Plans.IsInWatchlist(type, id); }
        catch (Exception) { return await AppServices.PlansDao.IsInWatchlist(type, id); }
    }

    public static async Task ToggleSaved(string type, int id, bool saved)
    {
        try
        {
            await AppServices.Plans.SetWatchlist(type, id, !saved);
            Toast.Show(saved ? "Removed from your Watchlist" : "Added to your Watchlist");
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    public static async Task<List<ReminderEntity>> Reminders(string type, int id)
    {
        try { return await AppServices.Plans.RemindersFor(type, id); }
        catch (Exception) { return new List<ReminderEntity>(); }
    }

    public static async Task RemindMe(DependencyObject anchor, string type, int id, int? season, int? episode, string title, string? airDate)
    {
        try
        {
            var owner = UiKit.OwnerOf(anchor) ?? Application.Current.MainWindow!;
            await Veltoret.App.Plans.ReminderDialog.Show(owner, type, id, season, episode, title, airDate);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show("Reminders aren't available"); }
    }

    /// <summary>ReminderList: bell, "[S1 · E2  ·  ]Reminder {label}", cancel button.</summary>
    public static void AddReminders(Panel info, IReadOnlyList<ReminderEntity> reminders)
    {
        if (reminders.Count == 0) return;
        var list = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        foreach (var r in reminders)
        {
            var row = new DockPanel { Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 6, 0, 0) };
            var bell = UiKit.Icon("Notifications", 18, "Amber");
            bell.Margin = new Thickness(0, 0, 8, 0);
            DockPanel.SetDock(bell, Dock.Left);
            row.Children.Add(bell);
            var id = r.Id;
            var close = UiKit.IconButton("Close", "Cancel reminder", async () =>
            {
                try { await AppServices.Plans.RemoveReminder(id); }
                catch (Exception ex) { App.Log(ex); }
            }, 32);
            close.Style = UiKit.Style("Button.IconFlat");
            DockPanel.SetDock(close, Dock.Right);
            row.Children.Add(close);
            var code = Formats.EpisodeCode(r.Season, r.Episode);
            var label = "Reminder " + Formats.ReminderLabel(DateTimeOffset.FromUnixTimeMilliseconds(r.At));
            var text = UiKit.Text(code.Length > 0 ? code + "  ·  " + label : label, "Text.BodyMedium", maxLines: 1);
            row.Children.Add(text);
            list.Children.Add(row);
        }
        info.Children.Add(list);
    }

    // ---------------- Sections below the header ----------------

    public static FrameworkElement Section(string title, FrameworkElement content, double top = 32, double gap = 12)
    {
        var col = new StackPanel { Margin = new Thickness(0, top, 0, 0) };
        col.Children.Add(new SectionHeader(title));
        content.Margin = new Thickness(content.Margin.Left, gap, content.Margin.Right, content.Margin.Bottom);
        col.Children.Add(content);
        return col;
    }

    public static FrameworkElement? Cast(IReadOnlyList<CreditEntity> credits)
    {
        if (credits.Count == 0) return null;
        var row = new HorizontalRow(16);
        foreach (var c in credits.OrderBy(c => c.Ord).Take(30))
        {
            var col = new StackPanel { Width = 84 };
            var photo = new AsyncImage
            {
                Url = TmdbImages.Profile(c.ProfilePath), FallbackText = Initials(c.Name), DecodeWidth = 185,
                Width = 76, Height = 76, CornerRadius = new CornerRadius(38), BorderThickness = new Thickness(1), BorderBrush = UiKit.Brush("Outline"),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            col.Children.Add(photo);
            var name = UiKit.Text(c.Name, "Text.LabelMedium", maxLines: 2);
            name.TextAlignment = TextAlignment.Center;
            name.Margin = new Thickness(0, 8, 0, 0);
            col.Children.Add(name);
            if (!string.IsNullOrWhiteSpace(c.Character))
            {
                var ch = UiKit.Text(c.Character, "Text.BodySmall", "TextMuted", maxLines: 1);
                ch.TextAlignment = TextAlignment.Center;
                col.Children.Add(ch);
            }
            col.ToolTip = string.IsNullOrWhiteSpace(c.Character) ? c.Name : $"{c.Name} as {c.Character}";
            row.Add(col);
        }
        row.ArrowCenter = 38;
        return Section("Cast", row, 32, 14);
    }

    private static string Initials(string name) =>
        string.Concat(name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(w => char.ToUpperInvariant(w[0])));

    /// <summary>Versions / File: FileRows, 2 per row (Expanded), spacing 10.</summary>
    public static FrameworkElement? Versions(IReadOnlyList<MediaFileEntity> files, Func<MediaFileEntity, Task> play)
    {
        if (files.Count == 0) return null;
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(UiKit.Gutter - 5, 0, UiKit.Gutter - 5, 0) };
        foreach (var f in files)
        {
            var row = FileRow(f, play);
            row.Margin = new Thickness(5, 0, 5, 10);
            grid.Children.Add(row);
        }
        return Section(files.Count > 1 ? "Versions" : "File", grid);
    }

    private static FrameworkElement FileRow(MediaFileEntity f, Func<MediaFileEntity, Task> play)
    {
        var playable = CanPlayNow(f);
        var dock = new DockPanel();
        var icon = UiKit.Icon("Play", 24, "Amber");
        icon.Margin = new Thickness(0, 0, 12, 0);
        icon.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(icon, Dock.Left);
        dock.Children.Add(icon);
        var col = new StackPanel();
        col.Children.Add(UiKit.Text(f.Name, "Text.TitleSmall", maxLines: 1));
        var tags = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var q in FilenameParser.QualityTags(f.Name, f.Height).Take(3))
        {
            var p = UiKit.Pill(q, accent: true);
            p.Margin = new Thickness(0, 0, 6, 0);
            p.VerticalAlignment = VerticalAlignment.Center;
            tags.Children.Add(p);
        }
        var size = UiKit.Text(Formats.JoinTight(f.SizeBytes > 0 ? Formats.Size(f.SizeBytes) : null, Formats.RuntimeMs(f.DurationMs)), "Text.BodySmall", "TextMuted", maxLines: 1);
        size.VerticalAlignment = VerticalAlignment.Center;
        tags.Children.Add(size);
        col.Children.Add(tags);
        var (srcIcon, srcText, srcBrush) = SourceLine(f, playable);
        var src = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var si = UiKit.Icon(srcIcon, 13, srcBrush);
        si.Margin = new Thickness(0, 0, 4, 0);
        src.Children.Add(si);
        src.Children.Add(UiKit.Text(srcText, "Text.BodySmall", srcBrush, maxLines: 1));
        col.Children.Add(src);
        dock.Children.Add(col);
        var b = UiKit.ClickPanel(dock, () => _ = play(f), new Thickness(14));
        b.ToolTip = f.RelativePath.Length > 0 ? f.RelativePath + "/" + f.Name : f.Name;
        if (!playable) { b.Opacity = 0.45; b.IsEnabled = false; }
        return b;
    }

    public static (string Icon, string Text, string Brush) SourceLine(MediaFileEntity f, bool playable)
    {
        if (Accounts.IsLocal(f.AccountEmail)) return ("Computer", "On this PC", "AmberSoft");
        if (Accounts.IsSmb(f.AccountEmail))
        {
            if (!playable) return ("Dns", "Network server · needs Wi-Fi", "TextFaint");
            string root;
            try { root = AppServices.Storage.RootName(f.AccountEmail); }
            catch (Exception) { root = f.AccountEmail.Replace("smb://", ""); }
            return ("Dns", "Network server · " + root, "TextFaint");
        }
        return ("Cloud", playable ? f.AccountEmail : "Google Drive · needs internet", "TextFaint");
    }

    public static FrameworkElement? MoreLikeThis(IReadOnlyList<PosterItem> items)
    {
        if (items.Count == 0) return null;
        var row = new HorizontalRow(16);
        var template = (DataTemplate)Application.Current.FindResource("Template.PosterCard");
        foreach (var it in items) row.Add(new ContentPresenter { Content = it, ContentTemplate = template, Width = 164 });
        row.ArrowCenter = 164 * 1.5 / 2;
        return Section("More like this", row, 36);
    }

    public static FrameworkElement Attribution()
    {
        var t = UiKit.Text("Metadata and artwork from TMDB", "Text.BodySmall", "TextFaint");
        t.Margin = new Thickness(UiKit.Gutter, 32, 0, 0);
        return t;
    }

    public static void OpenTrailer(string? key)
    {
        if (string.IsNullOrEmpty(key)) { Toast.Show("Install YouTube to watch trailers"); return; }
        UiKit.OpenUrl("https://www.youtube.com/watch?v=" + Uri.EscapeDataString(key));
    }

    /// <summary>A vertical page scroller with smooth wheel scrolling.</summary>
    public static ScrollViewer Scroller(UIElement content)
    {
        var sv = new ScrollViewer
        {
            Content = content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        SmoothScroll.SetIsEnabled(sv, true);
        return sv;
    }
}

/// <summary>A menu entry of the DetailActionRow's "⋮".</summary>
public sealed record DetailMenuItem(string Label, string Icon, Action Run);

/// <summary>
/// DetailActionRow (§6.4): always one line — [Play] [Trailer?] [Watchlist?] [⋮] — with the exact overflow rules:
/// buttonWidth(label) = text width + 70; fits(ws) = play + 48 + Σ(w + 10) + 10 ≤ width.
/// </summary>
public sealed class DetailActionRow : Grid
{
    private const double Gap = 10, IconSize = 48, ButtonChrome = 20 * 2 + 20 + 8 + 2;

    public required string PlayLabel { get; init; }
    public string PlayIcon { get; init; } = "Play";
    public bool PlayEnabled { get; init; } = true;
    public required Func<Task> OnPlay { get; init; }
    public string? TrailerKey { get; init; }
    public bool LabelledTrailer { get; init; }
    public bool Saved { get; init; }
    public required Func<Task> OnToggleSaved { get; init; }
    public IReadOnlyList<DetailMenuItem> Menu { get; init; } = Array.Empty<DetailMenuItem>();

    private enum TrailerMode { None, Labelled, Icon, Menu }
    private (TrailerMode, bool)? _layout;

    public DetailActionRow()
    {
        SizeChanged += (_, e) => Layout(e.NewSize.Width);
        Loaded += (_, _) => Layout(ActualWidth);
        HorizontalAlignment = HorizontalAlignment.Stretch;
        MinHeight = 48;
    }

    private static double TextWidth(string text, Visual v)
    {
        var ft = new FormattedText(text, CultureInfo.GetCultureInfo("en-US"), FlowDirection.LeftToRight,
            new Typeface(UiKit.Res<FontFamily>("Font.Sans"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
            14, Brushes.White, VisualTreeHelper.GetDpi(v).PixelsPerDip);
        return ft.WidthIncludingTrailingWhitespace;
    }

    private void Layout(double available)
    {
        if (available <= 0) return;
        var playWidth = TextWidth(PlayLabel, this) + ButtonChrome;
        var labelled = TextWidth("Trailer", this) + ButtonChrome;
        bool Fits(params double[] ws) => playWidth + IconSize + ws.Sum(w => w + Gap) + Gap <= available;
        var mode = TrailerKey == null || !DetailCommon.Online ? TrailerMode.None
            : LabelledTrailer && Fits(IconSize, labelled) ? TrailerMode.Labelled
            : Fits(IconSize, IconSize) ? TrailerMode.Icon
            : TrailerMode.Menu;
        var watchlistInRow = mode is TrailerMode.Menu or TrailerMode.None ? Fits(IconSize) : true;
        if (_layout == (mode, watchlistInRow)) return;
        _layout = (mode, watchlistInRow);
        Build(mode, watchlistInRow);
    }

    private void Build(TrailerMode mode, bool watchlistInRow)
    {
        Children.Clear();
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var play = UiKit.Button(PlayLabel, "Button.Primary", PlayIcon);
        play.IsEnabled = PlayEnabled;
        play.Click += async (_, _) =>
        {
            ButtonAssist.SetIsLoading(play, true);
            try { await OnPlay(); }
            catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
            finally { ButtonAssist.SetIsLoading(play, false); }
        };
        row.Children.Add(play);
        void Add(FrameworkElement e) { e.Margin = new Thickness(Gap, 0, 0, 0); row.Children.Add(e); }
        if (mode == TrailerMode.Labelled) Add(UiKit.Button("Trailer", "Button.Ghost", "SmartDisplay", () => DetailCommon.OpenTrailer(TrailerKey)));
        else if (mode == TrailerMode.Icon) Add(UiKit.IconButton("SmartDisplay", "Watch trailer", () => DetailCommon.OpenTrailer(TrailerKey), IconSize));
        if (watchlistInRow)
        {
            var w = UiKit.IconButton(Saved ? "Bookmark" : "BookmarkBorder", Saved ? "Remove from Watchlist" : "Watch later", () => _ = OnToggleSaved(), IconSize,
                tint: Saved ? "Amber" : "Text");
            Add(w);
        }
        Button more = null!;
        more = UiKit.IconButton("MoreVert", "More", () =>
        {
            var menu = new ContextMenu();
            if (mode == TrailerMode.Menu) menu.Items.Add(UiKit.MenuItem("Watch trailer", "SmartDisplay", () => DetailCommon.OpenTrailer(TrailerKey)));
            if (!watchlistInRow)
                menu.Items.Add(UiKit.MenuItem(Saved ? "Remove from Watchlist" : "Watch later", Saved ? "Bookmark" : "BookmarkBorder", () => _ = OnToggleSaved()));
            foreach (var m in Menu) menu.Items.Add(UiKit.MenuItem(m.Label, m.Icon, m.Run));
            UiKit.ShowMenu(more, menu);
        }, IconSize);
        Add(more);
        Children.Add(row);
    }
}
