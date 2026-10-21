using Veltoret.App.Navigation;
using Veltoret.App.Pages.Details;
using Veltoret.App.Pages.FixMatch;
using Veltoret.App.Pages.Home;
using Veltoret.App.Pages.Library;
using Veltoret.App.Pages.Onboarding;
using Veltoret.App.Pages.Search;

namespace Veltoret.App.Services;

// [ui] module wiring: the pages this module owns.
public static partial class AppServices
{
    static partial void InitUi()
    {
        Navigator.Register<HomeRoute>(_ => new HomePage());
        Navigator.Register<MoviesRoute>(r => new LibraryPage(shows: false, r.Genre));
        Navigator.Register<ShowsRoute>(r => new LibraryPage(shows: true, r.Genre));
        Navigator.Register<SearchRoute>(r => new SearchPage(r.Query, r.Spoken));
        Navigator.Register<MovieDetailRoute>(r => new MovieDetailPage(r.MovieId));
        Navigator.Register<ShowDetailRoute>(r => new ShowDetailPage(r.ShowId, r.Season));
        Navigator.Register<CollectionRoute>(r => new CollectionPage(r.CollectionId));
        Navigator.Register<FixMatchRoute>(r => r.FileIds is { Count: > 0 }
            ? new FixMatchPage(r.FileIds, r.Kind, r.Query)
            : new UnmatchedPage());
        Navigator.Register<OnboardingRoute>(_ => new OnboardingPage());
    }
}
