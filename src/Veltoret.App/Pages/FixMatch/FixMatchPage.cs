using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.FixMatch;

public sealed record Candidate(int Id, string Title, string? Year, string? Overview, string? PosterUrl);

public sealed partial class FixMatchViewModel : ObservableObject
{
    private static readonly Regex YearSplit = new(@"^(.*?)\s*\(?((?:19|20)[0-9]{2})\)?$", RegexOptions.CultureInvariant);

    public FixMatchViewModel(IReadOnlyList<string> fileIds, MediaKind kind, string query)
    {
        FileIds = fileIds;
        _kind = kind;
        _query = query;
    }

    public IReadOnlyList<string> FileIds { get; }
    [ObservableProperty] private MediaKind _kind;
    [ObservableProperty] private string _query;
    [ObservableProperty] private bool _searching;
    [ObservableProperty] private string? _error;
    [ObservableProperty] private IReadOnlyList<Candidate> _results = Array.Empty<Candidate>();
    [ObservableProperty] private int? _applying;

    public static (string Title, int? Year) Split(string query)
    {
        var q = query.Trim();
        var m = YearSplit.Match(q);
        if (m.Success && !string.IsNullOrWhiteSpace(m.Groups[1].Value))
            return (m.Groups[1].Value.Trim(), int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture));
        return (q, null);
    }

    public async Task Search()
    {
        if (string.IsNullOrWhiteSpace(Query)) return;
        Searching = true;
        Error = null;
        try
        {
            var (title, year) = Split(Query);
            if (Kind == MediaKind.MOVIE)
            {
                var list = await AppServices.Tmdb.SearchMovies(title, year);
                Results = list.Select(r => new Candidate(r.Id, r.Title, TmdbRepository.YearOf(r.ReleaseDate)?.ToString(), r.Overview, TmdbImages.Poster(r.PosterPath, "w185"))).ToList();
            }
            else
            {
                var list = await AppServices.Tmdb.SearchShows(title, year);
                Results = list.Select(r => new Candidate(r.Id, r.Name, TmdbRepository.YearOf(r.FirstAirDate)?.ToString(), r.Overview, TmdbImages.Poster(r.PosterPath, "w185"))).ToList();
            }
        }
        catch (Exception ex)
        {
            Results = Array.Empty<Candidate>();
            Error = string.IsNullOrWhiteSpace(ex.Message) ? "Search failed" : ex.Message;
        }
        finally { Searching = false; }
    }

    public async Task<bool> Apply(Candidate c)
    {
        if (Applying != null) return false;
        Applying = c.Id;
        Error = null;
        try
        {
            await AppServices.Scanner.ApplyManualMatch(FileIds, Kind, c.Id);
            return true;
        }
        catch (Exception ex)
        {
            Error = string.IsNullOrWhiteSpace(ex.Message) ? "Could not apply match" : ex.Message;
            return false;
        }
        finally { Applying = null; }
    }
}

/// <summary>Fix match: search TMDB as a movie or a show and apply the pick to the files.</summary>
public sealed class FixMatchPage : UserControl
{
    private readonly IReadOnlyList<string> _ids;
    private readonly string? _kindHint;
    private readonly string? _queryHint;
    private FixMatchViewModel? _vm;
    private readonly ScreenHeader _header;
    private readonly ToggleButton _movieChip;
    private readonly ToggleButton _tvChip;
    private readonly TextBox _box;
    private readonly Button _search;
    private readonly Button _ignore;
    private readonly TextBlock _error;
    private readonly ContentControl _results = new() { Focusable = false };
    private readonly VirtualGrid _grid = new() { MinCellWidth = 420, HGap = 10, VGap = 10, TopPadding = 12, BottomPadding = 20 };

    public FixMatchPage(IReadOnlyList<string> fileIds, string? kind, string? query)
    {
        _ids = fileIds;
        _kindHint = kind;
        _queryHint = query;
        SetResourceReference(BackgroundProperty, "Brush.Background");
        _header = new ScreenHeader("Fix match", Formats.Plural(fileIds.Count, "file", "files"), back: true);

        _movieChip = new ToggleButton { Content = "Movie", Style = UiKit.Style("Chip") };
        _tvChip = new ToggleButton { Content = "TV Show", Style = UiKit.Style("Chip"), Margin = new Thickness(8, 0, 0, 0) };
        _movieChip.Click += (_, _) => SetKind(MediaKind.MOVIE);
        _tvChip.Click += (_, _) => SetKind(MediaKind.EPISODE);
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(UiKit.Gutter, 0, UiKit.Gutter, 0) };
        chips.Children.Add(_movieChip);
        chips.Children.Add(_tvChip);

        _box = new TextBox { Style = UiKit.Style("TextBox") };
        ButtonAssist.SetIcon(_box, Controls.Icon.Get("Search"));
        ButtonAssist.SetPlaceholder(_box, "Title (add a year to narrow)");
        _box.KeyDown += (_, e) => { if (e.Key == Key.Enter) _ = Search(); };
        _search = UiKit.Button("Search", "Button.Primary", onClick: () => _ = Search());
        _search.Margin = new Thickness(10, 0, 0, 0);
        var row = new DockPanel { Margin = new Thickness(UiKit.Gutter, 12, UiKit.Gutter, 0), MaxWidth = 760 + 2 * UiKit.Gutter, HorizontalAlignment = HorizontalAlignment.Left };
        DockPanel.SetDock(_search, Dock.Right);
        row.Children.Add(_search);
        row.Children.Add(_box);
        row.Loaded += (_, _) => row.Width = Math.Min(760 + 2 * UiKit.Gutter, Math.Max(400, ActualWidth));
        SizeChanged += (_, _) => row.Width = Math.Min(760 + 2 * UiKit.Gutter, Math.Max(400, ActualWidth));

