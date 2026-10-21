using System.Windows.Input;
using CommunityToolkit.Mvvm.Input;
using Veltoret.App.Navigation;
using Veltoret.App.Services;

namespace Veltoret.App.Controls;

/// <summary>What cards do when clicked (bound from the card templates in Controls/Cards.xaml).</summary>
public static class CardActions
{
    /// <summary>Poster click route: collection → CollectionRoute; show → ShowDetailRoute; else MovieDetailRoute.</summary>
    public static readonly ICommand OpenPoster = new RelayCommand<PosterItem>(item =>
    {
        if (item == null || !item.Clickable) return;
        Route route = item.IsCollection ? new CollectionRoute(item.Id) : item.IsShow ? new ShowDetailRoute(item.Id) : new MovieDetailRoute(item.Id);
        Safe(() => AppServices.Navigator.Navigate(route));
    });

    /// <summary>Plays a wide card's file (Continue Watching / Next Up).</summary>
    public static readonly ICommand Play = new AsyncRelayCommand<PlayItem>(async item =>
    {
        if (item == null) return;
        try
        {
            var file = await AppServices.MediaFileDao.File(item.FileId);
            if (file != null) await AppServices.Playback.PlayFile(file);
            else if (item.MovieId is { } m) await AppServices.Playback.PlayMovie(m);
            else if (item is { ShowId: { } s, Season: { } se, Episode: { } e }) await AppServices.Playback.PlayEpisode(s, se, e);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }, AsyncRelayCommandOptions.AllowConcurrentExecutions);

    /// <summary>Opens the title behind a wide card (right-click "Details").</summary>
    public static readonly ICommand OpenPlayItem = new RelayCommand<PlayItem>(item =>
    {
        if (item == null) return;
        if (item.MovieId is { } m) Safe(() => AppServices.Navigator.Navigate(new MovieDetailRoute(m)));
        else if (item.ShowId is { } s) Safe(() => AppServices.Navigator.Navigate(new ShowDetailRoute(s, item.Season)));
    });

    private static void Safe(Action a)
    {
        try { a(); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }
}
