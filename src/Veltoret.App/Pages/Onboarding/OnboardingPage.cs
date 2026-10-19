using System.Net;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;

namespace Veltoret.App.Pages.Onboarding;

using Accounts = Veltoret.Core.Storage.Accounts;

/// <summary>
/// First-run setup (Android OnboardingScreen): Welcome → Accounts → Folders → TMDB → Scan. Back works on steps
/// 1–3. Finishing (either button on the Scan step) sets OnboardingComplete and opens Home.
/// </summary>
public sealed class OnboardingPage : UserControl
{
    private enum Step { Welcome, Accounts, Folders, Tmdb, Scan }

    private Step _step = Step.Welcome;
    private readonly Grid _host = new() { ClipToBounds = true };
    private FrameworkElement? _current;

    // Accounts / folders state.
    private List<AccountEntity> _accounts = new();
    private List<LibraryFolderEntity> _folders = new();
    private bool _connecting;
    private string? _connectError;

    // TMDB state.
    private bool _useOwnKey;
    private string _key = "";
    private bool _showKey;
    private enum KeyStatus { None, Checking, Valid, Invalid }
    private KeyStatus _keyStatus;
    private string? _keyError;

    // Scan state.
    private ScanState _scan = new();

    public OnboardingPage()
    {
        SetResourceReference(BackgroundProperty, "Brush.Background");
        Focusable = true;
        FocusVisualStyle = null;
        Content = _host;
        _key = AppServices.Settings.Current.TmdbKeyOverride;
        _useOwnKey = string.IsNullOrWhiteSpace(BundledKeys.Tmdb);
        Loaded += async (_, _) =>
        {
            try { AppServices.Scanner.StateChanged += OnScan; _scan = AppServices.Scanner.State; } catch (Exception) { }
            await ReloadSources();
            if (_current == null) Show(_step, forward: true, animate: false);
        };
        Unloaded += (_, _) => { try { AppServices.Scanner.StateChanged -= OnScan; } catch (Exception) { } };
        PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt && CanGoBack) { e.Handled = true; Back(); }
        };
        PreviewMouseDown += (_, e) => { if (e.ChangedButton == MouseButton.XButton1 && CanGoBack) { e.Handled = true; Back(); } };
        try { AppServices.Db.Changed += OnDb; } catch (Exception) { }
    }

    private void OnDb(IReadOnlySet<string> tables)
    {
        if (!tables.Contains("accounts") && !tables.Contains("library_folders")) return;
        Dispatcher.BeginInvoke(async () =>
        {
            await ReloadSources();
            if (_step is Step.Accounts or Step.Folders) Rerender();
        });
    }

    private void OnScan(ScanState s) => Dispatcher.BeginInvoke(() =>
    {
        _scan = s;
        if (_step == Step.Scan) UpdateScan();
    });

    private async Task ReloadSources()
    {
        try
        {
            _accounts = await AppServices.Library.AccountList();
            _folders = await AppServices.Library.Folders();
        }
        catch (Exception ex) { App.Log(ex); }
    }

    private bool CanGoBack => _step is Step.Accounts or Step.Folders or Step.Tmdb;

    private void Back()
    {
        if (!CanGoBack) return;
        Show(_step - 1, forward: false);
    }

    private void Next() => Show(_step + 1, forward: true);

    // ---------------- Layout ----------------

    private void Rerender() => Show(_step, forward: true, animate: false);

    private void Show(Step step, bool forward, bool animate = true)
    {
        _step = step;
        var page = Build(step);
        var old = _current;
        _current = page;
        _host.Children.Add(page);
        if (old == null || !animate)
        {
            if (old != null) _host.Children.Remove(old);
            return;
        }
        var w = Math.Max(1, ActualWidth);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var tIn = new TranslateTransform(forward ? w / 3 : -w / 3, 0);
        page.RenderTransform = tIn;
        page.Opacity = 0;
        page.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(360)));
        tIn.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(420)) { EasingFunction = ease });
        var tOut = new TranslateTransform();
        old.RenderTransform = tOut;
        old.IsHitTestVisible = false;
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(220));
        fade.Completed += (_, _) => _host.Children.Remove(old);
        old.BeginAnimation(OpacityProperty, fade);
        tOut.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(forward ? -w / 4 : w / 4, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
    }

    private FrameworkElement Build(Step step)
    {
        var container = new DockPanel { MaxWidth = 1200, Margin = new Thickness(48, 12, 48, 12) };
        if (step != Step.Welcome)
        {
            var progress = TopProgress((int)step);
            DockPanel.SetDock(progress, Dock.Top);
            container.Children.Add(progress);
        }
        var (illustration, content, bottom) = step switch
        {
            Step.Welcome => Welcome(),
            Step.Accounts => AccountsStep(),
            Step.Folders => FoldersStep(),
            Step.Tmdb => TmdbStep(),
            _ => ScanStep(),
        };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var ill = new Grid { Margin = new Thickness(0, 0, 56, 0), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        ill.Children.Add(illustration);
        Motion.Play(ill, 0);
        row.Children.Add(ill);

        var right = new DockPanel { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Stretch };
        Grid.SetColumn(right, 1);
        bottom.Margin = new Thickness(0, 16, 0, 12);
        DockPanel.SetDock(bottom, Dock.Bottom);
        right.Children.Add(bottom);
        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
            Content = new Border { Child = content, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(0, 0, 8, 0) },
        };
        SmoothScroll.SetIsEnabled(scroll, true);
        right.Children.Add(scroll);
        row.Children.Add(right);
        container.Children.Add(row);
        return container;
    }

    private FrameworkElement TopProgress(int index)
    {
        var dock = new DockPanel { Margin = new Thickness(0, 0, 0, 12), Height = 38 };
        if (CanGoBack)
        {
            var back = UiKit.IconButton("ArrowBack", "Back", Back, 38);
            back.Margin = new Thickness(0, 0, 14, 0);
            DockPanel.SetDock(back, Dock.Left);
            dock.Children.Add(back);
        }
        var label = UiKit.Text($"{index} of 4", "Text.LabelMedium", "TextMuted", wrap: false);
        label.Margin = new Thickness(14, 0, 0, 0);
        label.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(label, Dock.Right);
        dock.Children.Add(label);
        var bars = new Grid { VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < 4; i++)
        {
            bars.ColumnDefinitions.Add(new ColumnDefinition());
            var track = new Grid { Height = 4, Margin = new Thickness(i == 0 ? 0 : 3, 0, i == 3 ? 0 : 3, 0) };
            track.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = UiKit.Brush("Outline") });
            var fill = new Border { CornerRadius = new CornerRadius(2), Background = UiKit.Brush("Amber"), HorizontalAlignment = HorizontalAlignment.Left, RenderTransformOrigin = new Point(0, 0.5) };
            var scale = new ScaleTransform(i < index - 1 ? 1 : 0, 1);
            fill.RenderTransform = scale;
            track.Children.Add(fill);
            track.SizeChanged += (_, e) => fill.Width = e.NewSize.Width;
            if (i < index) scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(600)) { EasingFunction = new CubicEase() });
            Grid.SetColumn(track, i);
            bars.Children.Add(track);
        }
        dock.Children.Add(bars);
        return dock;
    }

    private static void StepHeader(Panel p, string eyebrow, string title, string body, int idx = 1)
    {
        var e = UiKit.Text(eyebrow.ToUpperInvariant(), "Text.LabelSmall", "Amber", maxLines: 1);
        Motion.Play(e, idx);
        p.Children.Add(e);
        var t = UiKit.Text(title, "Text.DisplaySmall");
        t.Margin = new Thickness(0, 8, 0, 0);
        Motion.Play(t, idx + 1);
        p.Children.Add(t);
        var b = UiKit.Text(body, "Text.BodyLarge", "TextMuted");
        b.Margin = new Thickness(0, 10, 0, 24);
        Motion.Play(b, idx + 2);
        p.Children.Add(b);
    }

    private static Button Wide(Button b)
    {
        b.HorizontalAlignment = HorizontalAlignment.Stretch;
        b.HorizontalContentAlignment = HorizontalAlignment.Center;
        return b;
    }

    // ---------------- Welcome ----------------

    private (FrameworkElement, FrameworkElement, FrameworkElement) Welcome()
    {
        var wall = new Viewbox { Child = Illustrations.PosterWall(520), MaxWidth = 560, Stretch = Stretch.Uniform };
        var c = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var mark = new Wordmark(large: true) { HorizontalAlignment = HorizontalAlignment.Left };
        Motion.Play(mark, 1);
        c.Children.Add(mark);
        var tag = UiKit.Text("Your movies and shows,\nas a private cinema.", "Text.HeadlineMedium");
        tag.Margin = new Thickness(0, 10, 0, 24);
        Motion.Play(tag, 2);
        c.Children.Add(tag);
        var features = new[]
        {
            ("AutoAwesome", "Organized for you", "Posters, cast and episode guides added automatically."),
            ("PlayCircle", "Plays everything", "MKV, MP4 and more, with any audio track or subtitle."),
            ("Devices", "Picks up where you left off", "Continue Watching and Next Up remember your place."),
        };
        for (var i = 0; i < features.Length; i++)
        {
            var (icon, title, body) = features[i];
            var row = new DockPanel { Margin = new Thickness(0, 8, 0, 8) };
            var tile = new Border
            {
                Width = 44, Height = 44, CornerRadius = new CornerRadius(12), Background = UiKit.Brush("Surface"),
                BorderBrush = UiKit.Brush("Outline"), BorderThickness = new Thickness(1), Child = CenterIcon(icon, 22, "Amber"),
                Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Top,
            };
            DockPanel.SetDock(tile, Dock.Left);
            row.Children.Add(tile);
            var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            col.Children.Add(UiKit.Text(title, "Text.TitleMedium"));
            col.Children.Add(UiKit.Text(body, "Text.BodyMedium", "TextMuted"));
            row.Children.Add(col);
            Motion.Play(row, 3 + i);
            c.Children.Add(row);
        }
        var bottom = new StackPanel();
        var start = Wide(UiKit.Button("Get started", "Button.Primary", "ArrowForward", Next));
        Motion.Play(start, 7);
        bottom.Children.Add(start);
        var note = UiKit.Text("Free and open source · Your files stay in your Drive and on your PC", "Text.BodySmall", "TextFaint");
        note.TextAlignment = TextAlignment.Center;
        note.Margin = new Thickness(0, 12, 0, 0);
        Motion.Play(note, 8);
        bottom.Children.Add(note);
        return (wall, c, bottom);
    }

    private static FrameworkElement CenterIcon(string icon, double size, string brush)
    {
        var i = UiKit.Icon(icon, size, brush);
        i.HorizontalAlignment = HorizontalAlignment.Center;
        return i;
    }

    // ---------------- Accounts ----------------

    private (FrameworkElement, FrameworkElement, FrameworkElement) AccountsStep()
    {
        var c = new StackPanel();
        StepHeader(c, "Step 1 · Connect", "Where are your videos?",
            "Connect the Google Drive that holds them, use folders on this PC (internal or USB drives), a network server (SMB) at home, or all of them. You can change this any time.");
        foreach (var a in _accounts) c.Children.Add(AccountPanel(a));

        var buttons = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        var google = _accounts.Where(a => Accounts.IsDrive(a.Email)).ToList();
        var connect = Wide(UiKit.Button(google.Count == 0 ? "Connect Google account" : "Add another Google account",
            _accounts.Count == 0 ? "Button.Primary" : "Button.Secondary", "PersonAdd", () => _ = ConnectGoogle()));
        ButtonAssist.SetIsLoading(connect, _connecting);
        buttons.Children.Add(connect);
        if (_accounts.All(a => !Accounts.IsLocal(a.Email)))
        {
            var local = Wide(UiKit.Button("Use folders on this PC", "Button.Secondary", "Computer", () => _ = UseLocal()));
            local.Margin = new Thickness(0, 10, 0, 0);
            buttons.Children.Add(local);
        }
        var smb = Wide(UiKit.Button("Add network server", "Button.Secondary", "Dns", () => _ = AddServer()));
        smb.Margin = new Thickness(0, 10, 0, 0);
        buttons.Children.Add(smb);
        c.Children.Add(buttons);

        if (_connectError != null)
        {
            var card = new Border
            {
                CornerRadius = new CornerRadius(16), BorderBrush = UiKit.Brush("Danger45"), BorderThickness = new Thickness(1),
                Background = UiKit.Brush("Surface"), Padding = new Thickness(16), Margin = new Thickness(0, 14, 0, 0),
            };
            var col = new StackPanel();
            col.Children.Add(UiKit.Text("Couldn't connect", "Text.TitleMedium"));
            col.Children.Add(UiKit.Text(_connectError, "Text.BodyMedium", "TextMuted"));
            var hint = UiKit.Text("Google sign-in needs your own OAuth client (a “Desktop app” client JSON from Google Cloud Console). Import it in Settings → Accounts, then try again.", "Text.BodySmall", "TextFaint");
            hint.Margin = new Thickness(0, 8, 0, 0);
            col.Children.Add(hint);
            card.Child = col;
            c.Children.Add(card);
        }

        var privacy = new Border { CornerRadius = new CornerRadius(14), Background = UiKit.Brush("Surface"), Padding = new Thickness(14), Margin = new Thickness(0, 16, 0, 0) };
        var pr = new DockPanel();
        var lockIcon = UiKit.Icon("Lock", 20, "AmberSoft");
        lockIcon.Margin = new Thickness(0, 0, 12, 0);
        lockIcon.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(lockIcon, Dock.Left);
        pr.Children.Add(lockIcon);
        pr.Children.Add(UiKit.Text("Private by design. Veltoret talks to Google and your network servers directly from this PC and only sees the folders you pick — no servers of ours, no tracking. You can disconnect at any time in Settings.", "Text.BodySmall", "TextMuted"));
        privacy.Child = pr;
        c.Children.Add(privacy);

        var bottom = Wide(UiKit.Button("Continue", "Button.Primary", onClick: Next));
        bottom.IsEnabled = _accounts.Count > 0;
        return (Illustrations.Connect(_accounts.Count > 0), c, bottom);
    }

    private static string AccountLabel(AccountEntity a) =>
        Accounts.IsDrive(a.Email) ? a.Email : string.IsNullOrWhiteSpace(a.DisplayName) ? LibraryLabel(a.Email) : a.DisplayName;

    private static string LibraryLabel(string account) => Pages.Library.LibraryViewModel.LabelFor(account);

    private static FrameworkElement AccountPanel(AccountEntity a)
    {
        var dock = new DockPanel();
        var avatar = new Grid { Width = 40, Height = 40, Margin = new Thickness(0, 0, 12, 0) };
        avatar.Children.Add(new System.Windows.Shapes.Ellipse { Fill = UiKit.Brush("SurfaceHigh"), Stroke = UiKit.Brush("Outline"), StrokeThickness = 1 });
        if (Accounts.IsLocal(a.Email)) avatar.Children.Add(CenterIcon("Computer", 20, "AmberSoft"));
        else if (Accounts.IsSmb(a.Email)) avatar.Children.Add(CenterIcon("Dns", 20, "AmberSoft"));
        else if (!string.IsNullOrEmpty(a.PhotoUrl))
            avatar.Children.Add(new AsyncImage { Url = a.PhotoUrl, CornerRadius = new CornerRadius(20), FallbackText = Initial(a) });
        else
        {
            var t = UiKit.Text(Initial(a), "Text.TitleMedium", "AmberSoft", wrap: false);
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            avatar.Children.Add(t);
        }
        DockPanel.SetDock(avatar, Dock.Left);
        dock.Children.Add(avatar);
        var check = UiKit.Icon("CheckCircle", 22, "Amber");
        check.ToolTip = "Connected";
        DockPanel.SetDock(check, Dock.Right);
        dock.Children.Add(check);
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var name = Accounts.IsDrive(a.Email) && !string.IsNullOrWhiteSpace(a.DisplayName) ? a.DisplayName : AccountLabel(a);
        col.Children.Add(UiKit.Text(name, "Text.TitleMedium", maxLines: 1));
        var sub = Accounts.IsLocal(a.Email) ? "Folders on this PC" : Accounts.IsSmb(a.Email) ? "Network server" : a.Email;
        col.Children.Add(UiKit.Text(sub, "Text.BodySmall", "TextMuted", maxLines: 1));
        dock.Children.Add(col);
        var p = UiKit.Panel(dock, new Thickness(14));
        p.Margin = new Thickness(0, 0, 0, 10);
        return p;
    }

    private static string Initial(AccountEntity a)
    {
        var s = string.IsNullOrWhiteSpace(a.DisplayName) ? a.Email : a.DisplayName;
        return s.Length > 0 ? char.ToUpperInvariant(s[0]).ToString() : "?";
    }

    private Window? Owner => Window.GetWindow(this) ?? Application.Current.MainWindow;

    private async Task ConnectGoogle()
    {
        if (_connecting) return;
        _connecting = true;
        _connectError = null;
        Rerender();
        try { await Veltoret.App.AccountsUi.ConnectGoogle.Run(Owner); }
        catch (Exception ex) { App.Log(ex); _connectError = ex.Message; }
        _connecting = false;
        await ReloadSources();
        Rerender();
    }

    private async Task UseLocal()
    {
        try { await AppServices.Library.EnsureDeviceAccount(); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
        await ReloadSources();
        Rerender();
    }

    private async Task AddServer()
    {
        try { await Veltoret.App.Network.AddServerDialog.Show(Owner); }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
        await ReloadSources();
        Rerender();
    }

    // ---------------- Folders ----------------

    private (FrameworkElement, FrameworkElement, FrameworkElement) FoldersStep()
    {
        var c = new StackPanel();
        StepHeader(c, "Step 2 · Library", "Choose your folders",
            "Tell Veltoret where your movies and TV shows live. You can add several folders of each kind.");
        var multi = _accounts.Count > 1;
        var anyFolders = _folders.Count > 0;
        foreach (var a in _accounts)
        {
            if (multi)
            {
                var label = UiKit.Text(AccountLabel(a), "Text.LabelLarge", "TextMuted", maxLines: 1);
                label.Margin = new Thickness(0, c.Children.Count > 3 ? 16 : 0, 0, 8);
                c.Children.Add(label);
            }
            var mine = _folders.Where(f => f.AccountEmail == a.Email).ToList();
            foreach (var f in mine) c.Children.Add(FolderPanel(f));
            var name = AccountLabel(a);
            var text = mine.Count > 0 ? "Add another folder"
                : Accounts.IsLocal(a.Email) ? (multi ? "Choose a folder on this PC" : "Choose a folder")
                : Accounts.IsSmb(a.Email) ? (multi ? $"Choose a folder on {name}" : "Choose a folder")
                : multi ? "Choose a Drive folder" : "Choose a folder";
            var account = a.Email;
            var b = Wide(UiKit.Button(text, anyFolders ? "Button.Secondary" : "Button.Primary", "CreateNewFolder", () => _ = AddFolder(account)));
            b.Margin = new Thickness(0, 0, 0, 10);
            c.Children.Add(b);
        }
        var tip = new StackPanel();
        tip.Children.Add(UiKit.Text("Works best like this", "Text.TitleSmall"));
        var mono = new TextBlock
        {
            Text = "Movies/\n  Inception (2010)/Inception.mkv\nTV Shows/\n  Breaking Bad/\n    Season 1/S01E01.mkv",
            FontFamily = UiKit.Res<FontFamily>("Font.Mono"), FontSize = 13, Foreground = UiKit.Brush("AmberSoft"),
            Margin = new Thickness(0, 10, 0, 10), LineHeight = 19,
        };
        tip.Children.Add(mono);
        tip.Children.Add(UiKit.Text("Messy names are fine too — anything Veltoret can't recognise can be fixed later in a couple of clicks.", "Text.BodySmall", "TextMuted"));
        var tipPanel = UiKit.Panel(tip);
        tipPanel.Margin = new Thickness(0, 10, 0, 0);
        c.Children.Add(tipPanel);
        var bottom = Wide(UiKit.Button("Continue", "Button.Primary", onClick: Next));
        bottom.IsEnabled = anyFolders;
        return (Illustrations.Folders(), c, bottom);
    }

    private FrameworkElement FolderPanel(LibraryFolderEntity f)
    {
        var dock = new DockPanel();
        var icon = UiKit.Icon(f.Type == LibraryType.MOVIES ? "Movie" : "LiveTv", 22, "Amber");
        icon.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(icon, Dock.Left);
        dock.Children.Add(icon);
        var id = f.Id;
        var remove = UiKit.IconButton("Close", "Remove", async () =>
        {
            try { await AppServices.Library.RemoveFolder(id); }
            catch (Exception ex) { App.Log(ex); }
            await ReloadSources();
            Rerender();
        }, 32);
        remove.Style = UiKit.Style("Button.IconFlat");
        DockPanel.SetDock(remove, Dock.Right);
        dock.Children.Add(remove);
        var pill = UiKit.Pill(f.Type == LibraryType.MOVIES ? "Movies" : "TV Shows", accent: true);
        pill.Margin = new Thickness(8, 0, 8, 0);
        pill.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(pill, Dock.Right);
        dock.Children.Add(pill);
        var name = UiKit.Text(f.Name, "Text.TitleSmall", maxLines: 1);
        name.ToolTip = f.DriveFolderId;
        dock.Children.Add(name);
        var p = UiKit.Panel(dock, new Thickness(14, 10, 8, 10));
        p.Margin = new Thickness(0, 0, 0, 10);
        return p;
    }

    private async Task AddFolder(string account)
    {
        try
        {
            var picked = await FolderPickerDialog.PickLibraryFolder(Owner, account);
            if (picked is not { } p) return;
            var id = await AppServices.Library.AddFolder(account, p.Id, p.Name, p.Type);
            if (id == null) Toast.Show("That folder is already in your library");
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
        await ReloadSources();
        Rerender();
    }

    // ---------------- TMDB ----------------

    private (FrameworkElement, FrameworkElement, FrameworkElement) TmdbStep()
    {
        var c = new StackPanel();
        var hasBundled = !string.IsNullOrWhiteSpace(BundledKeys.Tmdb);
        FrameworkElement bottom;
        if (hasBundled && !_useOwnKey)
        {
            StepHeader(c, "Step 3 · Artwork", "Posters & details are ready",
                "This copy of Veltoret comes with a TMDB key, so posters, cast and episode guides work without any setup.");
            var own = UiKit.Button("Use my own TMDB key instead", "Button.Text", "Key", () => { _useOwnKey = true; Rerender(); });
            own.HorizontalAlignment = HorizontalAlignment.Left;
            own.Margin = new Thickness(-8, 0, 0, 16);
            c.Children.Add(own);
            c.Children.Add(new TmdbAttribution());
            bottom = Wide(UiKit.Button("Build my library", "Button.Primary", onClick: BuildLibrary));
            return (Illustrations.Metadata(), c, bottom);
        }

        StepHeader(c, "Step 3 · Artwork", "Add posters & details",
            "Veltoret uses The Movie Database (TMDB) for posters, cast and episode guides. A free key takes about a minute.");
        var steps = new[]
        {
            "Create a free account at themoviedb.org",
            "Open Settings → API and request a key (choose “Personal”)",
            "Copy the API Key or the Read Access Token and paste it below",
        };
        for (var i = 0; i < steps.Length; i++)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
            var disc = new Grid { Width = 26, Height = 26, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Top };
            disc.Children.Add(new System.Windows.Shapes.Ellipse { Fill = UiKit.Brush("AmberDim") });
            var n = UiKit.Text((i + 1).ToString(), "Text.LabelMedium", "AmberSoft", wrap: false);
            n.HorizontalAlignment = HorizontalAlignment.Center;
            n.VerticalAlignment = VerticalAlignment.Center;
            disc.Children.Add(n);
            DockPanel.SetDock(disc, Dock.Left);
            row.Children.Add(disc);
            var t = UiKit.Text(steps[i], "Text.BodyMedium");
            t.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(t);
            c.Children.Add(row);
        }
        var link = UiKit.Button("Open TMDB API settings", "Button.Text", "OpenInNew", () => UiKit.OpenUrl("https://www.themoviedb.org/settings/api"));
        link.HorizontalAlignment = HorizontalAlignment.Left;
        link.Margin = new Thickness(-8, 0, 0, 14);
        c.Children.Add(link);

        // Key field: a PasswordBox, or a TextBox while "Show key" is on.
        Control field;
        var toggle = UiKit.IconButton(_showKey ? "VisibilityOff" : "Visibility", "Show key", () => { _showKey = !_showKey; Rerender(); }, 32);
        toggle.Style = UiKit.Style("Button.IconFlat");
        ButtonAssist.SetIconSize(toggle, 20);
        if (_showKey)
        {
            var tb = new TextBox { Style = UiKit.Style("TextBox"), Text = _key, Tag = toggle };
            tb.TextChanged += (_, _) => KeyEdited(tb.Text);
            field = tb;
        }
        else
        {
            var pb = new PasswordBox { Style = UiKit.Style("PasswordBox"), Password = _key, Tag = toggle };
            pb.PasswordChanged += (_, _) => KeyEdited(pb.Password);
            field = pb;
        }
        ButtonAssist.SetIcon(field, Controls.Icon.Get("Key"));
        ButtonAssist.SetPlaceholder(field, "API key or Read Access Token");
        System.Windows.Automation.AutomationProperties.SetName(field, "API key or Read Access Token");
        field.Loaded += (_, _) =>
        {
            field.Focus();
            if (field is TextBox t) t.CaretIndex = t.Text.Length;
        };
        c.Children.Add(field);

        _statusLine = new ContentControl { Focusable = false, Margin = new Thickness(0, 10, 0, 0) };
        UpdateKeyStatus();
        c.Children.Add(_statusLine);
        var attribution = new TmdbAttribution { Margin = new Thickness(0, 20, 0, 0) };
        c.Children.Add(attribution);

        _keyButton = Wide(UiKit.Button("Verify key", "Button.Primary", onClick: () =>
        {
            if (_keyStatus == KeyStatus.Valid) BuildLibrary();
            else _ = VerifyKey();
        }));
        UpdateKeyButton();
        return (Illustrations.Metadata(), c, _keyButton);
    }

    private ContentControl? _statusLine;
    private Button? _keyButton;

    private void KeyEdited(string value)
    {
        if (value == _key) return;
        _key = value;
        _keyStatus = KeyStatus.None;
        _keyError = null;
        UpdateKeyStatus();
        UpdateKeyButton();
    }

    private void UpdateKeyButton()
    {
        if (_keyButton == null) return;
        _keyButton.Content = _keyStatus == KeyStatus.Valid ? "Build my library" : "Verify key";
        _keyButton.IsEnabled = _key.Trim().Length > 0 || _keyStatus == KeyStatus.Valid;
        ButtonAssist.SetIsLoading(_keyButton, _keyStatus == KeyStatus.Checking);
    }

    private void UpdateKeyStatus()
    {
        if (_statusLine == null) return;
        if (_keyStatus is KeyStatus.None or KeyStatus.Checking) { _statusLine.Content = null; return; }
        var ok = _keyStatus == KeyStatus.Valid;
        var row = new DockPanel();
        var icon = UiKit.Icon(ok ? "CheckCircle" : "ErrorOutline", 18, ok ? "Success" : "Danger");
        icon.Margin = new Thickness(0, 0, 8, 0);
        icon.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        row.Children.Add(UiKit.Text(ok ? "Key verified — you're all set" : _keyError, "Text.BodyMedium", ok ? "Success" : "Danger"));
        _statusLine.Content = row;
    }

    private async Task VerifyKey()
    {
        var key = _key.Trim();
        if (key.Length == 0) return;
        _keyStatus = KeyStatus.Checking;
        UpdateKeyButton();
        UpdateKeyStatus();
        try
        {
            AppServices.Settings.Update(s => s with { TmdbKeyOverride = key });
            await AppServices.Tmdb.ValidateKey();
            _keyStatus = KeyStatus.Valid;
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.Unauthorized)
        {
            _keyStatus = KeyStatus.Invalid;
            _keyError = "TMDB didn't accept this key. Copy it again from your TMDB account.";
        }
        catch (Exception ex)
        {
            _keyStatus = KeyStatus.Invalid;
            _keyError = ex is HttpRequestException { StatusCode: null } || string.IsNullOrWhiteSpace(ex.Message)
                ? "Couldn't reach TMDB. Check your connection."
                : ex.Message;
        }
        UpdateKeyButton();
        UpdateKeyStatus();
    }

    private void BuildLibrary()
    {
        try { _ = AppServices.Scans.RunNow(); }
        catch (Exception ex) { App.Log(ex); }
        try { _scan = AppServices.Scanner.State; } catch (Exception) { }
        Show(Step.Scan, forward: true);
    }

    // ---------------- Scan ----------------

    private TextBlock? _scanTitle, _scanBody, _filesValue, _matchedValue, _phase;
    private ProgressBar? _scanProgress;
    private FrameworkElement? _runningBlock;
    private Button? _finishButton;
    private ContentControl? _scanIllustration;
    private bool? _illustrationFinished;

    private bool Finished => !_scan.Running && _scan.LastFinishedAt > 0;

    private (FrameworkElement, FrameworkElement, FrameworkElement) ScanStep()
    {
        var c = new StackPanel();
        var eyebrow = UiKit.Text("STEP 4 · LIBRARY", "Text.LabelSmall", "Amber", maxLines: 1);
        c.Children.Add(eyebrow);
        _scanTitle = UiKit.Text("", "Text.DisplaySmall");
        _scanTitle.Margin = new Thickness(0, 8, 0, 0);
        c.Children.Add(_scanTitle);
        _scanBody = UiKit.Text("", "Text.BodyLarge", "TextMuted");
        _scanBody.Margin = new Thickness(0, 10, 0, 24);
        c.Children.Add(_scanBody);
        var tiles = new Grid();
        tiles.ColumnDefinitions.Add(new ColumnDefinition());
        tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        tiles.ColumnDefinitions.Add(new ColumnDefinition());
        (var t1, _filesValue) = StatTile("Videos found");
        (var t2, _matchedValue) = StatTile("Matched");
        Grid.SetColumn(t2, 2);
        tiles.Children.Add(t1);
        tiles.Children.Add(t2);
        c.Children.Add(tiles);
        var running = new StackPanel { Margin = new Thickness(0, 18, 0, 0) };
        _phase = UiKit.Text("", "Text.BodyMedium", "TextMuted");
        running.Children.Add(_phase);
        _scanProgress = new ProgressBar { Height = 4, Margin = new Thickness(0, 8, 0, 0) };
        running.Children.Add(_scanProgress);
        _runningBlock = running;
        c.Children.Add(running);
        _finishButton = Wide(UiKit.Button("", "Button.Primary", onClick: Finish));
        _scanIllustration = new ContentControl { Focusable = false };
        _illustrationFinished = null;
        UpdateScan();
        return (_scanIllustration, c, _finishButton);
    }

    private static (FrameworkElement Tile, TextBlock Value) StatTile(string label)
    {
        var col = new StackPanel();
        var value = UiKit.Text("0", "Text.HeadlineMedium", wrap: false);
        col.Children.Add(value);
        col.Children.Add(UiKit.Text(label, "Text.BodySmall", "TextMuted"));
        var b = new Border
        {
            CornerRadius = new CornerRadius(16), Background = UiKit.Brush("Surface"), BorderBrush = UiKit.Brush("Outline"),
            BorderThickness = new Thickness(1), Padding = new Thickness(16), Child = col,
        };
        return (b, value);
    }

    private void UpdateScan()
    {
        if (_scanTitle == null) return;
        var s = _scan;
        var finished = Finished;
        _scanTitle.Text = finished ? "Your library is ready" : "Building your library";
        _scanBody!.Text = finished && !string.IsNullOrEmpty(s.Error) ? $"Finished with a problem: {s.Error}"
            : finished ? "Everything is organized. Enjoy the show."
            : "This only takes a while the first time. You can start browsing whenever you like.";
        _filesValue!.Text = s.FilesFound.ToString(Formats.Us);
        _matchedValue!.Text = s.ToMatch > 0 ? $"{s.Matched} / {s.ToMatch}" : s.Matched.ToString(Formats.Us);
        _runningBlock!.Visibility = s.Running ? Visibility.Visible : Visibility.Collapsed;
        _phase!.Text = s.Phase.StartsWith("Matching", StringComparison.Ordinal) ? "Matching titles with TMDB…" : "Reading your Drive…";
        var target = s.ToMatch > 0 ? (double)s.Matched / s.ToMatch : 0.05;
        _scanProgress!.BeginAnimation(System.Windows.Controls.Primitives.RangeBase.ValueProperty,
            new DoubleAnimation(Math.Clamp(target, 0.05, 1), TimeSpan.FromMilliseconds(600)));
        if (finished)
        {
            _finishButton!.Content = "Start watching";
            _finishButton.Style = UiKit.Style("Button.Primary");
            ButtonAssist.SetIcon(_finishButton, Controls.Icon.Get("PlayCircle"));
        }
        else
        {
            _finishButton!.Content = "Continue in background";
            _finishButton.Style = UiKit.Style("Button.Secondary");
            ButtonAssist.SetIcon(_finishButton, null);
        }
        if (_illustrationFinished != finished)
        {
            _illustrationFinished = finished;
            _scanIllustration!.Content = Illustrations.Scan(finished);
        }
    }

    private void Finish()
    {
        try { AppServices.Settings.Update(s => s with { OnboardingComplete = true }); }
        catch (Exception ex) { App.Log(ex); }
        try { AppServices.Db.Changed -= OnDb; } catch (Exception) { }
        AppServices.Navigator.Navigate(new HomeRoute());
    }
}
