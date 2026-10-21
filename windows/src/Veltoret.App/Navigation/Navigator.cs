using System.Windows;

namespace Veltoret.App.Navigation;

// Routes (Android: ui/navigation/Navigation.kt). One back stack; top-level destinations reset it.
public abstract record Route;
public sealed record HomeRoute : Route;
public sealed record MoviesRoute(string? Genre = null) : Route;
public sealed record ShowsRoute(string? Genre = null) : Route;
public sealed record SearchRoute(string? Query = null, bool Spoken = false) : Route;
public sealed record FilesRoute(string? Account = null, string? FolderId = null) : Route;
public sealed record SettingsRoute : Route;
public sealed record MovieDetailRoute(int MovieId) : Route;
public sealed record ShowDetailRoute(int ShowId, int? Season = null) : Route;
public sealed record CollectionRoute(int CollectionId) : Route;
/// <summary>
/// No file ids: the "Needs a match" list. With file ids: the Fix match screen for them; <paramref name="Kind"/> is
/// "MOVIE" or "EPISODE" (default: the files' kind) and <paramref name="Query"/> the initial search (default: parsed title).
/// </summary>
public sealed record FixMatchRoute(IReadOnlyList<string>? FileIds = null, string? Kind = null, string? Query = null) : Route;
public sealed record ArchivesRoute : Route;
public sealed record OnboardingRoute : Route;

/// <summary>
/// Shows pages in the main window. Modules register a factory per route type in their Init hook
/// (<c>Navigator.Register&lt;MovieDetailRoute&gt;(r =&gt; new MovieDetailPage(r.MovieId))</c>); the shell hosts
/// <see cref="Current"/>.
/// </summary>
public sealed class Navigator
{
    private readonly Dictionary<Type, Func<Route, FrameworkElement>> _factories = new();
    private readonly Stack<(Route Route, FrameworkElement Page)> _back = new();

    public (Route Route, FrameworkElement Page)? Current { get; private set; }

    /// <summary>Raised when the shown page changes (the shell swaps its content and updates the rail).</summary>
    public event Action? Navigated;

    public bool CanGoBack => _back.Count > 0;

    public void Register<T>(Func<T, FrameworkElement> factory) where T : Route =>
        _factories[typeof(T)] = r => factory((T)r);

    public static bool IsTopLevel(Route r) =>
        r is HomeRoute or MoviesRoute or ShowsRoute or SearchRoute or FilesRoute or SettingsRoute;

    public void Navigate(Route route)
    {
        if (!_factories.TryGetValue(route.GetType(), out var factory))
            throw new InvalidOperationException($"No page registered for {route.GetType().Name}");
        if (IsTopLevel(route)) _back.Clear();
        else if (Current is { } c) _back.Push(c);
        LastNavigationWasBack = false;
        Current = (route, factory(route));
        Navigated?.Invoke();
    }

    public bool GoBack()
    {
        if (_back.Count == 0) return false;
        LastNavigationWasBack = true;
        Current = _back.Pop();
        Navigated?.Invoke();
        return true;
    }

    // ---- Added by the UI module (additive) ----

    /// <summary>True when the last change came from <see cref="GoBack"/> (the shell plays the pop transition).</summary>
    public bool LastNavigationWasBack { get; private set; }

    public bool IsRegistered(Type routeType) => _factories.ContainsKey(routeType);

    /// <summary>Pushes <paramref name="route"/> even when it is top-level (Search opened from a page keeps Back). No-op when it is already shown.</summary>
    public void Push(Route route)
    {
        if (Current?.Route == route) return;
        if (!_factories.TryGetValue(route.GetType(), out var factory))
            throw new InvalidOperationException($"No page registered for {route.GetType().Name}");
        if (Current is { } c) _back.Push(c);
        LastNavigationWasBack = false;
        Current = (route, factory(route));
        Navigated?.Invoke();
    }

    /// <summary>
    /// Nav rail tab (Android selectTab): no-op when already shown; otherwise clears the stack to Home and pushes
    /// <paramref name="route"/>, so Back from any tab exits through Home.
    /// </summary>
    public void SelectTab(Route route)
    {
        if (Current?.Route == route) return;
        if (route is HomeRoute || !_factories.ContainsKey(typeof(HomeRoute)))
        {
            Navigate(route);
            return;
        }
        if (!_factories.TryGetValue(route.GetType(), out var factory))
            throw new InvalidOperationException($"No page registered for {route.GetType().Name}");
        // Reuse a Home page already in the history, so its scroll position and state survive.
        var history = _back.ToList();
        if (Current is { } cur) history.Add(cur);
        var found = history.FirstOrDefault(x => x.Route is HomeRoute);
        var home = found.Page != null ? found : (new HomeRoute(), _factories[typeof(HomeRoute)](new HomeRoute()));
        _back.Clear();
        _back.Push(home);
        LastNavigationWasBack = false;
        Current = (route, factory(route));
        Navigated?.Invoke();
    }

    /// <summary>The last top-level route in the history (drives the rail selection), else Home.</summary>
    public Route CurrentTopLevel
    {
        get
        {
            if (Current is { } c && IsTopLevel(c.Route) && c.Route is not SearchRoute) return c.Route;
            foreach (var (r, _) in _back) if (IsTopLevel(r) && r is not SearchRoute) return r;
            return Current?.Route is SearchRoute && _back.Count == 0 ? Current.Value.Route : new HomeRoute();
        }
    }
}
