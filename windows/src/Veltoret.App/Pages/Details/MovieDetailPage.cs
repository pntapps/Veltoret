using System.Windows;
using System.Windows.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Details;

public sealed partial class MovieDetailViewModel : ObservableObject
{
    public MovieDetailViewModel(int id) => Id = id;

    public int Id { get; }
    [ObservableProperty] private MovieEntity? _movie;
    [ObservableProperty] private IReadOnlyList<MediaFileEntity> _files = Array.Empty<MediaFileEntity>();
    [ObservableProperty] private WatchStateEntity? _state;
    [ObservableProperty] private IReadOnlyList<CreditEntity> _credits = Array.Empty<CreditEntity>();
    [ObservableProperty] private IReadOnlyList<PosterItem> _related = Array.Empty<PosterItem>();
    [ObservableProperty] private bool _saved;
    [ObservableProperty] private IReadOnlyList<ReminderEntity> _reminders = Array.Empty<ReminderEntity>();
    [ObservableProperty] private string? _trailerKey;
    public bool Loaded { get; private set; }

    private bool _fetched;

    public bool Resumable => State is { Watched: false, PositionMs: > 30_000 };
    public bool Watched => State?.Watched == true;
    public MediaFileEntity? BestFile => Files.FirstOrDefault();

    public async Task Load()
    {
        var lib = AppServices.Library;
        Movie = await lib.Movie(Id);
        Files = await lib.MovieFiles(Id);
        State = await AppServices.Watch.Get(WatchKeys.Movie(Id));
        Credits = await lib.Credits("movie", Id);
        var states = (await AppServices.Watch.All()).ToDictionary(s => s.Key);
        Related = (await lib.RelatedMovies(Id)).Select(r => PosterItems.Movie(r.Movie, states.GetValueOrDefault(WatchKeys.Movie(r.Movie.TmdbId)))).ToList();
        Saved = await DetailCommon.IsSaved("movie", Id);
        Reminders = await DetailCommon.Reminders("movie", Id);
        Loaded = true;
    }

    /// <summary>On open (online): recommendations and the trailer key.</summary>
    public async Task FetchOnline()
    {
        if (_fetched || !DetailCommon.Online) return;
        _fetched = true;
        try { await AppServices.Tmdb.EnsureRecommendations("movie", Id); } catch (Exception) { }
        try { TrailerKey = await AppServices.Tmdb.Trailer("movie", Id); } catch (Exception) { }
    }
}

/// <summary>Movie detail (Android MovieDetailScreen).</summary>
public sealed class MovieDetailPage : LivePage
{
    private readonly MovieDetailViewModel _vm;
    private readonly ContentControl _root = new() { Focusable = false };
    private bool _entered;

    public MovieDetailPage(int movieId)
    {
        _vm = new MovieDetailViewModel(movieId);
        _root.Content = new LoadingBox();
        Content = _root;
    }

    protected override IReadOnlyCollection<string> Tables { get; } =
        new[] { "movies", "media_files", "watch_state", "credits", "recommendations", "watchlist", "reminders" };

    protected override async Task Refresh()
    {
        await _vm.Load();
        if (_vm.Movie == null)
        {
            // Re-matched or removed: close the page.
            if (AppServices.Navigator.Current?.Page == this) AppServices.Navigator.GoBack();
            return;
        }
        Render();
        if (!_vm.Loaded) return;
        var hadTrailer = _vm.TrailerKey;
        await _vm.FetchOnline();
        if (_vm.TrailerKey != hadTrailer) Render();
    }

    private void Render()
    {
        var m = _vm.Movie!;
        var info = new StackPanel();
        DetailCommon.AddTitle(info, m.Title, m.Tagline);
        DetailCommon.AddMeta(info, m.Rating, m.Year?.ToString(), m.Certification, Formats.Runtime(m.RuntimeMin));
        var best = _vm.BestFile;
        DetailCommon.AddTags(info, best != null ? FilenameParser.QualityTags(best.Name, best.Height) : Enumerable.Empty<string>(), m.GenreList);

        var actions = new StackPanel { Margin = new Thickness(0, 20, 0, 0) };
        if (_vm.Resumable)
        {
            var p = new ProgressBar { Value = _vm.State!.Progress, Margin = new Thickness(0, 0, 0, 6) };
            actions.Children.Add(p);
            var left = UiKit.Text(Formats.Remaining(_vm.State.PositionMs, _vm.State.DurationMs), "Text.BodySmall", "TextMuted");
            left.Margin = new Thickness(0, 0, 0, 12);
            actions.Children.Add(left);
        }
        var id = m.TmdbId;
        var watched = _vm.Watched;
        var menu = new List<DetailMenuItem>
        {
            watched
                ? new DetailMenuItem("Mark unwatched", "RemoveDone", () => _ = SetWatched(false))
                : new DetailMenuItem("Mark watched", "Check", () => _ = SetWatched(true)),
            new DetailMenuItem("Remind me…", "Notifications", () => _ = DetailCommon.RemindMe(this, "movie", id, null, null, m.Title, null)),
            new DetailMenuItem("Fix match", "Edit", () => AppServices.Navigator.Navigate(new FixMatchRoute(_vm.Files.Select(f => f.DriveId).ToList(), "MOVIE", m.Title))),
        };
        actions.Children.Add(new DetailActionRow
        {
            PlayLabel = _vm.Resumable ? "Resume" : watched ? "Watch again" : "Play",
            PlayIcon = watched && !_vm.Resumable ? "Replay" : "Play",
            PlayEnabled = best != null && DetailCommon.CanPlayNow(best),
            OnPlay = () => AppServices.Playback.PlayMovie(id, startOver: watched && !_vm.Resumable),
            TrailerKey = _vm.TrailerKey,
            LabelledTrailer = false,
            Saved = _vm.Saved,
            OnToggleSaved = () => DetailCommon.ToggleSaved("movie", id, _vm.Saved),
            Menu = menu,
        });
        info.Children.Add(actions);
        DetailCommon.AddReminders(info, _vm.Reminders);
        DetailCommon.AddOverview(info, m.Overview);
        DetailCommon.AddCredit(info, "Director", m.Director);
        if (m.CollectionId is { } cid)
            DetailCommon.AddCredit(info, "Collection", m.CollectionName, () => AppServices.Navigator.Navigate(new CollectionRoute(cid)));
        DetailCommon.AddCredit(info, "Released", Formats.LongDate(m.ReleaseDate));

        var page = new StackPanel { Margin = new Thickness(0, 0, 0, 40) };
        page.Children.Add(DetailCommon.Header(info, TmdbImages.Backdrop(m.BackdropPath), TmdbImages.Poster(m.PosterPath, "w500"), m.Title, !_entered));
        _entered = true;
        if (DetailCommon.Cast(_vm.Credits) is { } cast) page.Children.Add(cast);
        if (DetailCommon.Versions(_vm.Files, f => AppServices.Playback.PlayFile(f)) is { } versions) page.Children.Add(versions);
        if (DetailCommon.MoreLikeThis(_vm.Related) is { } more) page.Children.Add(more);
        page.Children.Add(DetailCommon.Attribution());

        if (_root.Content is ScrollViewer sv) sv.Content = page;
        else _root.Content = DetailCommon.Scroller(page);
    }

    private async Task SetWatched(bool watched)
    {
        try { await AppServices.Watch.SetMovieWatched(_vm.Id, watched); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }
}
