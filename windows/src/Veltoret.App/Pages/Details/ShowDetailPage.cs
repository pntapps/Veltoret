using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Details;

using Accounts = Veltoret.Core.Storage.Accounts;

public sealed record EpisodeUi
{
    public int Season { get; init; }
    public int Number { get; init; }
    public string Name { get; init; } = "";
    public string? StillUrl { get; init; }
    public string? Runtime { get; init; }
    public string? AirDate { get; init; }
    public string? AirDateRaw { get; init; }
    public string Overview { get; init; } = "";
    public MediaFileEntity? File { get; init; }
    public bool Watched { get; init; }
    public double? Progress { get; init; }
    public bool NeedsInternet { get; init; }
    public bool Upcoming { get; init; }
    public bool Available => File != null && !NeedsInternet;
}

public sealed partial class ShowDetailViewModel : ObservableObject
{
    public ShowDetailViewModel(int id) => Id = id;

    public int Id { get; }
    public ShowEntity? Show { get; private set; }
    public IReadOnlyList<MediaFileEntity> Files { get; private set; } = Array.Empty<MediaFileEntity>();
    public IReadOnlyList<WatchStateEntity> States { get; private set; } = Array.Empty<WatchStateEntity>();
    public IReadOnlyList<EpisodeEntity> Episodes { get; private set; } = Array.Empty<EpisodeEntity>();
    public IReadOnlyList<CreditEntity> Credits { get; private set; } = Array.Empty<CreditEntity>();
    public IReadOnlyList<PosterItem> Related { get; private set; } = Array.Empty<PosterItem>();
    public bool Saved { get; private set; }
    public IReadOnlyList<ReminderEntity> Reminders { get; private set; } = Array.Empty<ReminderEntity>();
    public EpisodeTarget? Target { get; private set; }
    public IReadOnlyList<int> Seasons { get; private set; } = Array.Empty<int>();
    [ObservableProperty] private string? _trailerKey;
    private bool _fetched;

    public async Task Load()
    {
        var lib = AppServices.Library;
        Show = await lib.Show(Id);
        if (Show == null) return;
        Files = await lib.ShowFiles(Id);
        States = await AppServices.Watch.ForShow(Id);
        Episodes = await lib.Episodes(Id);
        Credits = await lib.Credits("tv", Id);
        Related = (await lib.RelatedShows(Id)).Select(r => PosterItems.Show(r.Show, r.AvailableEpisodes)).ToList();
        Saved = await DetailCommon.IsSaved("tv", Id);
        Reminders = await DetailCommon.Reminders("tv", Id);
        Target = PlayTargets.NextEpisode(Files.Where(DetailCommon.CanPlayNow).ToList(), States);
        Seasons = Files.Where(f => f.Season != null).Select(f => f.Season!.Value).Distinct()
            .OrderBy(s => s == 0 ? int.MaxValue : s).ToList();
    }

    public async Task FetchOnline()
    {
        if (_fetched || !DetailCommon.Online) return;
        _fetched = true;
        try { await AppServices.Tmdb.EnsureRecommendations("tv", Id); } catch (Exception) { }
        try { TrailerKey = await AppServices.Tmdb.Trailer("tv", Id); } catch (Exception) { }
    }

    private WatchStateEntity? StateOf(int season, int episode) =>
        States.FirstOrDefault(s => s.Season == season && s.Episode == episode);

    public IReadOnlyList<EpisodeUi> EpisodesOf(int season)
    {
        var today = DateTime.Today;
        var fileByEp = Files.Where(f => f.Season == season && f.Episode != null)
            .GroupBy(f => f.Episode!.Value)
            .ToDictionary(g => g.Key, g => g.OrderByDescending(f => Accounts.IsLocal(f.AccountEmail)).ThenByDescending(f => f.Height).First());
        var tmdb = Episodes.Where(e => e.SeasonNumber == season).ToDictionary(e => e.EpisodeNumber);
        var numbers = fileByEp.Keys.Union(tmdb.Keys).OrderBy(n => n);
        return numbers.Select(n =>
        {
            tmdb.TryGetValue(n, out var e);
            fileByEp.TryGetValue(n, out var f);
            var st = StateOf(season, n);
            var date = Formats.ParseDate(e?.AirDate);
            return new EpisodeUi
            {
                Season = season,
                Number = n,
                Name = string.IsNullOrWhiteSpace(e?.Name) ? $"Episode {n}" : e!.Name,
                StillUrl = TmdbImages.Still(e?.StillPath),
                Runtime = e?.RuntimeMin is > 0 ? Formats.Runtime(e.RuntimeMin) : f != null ? Formats.RuntimeMs(f.DurationMs) : null,
                AirDate = Formats.LongDate(e?.AirDate),
                AirDateRaw = e?.AirDate,
                Overview = e?.Overview ?? "",
                File = f,
                Watched = st?.Watched == true,
                Progress = st is { Watched: false, PositionMs: > 30_000 } ? st.Progress : null,
                NeedsInternet = f != null && !DetailCommon.CanPlayNow(f),
                Upcoming = date != null && date.Value.Date >= today,
            };
        }).ToList();
    }

