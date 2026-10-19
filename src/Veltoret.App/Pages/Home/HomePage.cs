using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core.Library;

namespace Veltoret.App.Pages.Home;

/// <summary>Home (Android HomeScreen): header, status block, featured hero, panels, rows.</summary>
public sealed class HomePage : LivePage
{
    private readonly HomeViewModel _vm = new();
    private readonly StackPanel _list = new() { Margin = new Thickness(0, 0, 0, 32) };
    private readonly ContentControl _status = new() { Focusable = false };
    private readonly FeaturedPager _featured = new();
    private readonly ContentControl _panels = new() { Focusable = false };
    private readonly StackPanel _rows = new();
    private readonly Dictionary<string, (HomeRow Row, FrameworkElement View)> _rowViews = new();
    private readonly Border _scanChip;
    private readonly TextBlock _scanText;
    private bool _featuredEntered;

    public HomePage()
    {
        // Header: Wordmark (fills) · ScanChip · Cast · Search.
        var header = new DockPanel { Margin = new Thickness(UiKit.Gutter, 12, 12, 12), LastChildFill = true };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        _scanText = UiKit.Text("", "Text.LabelMedium", "TextMuted", wrap: false);
        _scanText.VerticalAlignment = VerticalAlignment.Center;
        var chipRow = new StackPanel { Orientation = Orientation.Horizontal };
        chipRow.Children.Add(new Spinner { Width = 12, Height = 12, Thickness = 1.5, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        chipRow.Children.Add(_scanText);
        _scanChip = new Border
        {
            CornerRadius = new CornerRadius(10), Background = UiKit.Brush("Surface"), BorderBrush = UiKit.Brush("Outline"),
            BorderThickness = new Thickness(1), Padding = new Thickness(10, 6, 10, 6), Child = chipRow,
            Margin = new Thickness(0, 0, 8, 0), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center,
        };
        actions.Children.Add(_scanChip);
        if (CreateCastButton() is { } cast)
        {
            cast.Margin = new Thickness(0, 0, 8, 0);
            actions.Children.Add(cast);
        }
        actions.Children.Add(UiKit.IconButton("Search", "Search", () => AppServices.Navigator.Push(new SearchRoute())));
        DockPanel.SetDock(actions, Dock.Right);
        header.Children.Add(actions);
        header.Children.Add(new Wordmark());

        _list.Children.Add(header);
        _list.Children.Add(_status);
        _featured.Visibility = Visibility.Collapsed;
        _list.Children.Add(_featured);
        _list.Children.Add(_panels);
        _list.Children.Add(_rows);
        _status.Content = new LoadingBox(400);

        var scroll = new ScrollViewer
        {
            Content = _list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        SmoothScroll.SetIsEnabled(scroll, true);
        Content = scroll;
    }

    protected override IReadOnlyCollection<string> Tables => HomeViewModel.WatchedTables;
    protected override bool WatchScan => true;

    private ScanState _lastScan = new();

    protected override void OnScanState(ScanState s)
    {
        var wasRunning = _lastScan.Running;
        _lastScan = s;
        _scanChip.Visibility = s.Running ? Visibility.Visible : Visibility.Collapsed;
        _scanText.Text = s.Phase.StartsWith("Matching", StringComparison.Ordinal) ? "Matching" : $"Syncing {s.FilesFound}";
        // The empty states depend on the scan ("Building your library").
        if (wasRunning != s.Running || (_vm.State.IsEmpty && s.Running)) RenderStatus();
    }

    protected override async Task Refresh()
    {
        await _vm.Load();
        Render(_vm.State);
    }

    private void Render(HomeState state)
    {
        RenderStatus();

        // Featured hero (entrance 0).
        _featured.Visibility = state.Featured.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _featured.SetItems(state.Featured);
        if (state.Featured.Count > 0 && !_featuredEntered)
        {
            _featuredEntered = true;
            Motion.Play(_featured, 0);
        }

        // Panels.
        var panels = new StackPanel();
        if (state.UnmatchedCount > 0 && state.Online)
        {
            panels.Children.Add(Panel("ErrorOutline",
                state.UnmatchedCount == 1 ? "1 file needs a match" : $"{state.UnmatchedCount} files need a match",
                "Click to identify them on TMDB",
                () => AppServices.Navigator.Navigate(new FixMatchRoute()), new Thickness(UiKit.Gutter, 12, UiKit.Gutter, 12)));
        }
        if (state.ArchiveCount > 0)
        {
            panels.Children.Add(Panel("FolderZip",
                state.ArchiveCount == 1 ? "1 ZIP archive in your library" : $"{state.ArchiveCount} ZIP archives in your library",
                "Click to unpack them so they can play",
                () => Navigate(new ArchivesRoute()), new Thickness(UiKit.Gutter, 6, UiKit.Gutter, 6)));
        }
        _panels.Content = panels.Children.Count > 0 ? panels : null;

        // Rows (reuse views whose items didn't change, so scroll positions and images stay).
        var keep = new HashSet<string>();
        _rows.Children.Clear();
        foreach (var row in state.Rows)
        {
            keep.Add(row.Title);
            FrameworkElement view;
            if (_rowViews.TryGetValue(row.Title, out var existing) && existing.Row.Items.SequenceEqual(row.Items) && existing.Row.Wide == row.Wide)
                view = existing.View;
            else
            {
                view = BuildRow(row, existing.View == null && row.Title == "Continue Watching");
                _rowViews[row.Title] = (row, view);
            }
            if (view.Parent is Panel p) p.Children.Remove(view);
            _rows.Children.Add(view);
        }
        foreach (var k in _rowViews.Keys.Where(k => !keep.Contains(k)).ToList()) _rowViews.Remove(k);
    }

    private void RenderStatus()
    {
        var state = _vm.State;
        var scan = _lastScan;
        FrameworkElement? status = null;
        if (state.Loading) status = new LoadingBox(400);
        else if (!state.HasFolders)
            status = new EmptyState("CreateNewFolder", "Choose your library folders",
                "Pick the Google Drive or device folders that hold your movies and TV shows.",
                "Open Settings", () => Navigate(new SettingsRoute(), tab: true));
        else if (state.IsEmpty && scan.Running)
            status = new EmptyState("VideoLibrary", "Building your library",
                $"Found {scan.FilesFound} videos so far. Posters will appear here as titles are matched.");
        else if (state.IsEmpty && !state.Online)
            status = new EmptyState("CloudOff", "Nothing on this device",
                "Your library is on Google Drive. Connect to the internet to watch it, or add a folder from this device in Settings.");
        else if (state.IsEmpty)
            status = new EmptyState("VideoLibrary", "Nothing here yet",
                string.IsNullOrEmpty(scan.Error) ? "No videos were found in your library folders. Add files to Drive and scan again." : scan.Error!,
                "Scan now", () => _ = ScanNow());
        if (status != null) status.Margin = new Thickness(0, 40, 0, 0);
        _status.Content = status;
    }

    private static async Task ScanNow()
    {
        try { await AppServices.Scans.RunNow(); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    private static void Navigate(Route r, bool tab = false)
    {
        try
        {
            if (!AppServices.Navigator.IsRegistered(r.GetType())) { Toast.Show("That screen isn't available yet"); return; }
            if (tab) AppServices.Navigator.SelectTab(r);
            else AppServices.Navigator.Navigate(r);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    private static FrameworkElement Panel(string icon, string title, string body, Action onClick, Thickness margin)
    {
        var row = new DockPanel();
        var i = UiKit.Icon(icon, 24, "Amber");
        i.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(i, Dock.Left);
        row.Children.Add(i);
        var chevron = UiKit.Icon("ChevronRight", 22, "TextMuted");
        DockPanel.SetDock(chevron, Dock.Right);
        row.Children.Add(chevron);
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        col.Children.Add(UiKit.Text(title, "Text.TitleSmall", maxLines: 1));
        col.Children.Add(UiKit.Text(body, "Text.BodySmall", "TextMuted", maxLines: 1));
        row.Children.Add(col);
        var b = UiKit.ClickPanel(row, onClick);
        b.Margin = margin;
        return b;
    }

    private static FrameworkElement BuildRow(HomeRow row, bool entrance)
    {
        var col = new StackPanel { Margin = new Thickness(0, 28, 0, 0) };
        col.Children.Add(new SectionHeader(row.Title, row.Action, row.ActionRoute is { } r ? () => Navigate(r, tab: true) : null));
        var strip = new HorizontalRow(16) { Margin = new Thickness(0, 12, 0, 0) };
        var width = row.Wide ? 360.0 : 164.0;
        strip.ArrowCenter = row.Wide ? width * 9 / 16 / 2 : width * 1.5 / 2;
        var template = (DataTemplate)Application.Current.FindResource(row.Wide ? "Template.WideCard" : "Template.PosterCard");
        foreach (var item in row.Items)
            strip.Add(new ContentPresenter { Content = item, ContentTemplate = template, Width = width, VerticalAlignment = VerticalAlignment.Top });
        col.Children.Add(strip);
        if (entrance) Motion.Play(col, 1);
        return col;
    }

    /// <summary>The network module's Cast button, when it exists (looked up by name so Home doesn't depend on it).</summary>
    private static FrameworkElement? CreateCastButton()
    {
        try
        {
            var type = typeof(HomePage).Assembly.GetType("Veltoret.App.Network.CastButton");
            return type == null ? null : Activator.CreateInstance(type) as FrameworkElement;
        }
        catch (Exception ex) { App.Log(ex); return null; }
    }
}
