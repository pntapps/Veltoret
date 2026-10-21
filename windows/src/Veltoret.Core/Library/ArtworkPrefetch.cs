using Veltoret.Core.Data;
using Veltoret.Core.Images;
using Veltoret.Core.Tmdb;

namespace Veltoret.Core.Library;

/// <summary>
/// Downloads library artwork into the image cache after a scan, so posters and backdrops show up offline even for
/// titles the user never scrolled to. Uses exactly the URLs the screens request (the cache is keyed by URL) and
/// skips anything already cached. Any screen that changes an image size must update this list.
/// </summary>
public sealed class ArtworkPrefetch
{
    private readonly CatalogDao _catalog;
    private readonly ImageCache _images;

    public ArtworkPrefetch(CatalogDao catalog, ImageCache images)
    {
        _catalog = catalog;
        _images = images;
    }

    public async Task<List<string>> Urls()
    {
        var movies = await _catalog.Movies().ConfigureAwait(false);
        var shows = await _catalog.Shows().ConfigureAwait(false);
        var urls = new List<string?>();
        foreach (var m in movies)
        {
            urls.Add(TmdbImages.Poster(m.Movie.PosterPath));              // grids, rows, search
            urls.Add(TmdbImages.Poster(m.Movie.PosterPath, "w500"));      // detail page
            urls.Add(TmdbImages.Backdrop(m.Movie.BackdropPath));          // detail page, featured
            urls.Add(TmdbImages.Backdrop(m.Movie.BackdropPath, "w780"));  // Continue Watching
        }
        foreach (var s in shows)
        {
            urls.Add(TmdbImages.Poster(s.Show.PosterPath));
            urls.Add(TmdbImages.Poster(s.Show.PosterPath, "w500"));
            urls.Add(TmdbImages.Backdrop(s.Show.BackdropPath));
            urls.Add(TmdbImages.Backdrop(s.Show.BackdropPath, "w780"));
        }
        // Episode stills for shows that can play offline.
        var offlineShows = shows.Where(s => s.DeviceEpisodes > 0).Select(s => s.Show.TmdbId).ToHashSet();
        if (offlineShows.Count > 0)
        {
            foreach (var ep in await _catalog.AllEpisodes().ConfigureAwait(false))
                if (offlineShows.Contains(ep.ShowId)) urls.Add(TmdbImages.Still(ep.StillPath));
        }
        return urls.Where(u => u != null).Select(u => u!).Distinct().ToList();
    }

    public async Task Run() => await _images.Prefetch(await Urls().ConfigureAwait(false)).ConfigureAwait(false);
}