    /// <summary>All available episodes of the season are watched.</summary>
    public bool SeasonDone(int season)
    {
        var eps = Files.Where(f => f.Season == season && f.Episode != null).Select(f => f.Episode!.Value).Distinct().ToList();
        return eps.Count > 0 && eps.All(e => StateOf(season, e)?.Watched == true);
    }
}

/// <summary>Show detail (Android ShowDetailScreen): header, seasons, episodes (2 per row), cast, more like this.</summary>
public sealed class ShowDetailPage : LivePage
{
    private readonly ShowDetailViewModel _vm;
    private readonly ContentControl _root = new() { Focusable = false };
    private int? _season;
    private bool _entered;

    public ShowDetailPage(int showId, int? season = null)
    {
        _vm = new ShowDetailViewModel(showId);
        _season = season;
        _root.Content = new LoadingBox();
        Content = _root;
    }

    protected override IReadOnlyCollection<string> Tables { get; } =
        new[] { "shows", "media_files", "watch_state", "credits", "recommendations", "watchlist", "reminders", "episodes", "seasons" };

    protected override async Task Refresh()
    {
        await _vm.Load();
        if (_vm.Show == null)
        {
            if (AppServices.Navigator.Current?.Page == this) AppServices.Navigator.GoBack();
            return;
        }
        Render();
        var had = _vm.TrailerKey;
        await _vm.FetchOnline();
        if (_vm.TrailerKey != had) Render();
    }

    private int SelectedSeason
    {
        get
        {
            if (_season is { } s && _vm.Seasons.Contains(s)) return s;
            if (_vm.Target?.File.Season is { } t && _vm.Seasons.Contains(t)) return t;
            return _vm.Seasons.FirstOrDefault();
        }
    }

    private void Render()
    {
        var show = _vm.Show!;
        var id = show.TmdbId;
        var info = new StackPanel();
        DetailCommon.AddTitle(info, show.Name, show.Tagline);
        DetailCommon.AddMeta(info, show.Rating, show.Year?.ToString(), show.Certification, show.Network,
            show.SeasonCount > 0 ? Formats.Seasons(show.SeasonCount) : null);
        DetailCommon.AddTags(info, show.Status == "Returning Series" ? new[] { "Returning" } : Array.Empty<string>(), show.GenreList);

        var actions = new StackPanel { Margin = new Thickness(0, 20, 0, 0) };
        var target = _vm.Target;
        if (target is { Resuming: true, State: { } st })
            actions.Children.Add(new ProgressBar { Value = st.Progress, Margin = new Thickness(0, 0, 0, 12) });
        var code = target != null ? Formats.EpisodeCode(target.File.Season, target.File.Episode) : "";
        var season = SelectedSeason;
        var menu = new List<DetailMenuItem>
        {
            new("Remind me…", "Notifications", () => _ = DetailCommon.RemindMe(this, "tv", id, null, null, show.Name, null)),
            new("Mark season watched", "DoneAll", () => _ = MarkSeason(season, true)),
            new("Mark season unwatched", "RemoveDone", () => _ = MarkSeason(season, false)),
            new("Fix match", "Edit", () => AppServices.Navigator.Navigate(new FixMatchRoute(_vm.Files.Select(f => f.DriveId).ToList(), "EPISODE", show.Name))),
        };
        actions.Children.Add(new DetailActionRow
        {
            PlayLabel = target == null ? "All caught up" : target.Resuming ? $"Resume {code}" : $"Play {code}",
            PlayEnabled = target != null,
            OnPlay = () => target == null ? Task.CompletedTask
                : AppServices.Playback.PlayEpisode(id, target.File.Season!.Value, target.File.Episode!.Value),
            TrailerKey = _vm.TrailerKey,
            LabelledTrailer = true,
            Saved = _vm.Saved,
            OnToggleSaved = () => DetailCommon.ToggleSaved("tv", id, _vm.Saved),
            Menu = menu,
        });
        info.Children.Add(actions);
        DetailCommon.AddReminders(info, _vm.Reminders);
        DetailCommon.AddOverview(info, show.Overview);
        if (Formats.ParseDate(show.NextEpisodeAirDate) is { } next && next.Date >= DateTime.Today && show.NextEpisodeSeason != null)
        {
            var name = string.IsNullOrWhiteSpace(show.NextEpisodeName) ? null : $"“{show.NextEpisodeName}”";
            DetailCommon.AddCredit(info, "Next episode",
                Formats.Join(Formats.EpisodeCode(show.NextEpisodeSeason, show.NextEpisodeNumber), name, Formats.AirLabel(next)));
        }
        DetailCommon.AddCredit(info, "Created by", show.Creator);
        DetailCommon.AddCredit(info, "First aired", Formats.LongDate(show.FirstAirDate));

        var page = new StackPanel { Margin = new Thickness(0, 0, 0, 40) };
        page.Children.Add(DetailCommon.Header(info, TmdbImages.Backdrop(show.BackdropPath), TmdbImages.Poster(show.PosterPath, "w500"), show.Name, !_entered));
        _entered = true;
        if (_vm.Seasons.Count > 0)
        {
            page.Children.Add(SeasonChips(season));
            page.Children.Add(EpisodeList(show, season));
        }
        if (DetailCommon.Cast(_vm.Credits) is { } cast) page.Children.Add(cast);
        if (DetailCommon.MoreLikeThis(_vm.Related) is { } more) page.Children.Add(more);
        page.Children.Add(DetailCommon.Attribution());
        if (_root.Content is ScrollViewer sv) sv.Content = page;
        else _root.Content = DetailCommon.Scroller(page);
    }

