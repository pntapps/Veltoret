using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Details;

/// <summary>Collection page (Android CollectionScreen): owned parts link to the movie, the rest are dimmed.</summary>
public sealed class CollectionPage : LivePage
{
    private readonly int _id;
    private readonly ContentControl _root = new() { Focusable = false };
    private TmdbCollection? _tmdb;
    private bool _tmdbTried;
    private bool _entered;

    public CollectionPage(int collectionId)
    {
        _id = collectionId;
        _root.Content = new LoadingBox();
        Content = _root;
    }

    protected override IReadOnlyCollection<string> Tables { get; } = new[] { "movies", "media_files", "watch_state" };

    protected override async Task Refresh()
    {
        var owned = (await AppServices.Library.Movies()).Where(m => m.Movie.CollectionId == _id).Select(m => m.Movie)
            .OrderBy(m => string.IsNullOrEmpty(m.ReleaseDate) ? "9999" : m.ReleaseDate, StringComparer.Ordinal).ToList();
        if (owned.Count == 0)
        {
            if (AppServices.Navigator.Current?.Page == this) AppServices.Navigator.GoBack();
            return;
        }
        var states = (await AppServices.Watch.All()).ToDictionary(s => s.Key);
        Render(owned, states);
        if (!_tmdbTried && IsOnline)
        {
            _tmdbTried = true;
            try
            {
                _tmdb = await AppServices.Tmdb.Collection(_id);
                Render(owned, states);
            }
            catch (Exception) { }
        }
    }

    private void Render(List<MovieEntity> owned, Dictionary<string, WatchStateEntity> states)
    {
        var first = owned[0];
        var name = !string.IsNullOrWhiteSpace(_tmdb?.Name) ? _tmdb!.Name : first.CollectionName ?? first.Title;
        var backdrop = TmdbImages.Backdrop(_tmdb?.BackdropPath ?? first.BackdropPath);
        var poster = TmdbImages.Poster(_tmdb?.PosterPath ?? first.PosterPath, "w500");
        var ownedById = owned.ToDictionary(m => m.TmdbId);

        var info = new StackPanel();
        DetailCommon.AddTitle(info, name, null);
        var badge = _tmdb is { Parts.Count: > 0 }
            ? $"{owned.Count} of {_tmdb.Parts.Count} in your library"
            : $"{owned.Count} in your library";
        var pill = UiKit.Pill(badge, accent: true);
        pill.Margin = new Thickness(0, 12, 0, 0);
        info.Children.Add(pill);
        DetailCommon.AddOverview(info, _tmdb?.Overview);

        List<PosterItem> parts;
        if (_tmdb is { Parts.Count: > 0 })
        {
            parts = _tmdb.Parts.Select(p =>
            {
                if (ownedById.TryGetValue(p.Id, out var m)) return PosterItems.Movie(m, states.GetValueOrDefault(WatchKeys.Movie(m.TmdbId)));
                var year = TmdbRepository.YearOf(p.ReleaseDate);
                return new PosterItem
                {
                    Id = p.Id, Title = p.Title, PosterUrl = TmdbImages.Poster(p.PosterPath), Clickable = false,
                    Subtitle = Formats.JoinTight(year?.ToString(), "Not in your library"),
                };
            }).ToList();
            // Owned movies TMDB doesn't list (rare) still appear.
            parts.AddRange(owned.Where(m => _tmdb.Parts.All(p => p.Id != m.TmdbId))
                .Select(m => PosterItems.Movie(m, states.GetValueOrDefault(WatchKeys.Movie(m.TmdbId)))));
        }
        else parts = owned.Select(m => PosterItems.Movie(m, states.GetValueOrDefault(WatchKeys.Movie(m.TmdbId)))).ToList();

        var page = new StackPanel { Margin = new Thickness(0, 0, 0, 40) };
        page.Children.Add(DetailCommon.Header(info, backdrop, poster, name, !_entered));
        _entered = true;
        var header = new SectionHeader("Movies") { Margin = new Thickness(UiKit.Gutter, 28, UiKit.Gutter, 12) };
        page.Children.Add(header);
        var template = (DataTemplate)Application.Current.FindResource("Template.PosterCard");
        const int cols = 6;
        for (var i = 0; i < parts.Count; i += cols)
        {
            var row = new UniformGrid { Columns = cols, Rows = 1, Margin = new Thickness(UiKit.Gutter - 7, 0, UiKit.Gutter - 7, 20) };
            foreach (var p in parts.Skip(i).Take(cols))
                row.Children.Add(new ContentPresenter { Content = p, ContentTemplate = template, Margin = new Thickness(7, 0, 7, 0), VerticalAlignment = VerticalAlignment.Top });
            page.Children.Add(row);
        }
        page.Children.Add(DetailCommon.Attribution());
        if (_root.Content is ScrollViewer sv) sv.Content = page;
        else _root.Content = DetailCommon.Scroller(page);
    }
}
