using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Toolkit.Uwp.Notifications;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core;
using Veltoret.Core.Data;
using Veltoret.Core.Plans;
using Veltoret.Core.Tmdb;
using Windows.UI.Notifications;
using P = Veltoret.Core.Plans.Plans;

namespace Veltoret.App.Plans;

/// <summary>
/// Windows toasts for reminders ("Time for …", Play / Snooze 1 hour) and new episodes (Android:
/// PlanNotifications), and what happens when one is clicked. Unpackaged toasts take only local image files, so
/// artwork comes from the image cache (8 s limit; skipped on failure) and the poster is cropped to its top square.
/// </summary>
public sealed class ToastNotifier : IPlanNotifier
{
    private const string RemindersGroup = "reminders";
    private const string EpisodesGroup = "new-episodes";
    private static readonly string CacheDir = Path.Combine(AppPaths.Root, "toast-cache");

    public bool CanPost => CanPostNow();

    /// <summary>False when the user turned off Veltoret's notifications in Windows Settings.</summary>
    public static bool CanPostNow()
    {
        try { return ToastNotificationManagerCompat.CreateToastNotifier().Setting == NotificationSetting.Enabled; }
        catch (Exception) { return true; }
    }

    public async Task ShowReminder(ReminderEntity r)
    {
        var catalog = AppServices.CatalogDao;
        var movie = r.MediaType == P.Movie ? await catalog.Movie(r.MediaId) : null;
        var show = r.MediaType == P.Tv ? await catalog.Show(r.MediaId) : null;
        int? season = r.Season, episode = r.Episode;
        bool playable;
        string title, text;
        string? picture = null, poster = null;

        if (movie != null)
        {
            title = $"Time for {movie.Title}";
            text = string.Join(" · ", new[]
            {
                movie.Year?.ToString(), movie.GenreList.FirstOrDefault(g => !string.IsNullOrWhiteSpace(g)), PlanFormat.Runtime(movie.RuntimeMin),
            }.Where(s => s != null));
            picture = TmdbImages.Backdrop(movie.BackdropPath, "w780");
            poster = TmdbImages.Poster(movie.PosterPath);
            playable = await Safe(() => AppServices.Resolver.MovieFile(movie.TmdbId)) != null;
        }
        else if (show != null && season != null && episode != null)
        {
            var ep = await catalog.Episode(show.TmdbId, season.Value, episode.Value);
            title = $"Time for {show.Name}";
            text = string.Join("  ·  ", new[] { PlanFormat.EpisodeCode(season, episode), ep?.Name }.Where(s => !string.IsNullOrWhiteSpace(s)));
            picture = TmdbImages.Still(ep?.StillPath, "w780") ?? TmdbImages.Backdrop(show.BackdropPath, "w780");
            poster = TmdbImages.Poster(show.PosterPath);
            playable = await Safe(() => AppServices.Resolver.EpisodeFile(show.TmdbId, season.Value, episode.Value)) != null;
        }
        else if (show != null)
        {
            // A show reminder plays what "Play" on its page would: the next episode.
            var target = await Safe(() => AppServices.Resolver.ShowPlayTarget(show.TmdbId));
            season = target?.File.Season;
            episode = target?.File.Episode;
            var ep = season != null && episode != null ? await catalog.Episode(show.TmdbId, season.Value, episode.Value) : null;
            title = $"Time for {show.Name}";
            text = target == null
                ? "Your reminder"
                : string.Join("  ·  ", new[]
                {
                    target.Resuming ? "Continue" : "Up next", PlanFormat.EpisodeCode(season, episode), ep?.Name,
                }.Where(s => !string.IsNullOrWhiteSpace(s)));
            picture = TmdbImages.Still(ep?.StillPath, "w780") ?? TmdbImages.Backdrop(show.BackdropPath, "w780");
            poster = TmdbImages.Poster(show.PosterPath);
            playable = target != null;
        }
        else
        {
            // The title left the library since the reminder was set.
            title = $"Time for {r.Title}";
            text = "Your reminder";
            playable = false;
        }

        var tag = $"r{r.Id}";
        var builder = new ToastContentBuilder()
            .AddArgument("action", "open").AddArgument("type", r.MediaType).AddArgument("id", r.MediaId)
            .AddArgument("season", r.Season?.ToString() ?? "").AddArgument("episode", r.Episode?.ToString() ?? "")
            .AddArgument("tag", tag).AddArgument("group", RemindersGroup)
            .AddText(title)
            .AddText(text)
            .AddAttributionText("Reminder");
        await AddArtwork(builder, picture, poster);
        if (playable && (movie != null || show != null))
        {
            builder.AddButton(new ToastButton().SetContent("Play")
                .AddArgument("action", "play").AddArgument("type", r.MediaType).AddArgument("id", r.MediaId)
                .AddArgument("season", season?.ToString() ?? "").AddArgument("episode", episode?.ToString() ?? "")
                .AddArgument("tag", tag).AddArgument("group", RemindersGroup));
        }
        builder.AddButton(new ToastButton().SetContent("Snooze 1 hour")
            .AddArgument("action", "snooze").AddArgument("type", r.MediaType).AddArgument("id", r.MediaId)
            .AddArgument("season", r.Season?.ToString() ?? "").AddArgument("episode", r.Episode?.ToString() ?? "")
            .AddArgument("title", r.Title)
            .AddArgument("tag", tag).AddArgument("group", RemindersGroup)
            .SetBackgroundActivation());
        builder.SetToastScenario(ToastScenario.Reminder);
        builder.Show(t => { t.Tag = tag; t.Group = RemindersGroup; });
    }