    private FrameworkElement SeasonChips(int selected)
    {
        var wrap = new WrapPanel { Margin = new Thickness(UiKit.Gutter, 40, UiKit.Gutter, 8) };
        foreach (var s in _vm.Seasons)
        {
            var label = (s == 0 ? "Specials" : $"Season {s}") + (_vm.SeasonDone(s) ? "  ✓" : "");
            var chip = new ToggleButton { Content = label, Style = UiKit.Style("Chip"), IsChecked = s == selected, Margin = new Thickness(0, 0, 8, 8) };
            var season = s;
            chip.Click += (_, _) => { _season = season; Render(); };
            wrap.Children.Add(chip);
        }
        return wrap;
    }

    private FrameworkElement EpisodeList(ShowEntity show, int season)
    {
        var grid = new UniformGrid { Columns = 2, Margin = new Thickness(UiKit.Gutter - 20, 8, UiKit.Gutter - 20, 0) };
        foreach (var e in _vm.EpisodesOf(season)) grid.Children.Add(EpisodeRow(show, e));
        return grid;
    }

    private FrameworkElement EpisodeRow(ShowEntity show, EpisodeUi e)
    {
        var dim = e.Available ? 1.0 : 0.45;
        var dock = new DockPanel();

        // Thumbnail (200 wide, 16:9).
        var thumb = new Grid { Width = 200, Height = 112.5, Opacity = dim, VerticalAlignment = VerticalAlignment.Top };
        thumb.Children.Add(new AsyncImage
        {
            Url = e.StillUrl, FallbackText = $"E{e.Number}", DecodeWidth = 300,
            CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), BorderBrush = UiKit.Brush("Outline"),
        });
        if (e.Available)
        {
            var disc = new Grid { Width = 34, Height = 34, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            disc.Children.Add(new Ellipse { Fill = UiKit.Brush("ImageDim") });
            var play = UiKit.Icon("Play", 20, "Text");
            play.HorizontalAlignment = HorizontalAlignment.Center;
            disc.Children.Add(play);
            thumb.Children.Add(disc);
        }
        if (e.Progress is { } p)
            thumb.Children.Add(new ProgressBar { Value = p, Margin = new Thickness(6), VerticalAlignment = VerticalAlignment.Bottom, Background = UiKit.Brush("ImageDim") });
        DockPanel.SetDock(thumb, Dock.Left);
        dock.Children.Add(thumb);

        // Trailing toggle / bell.
        FrameworkElement? trailing = null;
        if (e.Available)
        {
            var b = UiKit.IconButton(e.Watched ? "CheckCircle" : "RadioUnchecked", e.Watched ? "Mark unwatched" : "Mark watched",
                () => _ = SetWatched(e, !e.Watched), 36, tint: e.Watched ? "Amber" : "TextFaint");
            b.Style = UiKit.Style("Button.IconFlat");
            ButtonAssist.SetIconSize(b, 24);
            b.Foreground = UiKit.Brush(e.Watched ? "Amber" : "TextFaint");
            trailing = b;
        }
        else if (e.Upcoming)
        {
            var b = UiKit.IconButton("Notifications", "Remind me", () => _ = RemindEpisode(show, e), 36);
            b.Style = UiKit.Style("Button.IconFlat");
            ButtonAssist.SetIconSize(b, 24);
            b.Foreground = UiKit.Brush("Amber");
            trailing = b;
        }
        if (trailing != null)
        {
            trailing.Margin = new Thickness(8, 0, 0, 0);
            trailing.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(trailing, Dock.Right);
            dock.Children.Add(trailing);
        }

        var col = new StackPanel { Margin = new Thickness(14, 0, 0, 0), Opacity = dim };
        col.Children.Add(UiKit.Text($"{e.Number}. {e.Name}", "Text.TitleSmall", maxLines: 2));
        var status = e.NeedsInternet ? (Accounts.IsSmb(e.File!.AccountEmail) ? "Network server · needs Wi-Fi" : "On Google Drive · needs internet")
            : e.File == null ? "Not in library" : null;
        var meta = UiKit.Text(Formats.JoinTight(e.Runtime, e.AirDate, status), "Text.BodySmall", "TextMuted", maxLines: 1);
        meta.Margin = new Thickness(0, 3, 0, 0);
        col.Children.Add(meta);
        if (!string.IsNullOrWhiteSpace(e.Overview))
        {
            var o = UiKit.Text(e.Overview, "Text.BodySmall", "TextMuted", maxLines: 3);
            o.Margin = new Thickness(0, 3, 0, 0);
            col.Children.Add(o);
        }
        dock.Children.Add(col);

        var row = new Button { Style = UiKit.Style("Button.Row"), Content = dock, Padding = new Thickness(20, 10, 20, 10) };
        row.Click += (_, _) =>
        {
            if (e.Available) _ = Play(e);
            else ShowEpisodeMenu(row, show, e);
        };
        row.MouseRightButtonUp += (_, args) => { args.Handled = true; ShowEpisodeMenu(row, show, e); };
        return row;
    }

