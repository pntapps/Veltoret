using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Search;

/// <summary>Search results: movies and shows in the library (title, director, collection, cast, creator).</summary>
public sealed partial class SearchViewModel : ObservableObject
{
    [ObservableProperty] private string _query = "";
    [ObservableProperty] private IReadOnlyList<PosterItem> _movies = Array.Empty<PosterItem>();
    [ObservableProperty] private IReadOnlyList<PosterItem> _shows = Array.Empty<PosterItem>();
    [ObservableProperty] private bool _searched;

    private int _generation;

    public async Task Run(string raw)
    {
        var q = raw.Trim();
        var gen = ++_generation;
        if (q.Length == 0)
        {
            Query = "";
            Movies = Array.Empty<PosterItem>();
            Shows = Array.Empty<PosterItem>();
            Searched = false;
            return;
        }
        var lib = AppServices.Library;
        var (movieHits, showHits) = await lib.Search(q);
        var movies = (await lib.Movies()).ToDictionary(m => m.Movie.TmdbId);
        var shows = (await lib.Shows()).ToDictionary(s => s.Show.TmdbId);
        if (gen != _generation) return;
        Movies = movieHits.Where(h => movies.ContainsKey(h.Id)).Select(h =>
        {
            var m = movies[h.Id].Movie;
            return new PosterItem
            {
                Id = m.TmdbId, Title = m.Title, PosterUrl = TmdbImages.Poster(m.PosterPath), Rating = m.Rating,
                Subtitle = PosterItems.NullIfEmpty(Formats.JoinTight(m.Year?.ToString(), h.Reason)),
            };
        }).ToList();
        Shows = showHits.Where(h => shows.ContainsKey(h.Id)).Select(h =>
        {
            var s = shows[h.Id].Show;
            return new PosterItem
            {
                Id = s.TmdbId, IsShow = true, Title = s.Name, PosterUrl = TmdbImages.Poster(s.PosterPath), Rating = s.Rating,
                Subtitle = PosterItems.NullIfEmpty(Formats.JoinTight(s.Year?.ToString(), h.Reason)),
            };
        }).ToList();
        Query = q;
        Searched = true;
    }
}

public sealed class SearchPage : LivePage
{
    private readonly SearchViewModel _vm = new();
    private readonly TextBox _box;
    private readonly Button _clear;
    private readonly Button _mic;
    private readonly ContentControl _body = new() { Focusable = false };
    private readonly VirtualGrid _grid;
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private readonly bool _spoken;

    public SearchPage(string? query = null, bool spoken = false)
    {
        _spoken = spoken;
        var header = new ScreenHeader("Search", back: true);
        _box = new TextBox { Style = UiKit.Style("TextBox"), MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
        ButtonAssist.SetIcon(_box, Controls.Icon.Get("Search"));
        ButtonAssist.SetPlaceholder(_box, "Titles, actors, directors, collections");
        System.Windows.Automation.AutomationProperties.SetName(_box, "Titles, actors, directors, collections");
        _clear = UiKit.IconButton("Close", "Clear", () => { _box.Clear(); _box.Focus(); }, 32);
        _clear.Style = UiKit.Style("Button.IconFlat");
        _mic = UiKit.IconButton("Mic", "Search by voice", () => _ = Listen(), 32);
        _mic.Style = UiKit.Style("Button.IconFlat");
        _mic.Foreground = UiKit.Brush("Amber");
        var trailing = new Grid();
        trailing.Children.Add(_clear);
        trailing.Children.Add(_mic);
        _box.Tag = trailing;
        _box.TextChanged += (_, _) =>
        {
            UpdateTrailing();
            _debounce.Stop();
            _debounce.Start();
        };
        _box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { _debounce.Stop(); _ = Search(); } };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = Search(); };

        var boxHost = new Grid { Margin = new Thickness(UiKit.Gutter, 4, UiKit.Gutter, 0) };
        boxHost.Children.Add(_box);
        _box.HorizontalAlignment = HorizontalAlignment.Left;
        boxHost.SizeChanged += (_, _) => _box.Width = Math.Min(720, Math.Max(200, boxHost.ActualWidth));

        _grid = new VirtualGrid
        {
            MinCellWidth = 150, HGap = 14, VGap = 20, TopPadding = 20, BottomPadding = 20,
            CellTemplate = (DataTemplate)Application.Current.FindResource("Template.PosterCard"),
        };
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(boxHost, Dock.Top);
        dock.Children.Add(header);
        dock.Children.Add(boxHost);
        dock.Children.Add(_body);
        Content = dock;
        UpdateTrailing();
        if (!string.IsNullOrEmpty(query)) _box.Text = query;
        Loaded += (_, _) => { if (!_spoken) Dispatcher.BeginInvoke(() => { _box.Focus(); _box.CaretIndex = _box.Text.Length; }, DispatcherPriority.Input); };
        Unloaded += (_, _) => _debounce.Stop();
    }

    protected override IReadOnlyCollection<string> Tables { get; } = new[] { "movies", "shows", "credits", "media_files" };

    protected override async Task Refresh()
    {
        if (_box.Text.Trim().Length > 0) await Search();
        else Render();
    }

    private void UpdateTrailing()
    {
        var empty = _box.Text.Length == 0;
        _clear.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        _mic.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task Search()
    {
        try { await _vm.Run(_box.Text); }
        catch (Exception ex) { App.Log(ex); }
        Render();
    }

    private void Render()
    {
        if (!_vm.Searched) { _body.Content = null; return; }
        if (_vm.Movies.Count == 0 && _vm.Shows.Count == 0)
        {
            _body.Content = new EmptyState("Search", "No results", $"Nothing in your library matches \"{_vm.Query}\".");
            return;
        }
        var items = new List<object>();
        if (_vm.Movies.Count > 0)
        {
            items.Add(Header("Movies", items.Count == 0));
            items.AddRange(_vm.Movies);
        }
        if (_vm.Shows.Count > 0)
        {
            items.Add(Header("TV Shows", items.Count == 0));
            items.AddRange(_vm.Shows);
        }
        _grid.Source = items;
        _body.Content = _grid;
    }

    private static FrameworkElement Header(string text, bool first)
    {
        var t = UiKit.Text(text, "Text.HeadlineSmall", maxLines: 1);
        t.Margin = new Thickness(0, first ? 0 : 8, 0, 20);
        return t;
    }

    private async Task Listen()
    {
        string? heard = null;
        try
        {
            _mic.IsEnabled = false;
            Toast.Show("Say a title, actor or director");
            heard = await Veltoret.App.Plans.VoiceSearch.Listen();
        }
        catch (Exception ex) { App.Log(ex); }
        finally { _mic.IsEnabled = true; }
        if (string.IsNullOrWhiteSpace(heard))
        {
            Toast.Show("Voice search isn't available");
            return;
        }
        _box.Text = heard;
        _debounce.Stop();
        await Search();
    }
}