    public async Task ShowNewEpisode(ShowEntity show)
    {
        if (!CanPostNow()) return;
        var code = PlanFormat.EpisodeCode(show.NextEpisodeSeason, show.NextEpisodeNumber);
        var text = string.Join("  ·  ", new[]
        {
            code.Length == 0 ? null : code, show.NextEpisodeName == null ? null : $"“{show.NextEpisodeName}”", "out today",
        }.Where(s => s != null));
        var builder = new ToastContentBuilder()
            .AddArgument("action", "open").AddArgument("type", P.Tv).AddArgument("id", show.TmdbId)
            .AddArgument("tag", $"e{show.TmdbId}").AddArgument("group", EpisodesGroup)
            .AddText($"New episode of {show.Name}")
            .AddText(text)
            .AddAttributionText(show.Network ?? "New episode");
        await AddArtwork(builder, TmdbImages.Backdrop(show.BackdropPath, "w780"), TmdbImages.Poster(show.PosterPath));
        builder.Show(t => { t.Tag = $"e{show.TmdbId}"; t.Group = EpisodesGroup; });
    }

    private static async Task<T?> Safe<T>(Func<Task<T?>> f) where T : class
    {
        try { return await f(); }
        catch (Exception) { return null; }
    }

    private static async Task AddArtwork(ToastContentBuilder builder, string? pictureUrl, string? posterUrl)
    {
        var picture = await Download(pictureUrl);
        if (picture != null) builder.AddHeroImage(new Uri(picture));
        var poster = await Download(posterUrl);
        if (poster != null && SquareTop(poster) is { } square) builder.AddAppLogoOverride(new Uri(square));
    }

    private static async Task<string?> Download(string? url)
    {
        if (url == null) return null;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var file = await AppServices.Images.GetFile(url, cts.Token);
            return file != null && File.Exists(file) ? Path.GetFullPath(file) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Posters are 2:3; the logo is square, so keep the top square (where titles and faces usually are).</summary>
    private static string? SquareTop(string file)
    {
        try
        {
            Directory.CreateDirectory(CacheDir);
            var name = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(file)))[..24] + "-sq.png";
            var target = Path.Combine(CacheDir, name);
            if (File.Exists(target)) return target;
            BitmapSource src;
            using (var s = File.OpenRead(file))
            {
                var decoder = BitmapDecoder.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                src = decoder.Frames[0];
            }
            var side = Math.Min(src.PixelWidth, src.PixelHeight);
            var cropped = new CroppedBitmap(src, new Int32Rect((src.PixelWidth - side) / 2, 0, side, side));
            BitmapSource output = cropped;
            if (side > 256)
            {
                var scale = 256.0 / side;
                output = new TransformedBitmap(cropped, new System.Windows.Media.ScaleTransform(scale, scale));
            }
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(output));
            var tmp = target + ".tmp";
            using (var o = File.Create(tmp)) encoder.Save(o);
            File.Move(tmp, target, overwrite: true);
            return target;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // ---------------------------------------------------------------- activation

    /// <summary>Hooks toast clicks. Call before the window shows: a toast can be what launched the app.</summary>
    public static void RegisterActivation()
    {
        try { ToastNotificationManagerCompat.OnActivated += OnActivated; }
        catch (Exception ex) { App.Log(ex); }
    }

    private static void OnActivated(ToastNotificationActivatedEventArgsCompat e)
    {
        ToastArguments args;
        try { args = ToastArguments.Parse(e.Argument); }
        catch (Exception) { return; }
        if (!args.TryGetValue("action", out var action)) return;
        args.TryGetValue("type", out var type);
        if (!args.TryGetValue("id", out var idText) || !int.TryParse(idText, out var id) || id < 0 || type == null) return;
        var season = Number(args, "season");
        var episode = Number(args, "episode");
        args.TryGetValue("tag", out var tag);
        args.TryGetValue("group", out var group);
        Dismiss(tag, group);

        if (action == "snooze")
        {
            args.TryGetValue("title", out var title);
            _ = Task.Run(async () =>
            {
                try { await AppServices.Plans.Snooze(type, id, season, episode, title ?? ""); }
                catch (Exception ex) { App.Log(ex); }
            });
            return;
        }
        var target = new OpenTarget(type, id, season, episode, Play: action == "play");
        Application.Current?.Dispatcher.BeginInvoke(() => Open(target));
    }

    private static int? Number(ToastArguments args, string key) =>
        args.TryGetValue(key, out var v) && int.TryParse(v, out var n) && n >= 0 ? n : null;

    private static void Dismiss(string? tag, string? group)
    {
        if (string.IsNullOrEmpty(tag)) return;
        try
        {
            if (string.IsNullOrEmpty(group)) ToastNotificationManagerCompat.History.Remove(tag);
            else ToastNotificationManagerCompat.History.Remove(tag, group);
        }
        catch (Exception) { }
    }

    /// <summary>Opens the title's page (and plays it for "Play"). Runs on the UI thread.</summary>
    public static async void Open(OpenTarget target)
    {
        try
        {
            App.ShowMainWindow();
            if (target.MediaType == P.Movie) AppServices.Navigator.Navigate(new MovieDetailRoute(target.MediaId));
            else AppServices.Navigator.Navigate(new ShowDetailRoute(target.MediaId, target.Season));
            if (!target.Play) return;
            if (target.MediaType == P.Movie) await AppServices.Playback.PlayMovie(target.MediaId);
            else if (target.Season is { } s && target.Episode is { } ep) await AppServices.Playback.PlayEpisode(target.MediaId, s, ep);
            else await AppServices.Playback.PlayShow(target.MediaId);
        }
        catch (Exception ex)
        {
            App.Log(ex);
        }
    }
}