    private void ShowEpisodeMenu(FrameworkElement anchor, ShowEntity show, EpisodeUi e)
    {
        var menu = new ContextMenu();
        menu.Items.Add(UiKit.MenuItem("Remind me…", "Notifications", () => _ = RemindEpisode(show, e)));
        if (e.Available)
            menu.Items.Add(e.Watched
                ? UiKit.MenuItem("Mark unwatched", "RemoveDone", () => _ = SetWatched(e, false))
                : UiKit.MenuItem("Mark watched", "Check", () => _ = SetWatched(e, true)));
        UiKit.ShowMenu(anchor, menu);
    }

    private Task RemindEpisode(ShowEntity show, EpisodeUi e) =>
        DetailCommon.RemindMe(this, "tv", show.TmdbId, e.Season, e.Number,
            $"{show.Name} · {Formats.EpisodeCode(e.Season, e.Number)}", e.Upcoming ? e.AirDateRaw : null);

    private async Task Play(EpisodeUi e)
    {
        try
        {
            if (e.File != null && e.Watched) await AppServices.Playback.PlayEpisode(_vm.Id, e.Season, e.Number, startOver: true);
            else await AppServices.Playback.PlayEpisode(_vm.Id, e.Season, e.Number);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    private async Task SetWatched(EpisodeUi e, bool watched)
    {
        try { await AppServices.Watch.SetEpisodeWatched(_vm.Id, e.Season, e.Number, watched); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    /// <summary>Season actions apply to the episodes with files in the selected season.</summary>
    private async Task MarkSeason(int season, bool watched)
    {
        var eps = _vm.Files.Where(f => f.Season == season && f.Episode != null)
            .Select(f => (season, f.Episode!.Value)).Distinct().OrderBy(x => x.Value).ToList();
        if (eps.Count == 0) return;
        try { await AppServices.Watch.SetEpisodesWatched(_vm.Id, eps, watched); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }
}