        _ignore = UiKit.Button(fileIds.Count == 1 ? "Not a movie or show? Ignore this file" : "Not a movie or show? Ignore these files", "Button.TextMuted",
            onClick: async () =>
            {
                try
                {
                    await AppServices.Scanner.Ignore(_ids);
                    AppServices.Navigator.GoBack();
                }
                catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
            });
        _ignore.HorizontalAlignment = HorizontalAlignment.Left;
        _ignore.Margin = new Thickness(UiKit.Gutter - 8, 8, 0, 0);
        _error = UiKit.Text("", "Text.BodySmall", "Danger");
        _error.Margin = new Thickness(UiKit.Gutter, 8, UiKit.Gutter, 0);
        _error.Visibility = Visibility.Collapsed;

        var top = new StackPanel();
        top.Children.Add(_header);
        top.Children.Add(chips);
        top.Children.Add(row);
        top.Children.Add(_ignore);
        top.Children.Add(_error);
        var dock = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        dock.Children.Add(top);
        dock.Children.Add(_results);
        Content = dock;
        _results.Content = new LoadingBox();
        Loaded += async (_, _) => { if (_vm == null) await Init(); };
    }

    private async Task Init()
    {
        var files = await AppServices.MediaFileDao.Files(_ids);
        var kind = _kindHint switch
        {
            "MOVIE" => MediaKind.MOVIE,
            "EPISODE" => MediaKind.EPISODE,
            _ => files.FirstOrDefault()?.Kind ?? MediaKind.MOVIE,
        };
        var first = files.FirstOrDefault();
        var query = _queryHint
            ?? (first == null ? "" : string.IsNullOrWhiteSpace(first.ParsedTitle) ? Path.GetFileNameWithoutExtension(first.Name)
                : first.ParsedYear is { } y && kind == MediaKind.MOVIE ? $"{first.ParsedTitle} {y}" : first.ParsedTitle);
        _vm = new FixMatchViewModel(_ids, kind, query);
        _vm.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Render);
        _box.Text = query;
        _box.TextChanged += (_, _) => { if (_vm != null) _vm.Query = _box.Text; };
        Render();
        await _vm.Search();
        _ = Dispatcher.BeginInvoke(() => { _box.Focus(); _box.CaretIndex = _box.Text.Length; });
    }

    private void SetKind(MediaKind kind)
    {
        if (_vm == null) return;
        if (_vm.Kind != kind)
        {
            _vm.Kind = kind;
            _ = _vm.Search();
        }
        Render();
    }

    private async Task Search()
    {
        if (_vm == null) return;
        _vm.Query = _box.Text;
        await _vm.Search();
    }

    private IReadOnlyList<Candidate>? _shown;
    private int? _shownApplying;

    private void Render()
    {
        if (_vm == null) return;
        _movieChip.IsChecked = _vm.Kind == MediaKind.MOVIE;
        _tvChip.IsChecked = _vm.Kind == MediaKind.EPISODE;
        ButtonAssist.SetIsLoading(_search, _vm.Searching);
        _error.Text = _vm.Error ?? "";
        _error.Visibility = string.IsNullOrEmpty(_vm.Error) ? Visibility.Collapsed : Visibility.Visible;
        if (_vm.Searching && _vm.Results.Count == 0) { _results.Content = new LoadingBox(); _shown = null; return; }
        if (!_vm.Searching && _vm.Results.Count == 0 && _vm.Error == null)
        {
            _results.Content = new EmptyState("Movie", "No results", "Try a shorter title or switch between Movie and TV Show.");
            _shown = null;
            return;
        }
        if (ReferenceEquals(_shown, _vm.Results) && _shownApplying == _vm.Applying && _results.Content == _grid) return;
        _shown = _vm.Results;
        _shownApplying = _vm.Applying;
        _grid.Source = _vm.Results.Select(c => (object)new UiCell(("c", c.Id, _vm.Applying == c.Id), () => CandidateCard(c))).ToList();
        _results.Content = _grid;
    }

    private FrameworkElement CandidateCard(Candidate c)
    {
        var dock = new DockPanel();
        var poster = new AsyncImage
        {
            Url = c.PosterUrl, FallbackText = c.Title.Length > 0 ? c.Title[..1] : "?", DecodeWidth = 185, Width = 64, Height = 96,
            CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), BorderBrush = UiKit.Brush("Outline"), VerticalAlignment = VerticalAlignment.Top,
        };
        DockPanel.SetDock(poster, Dock.Left);
        dock.Children.Add(poster);
        if (_vm?.Applying == c.Id)
        {
            var spin = new Spinner { Width = 20, Height = 20, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(spin, Dock.Right);
            dock.Children.Add(spin);
        }
        var col = new StackPanel { Margin = new Thickness(14, 0, 0, 0) };
        col.Children.Add(UiKit.Text(c.Title, "Text.TitleMedium", maxLines: 2));
        if (c.Year != null) col.Children.Add(UiKit.Text(c.Year, "Text.BodySmall", "Amber", maxLines: 1));
        if (!string.IsNullOrWhiteSpace(c.Overview))
        {
            var o = UiKit.Text(c.Overview, "Text.BodySmall", "TextMuted", maxLines: 3);
            o.Margin = new Thickness(0, 4, 0, 0);
            col.Children.Add(o);
        }
        dock.Children.Add(col);
        var card = UiKit.ClickPanel(dock, async () =>
        {
            if (_vm == null || _vm.Applying != null) return;
            if (await _vm.Apply(c)) AppServices.Navigator.GoBack();
        }, new Thickness(12));
        return card;
    }
}
