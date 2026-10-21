using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;

namespace Veltoret.App.Pages.Library;

/// <summary>Movies / TV Shows grid with filter chips, genre, sort and source menus.</summary>
public sealed class LibraryPage : LivePage
{
    private readonly LibraryViewModel _vm;
    private readonly ScreenHeader _header;
    private readonly ContentControl _body = new() { Focusable = false };
    private readonly VirtualGrid _grid;
    private readonly string _title;
    private IReadOnlyList<PosterItem>? _lastShown;

    public LibraryPage(bool shows, string? genre = null)
    {
        _vm = new LibraryViewModel(shows);
        if (genre != null) _vm.Genre = genre;
        _title = shows ? "TV Shows" : "Movies";
        _header = new ScreenHeader(_title);
        _header.AddAction(UiKit.IconButton("Search", "Search", () => AppServices.Navigator.Push(new SearchRoute())));
        Button? sort = null;
        sort = UiKit.IconButton("Sort", "Sort", () => UiKit.ShowMenu(sort!, SortMenu()));
        _header.AddAction(sort);

        _grid = new VirtualGrid
        {
            MinCellWidth = 156, HGap = 20, VGap = 28, BottomPadding = 32, TopPadding = 4,
            CellTemplate = (DataTemplate)Application.Current.FindResource("Template.PosterCard"),
        };
        var dock = new DockPanel();
        DockPanel.SetDock(_header, Dock.Top);
        dock.Children.Add(_header);
        dock.Children.Add(_body);
        _body.Content = new LoadingBox();
        Content = dock;
        _vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(LibraryViewModel.Shown)) Render();
        };
    }

    protected override IReadOnlyCollection<string> Tables => LibraryViewModel.WatchedTables;

    protected override async Task Refresh()
    {
        await _vm.Load();
        Render(force: true);
    }

    private void Render(bool force = false)
    {
        var total = _vm.All.Count;
        _header.Subtitle = _vm.Loading ? null
            : _vm.Source != null ? $"{_vm.Shown.Count} of {total} titles · {_vm.SourceLabel}"
            : total == 1 ? "1 title" : $"{total} titles";
        if (_vm.Loading) { _body.Content = new LoadingBox(); return; }
        var lower = _title.ToLowerInvariant();
        if (total == 0 && !_vm.Online)
        {
            _body.Content = new EmptyState("CloudOff", $"No {lower} on this device",
                $"Your {lower} are on Google Drive. Connect to the internet to watch them, or add a folder from this device in Settings.");
            return;
        }
        if (total == 0 && _vm.Unmatched == 0)
        {
            _body.Content = new EmptyState(_vm.Shows ? "LiveTv" : "Movie", $"No {lower} yet",
                $"Add a {lower} folder in Settings, or wait for the library scan to finish.");
            return;
        }
        if (!force && _lastShown != null && _lastShown.SequenceEqual(_vm.Shown)) return;
        _lastShown = _vm.Shown;
        var items = new List<object> { Chips() };
        if (_vm.Shown.Count == 0)
        {
            var none = UiKit.Text("Nothing matches these filters.", "Text.BodyMedium", "TextMuted");
            none.Margin = new Thickness(0, 40, 0, 40);
            items.Add(none);
        }
        else items.AddRange(_vm.Shown);
        _grid.Source = items;
        if (_body.Content != _grid) _body.Content = _grid;
    }

    private FrameworkElement Chips()
    {
        var strip = new WrapPanel { Margin = new Thickness(0, 0, 0, 20) };
        void Add(FrameworkElement chip) { chip.Margin = new Thickness(0, 0, 8, 8); strip.Children.Add(chip); }
        if (_vm.Unmatched > 0 && _vm.Online)
        {
            var c = Chip($"{_vm.Unmatched} unmatched", false, "ErrorOutline");
            c.Click += (_, _) => { c.IsChecked = false; AppServices.Navigator.Navigate(new FixMatchRoute()); };
            Add(c);
        }
        foreach (var (label, f) in new[] { ("All", WatchFilter.All), ("Unwatched", WatchFilter.Unwatched), ("In progress", WatchFilter.InProgress), ("Watched", WatchFilter.Watched), ("4K", WatchFilter.FourK) })
        {
            var c = Chip(label, _vm.Filter == f);
            c.Click += (_, _) => { c.IsChecked = _vm.Filter == f; _vm.Filter = f; };
            Add(c);
        }
        if (_vm.Genres.Count > 0)
        {
            ToggleButton g = null!;
            g = Chip(_vm.Genre ?? "Genre", _vm.Genre != null, "Tune");
            g.Click += (_, _) =>
            {
                g.IsChecked = _vm.Genre != null;
                var menu = new ContextMenu { MaxHeight = 480 };
                menu.Items.Add(UiKit.MenuItem("All genres", null, () => _vm.Genre = null, _vm.Genre == null));
                foreach (var name in _vm.Genres) menu.Items.Add(UiKit.MenuItem(name, null, () => _vm.Genre = name, _vm.Genre == name));
                UiKit.ShowMenu(g, menu);
            };
            Add(g);
        }
        return strip;
    }

    private static ToggleButton Chip(string label, bool selected, string? icon = null)
    {
        var c = new ToggleButton { Content = label, Style = UiKit.Style("Chip"), IsChecked = selected };
        if (icon != null) ButtonAssist.SetIcon(c, Controls.Icon.Get(icon));
        return c;
    }

    private ContextMenu SortMenu()
    {
        var menu = new ContextMenu();
        foreach (var (label, s) in new[] { ("Recently added", LibrarySort.Recent), ("Title", LibrarySort.Title), ("Release year", LibrarySort.Year), ("Rating", LibrarySort.Rating) })
            menu.Items.Add(UiKit.MenuItem(label, null, () => _vm.Sort = s, _vm.Sort == s));
        if (_vm.Sources.Count > 0)
        {
            menu.Items.Add(new Separator());
            menu.Items.Add(new MenuItem { Header = "SOURCE", Style = UiKit.Style("MenuItem.Caption") });
            menu.Items.Add(UiKit.MenuItem("All sources", null, () => _vm.Source = null, _vm.Source == null));
            foreach (var src in _vm.Sources) menu.Items.Add(UiKit.MenuItem(src.Label, null, () => _vm.Source = src.Account, _vm.Source == src.Account));
        }
        return menu;
    }
}
