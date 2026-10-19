using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Plans;
using Veltoret.App.Services;
using Veltoret.App.Tray;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;
using Src = Veltoret.Core.Storage.Accounts;
using Veltoret.Core.Tmdb;
using P = Veltoret.Core.Plans.Plans;
using static Veltoret.App.Pages.Settings.SettingsRows;

namespace Veltoret.App.Pages.Settings;

/// <summary>
/// Settings (Android: ui/settings/SettingsScreen.kt). Two columns when the window is at least 840 px wide: Sources
/// and Library on the left; Playback, Subtitles, Reminders &amp; alerts, Appearance, App, TMDB and About on the right.
/// Google accounts, network servers and Play on TV are sections the Drive and network modules provide.
/// </summary>
public sealed class SettingsPage : UserControl
{
    private static readonly (string Code, string Name)[] Languages =
    {
        ("en", "English"), ("hi", "Hindi"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"),
        ("ta", "Tamil"), ("te", "Telugu"), ("ml", "Malayalam"), ("bn", "Bengali"), ("ur", "Urdu"), ("tr", "Turkish"),
    };

    private readonly Grid _columns = new();
    private readonly StackPanel _left = new();
    private readonly StackPanel _right = new();
    private readonly StackPanel _accountsHost = new();
    private readonly StackPanel _libraryRows = new();
    private readonly StackPanel _remindersRows = new();
    private readonly DispatcherTimer _refreshTimer;
    private readonly DispatcherTimer _scanTimer;

    // Scan progress block (kept, so the progress bar can animate).
    private readonly Border _scanBlock;
    private readonly TextBlock _scanTitle, _scanStep, _scanCounts, _scanPercent, _scanPath;
    private readonly ProgressBar _scanBar;
    private readonly Button _idleRow;
    private readonly TextBlock _idleSubtitle;

    private Data _data = new();
    private bool _refreshing, _refreshAgain;

    private sealed record Data
    {
        public List<AccountEntity> Accounts { get; init; } = new();
        public List<LibraryFolderEntity> Folders { get; init; } = new();
        public Dictionary<long, int> Counts { get; init; } = new();
        public int Unmatched { get; init; }
        public int Ignored { get; init; }
        public int Archives { get; init; }
        public List<ReminderEntity> Reminders { get; init; } = new();
    }

    private static AppSettings S => AppServices.Settings.Current;
    private static void Save(Func<AppSettings, AppSettings> edit) => AppServices.Settings.Update(edit);

    public SettingsPage()
    {
        SetResourceReference(BackgroundProperty, "Brush.Background");
        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _refreshTimer.Tick += (_, _) => { _refreshTimer.Stop(); _ = Refresh(); };
        _scanTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _scanTimer.Tick += (_, _) => { _scanTimer.Stop(); RenderScan(); RenderSources(); };

        // Scan block.
        _scanTitle = Ui.Text("", "Text.TitleSmall");
        _scanStep = Ui.Text("", "Text.BodySmall", "Brush.TextMuted");
        _scanCounts = Ui.Text("", "Text.BodySmall", "Brush.TextMuted");
        _scanPercent = Ui.Text("", "Text.BodySmall", "Brush.TextMuted");
        _scanPath = Ui.OneLine("", "Text.BodySmall", "Brush.TextFaint");
        _scanBar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 4, Margin = new Thickness(0, 12, 0, 8) };
        Ui.Apply(_scanBar, "ProgressBar");
        _scanBlock = BuildScanBlock();
        (_idleRow, _idleSubtitle) = Setting("Scan library now", "", "Refresh", () => _ = AppServices.Scans.RunNow(), chevron: false);

        BuildLayout();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        SizeChanged += (_, e) => { if (e.WidthChanged) Arrange(e.NewSize.Width); };
    }

    // ------------------------------------------------------------------ layout

    private void BuildLayout()
    {
        var header = Ui.Text("Settings", "Text.DisplaySmall");
        header.Margin = new Thickness(8, 0, 0, 0);

        // Left: Sources and Library.
        _left.Children.Add(Group("Sources"));
        _left.Children.Add(_accountsHost);
        foreach (var name in new[] { "Veltoret.App.AccountsUi.AccountsSection", "Veltoret.App.Network.NetworkServersSection", "Veltoret.App.Network.PlayOnTvSection" })
        {
            if (Host(name) is { } section)
            {
                section.Margin = new Thickness(0, 12, 0, 0);
                _left.Children.Add(section);
            }
        }
        _left.Children.Add(Group("Library"));
        var (libraryPanel, libraryStack) = Panel();
        libraryStack.Children.Add(_libraryRows);
        _left.Children.Add(libraryPanel);

        // Right.
        _right.Children.Add(Group("Playback"));
        _right.Children.Add(PanelOf(
            Switch("Auto-play next episode", "Counts down at the end of an episode", () => S.AutoPlayNext, v => Save(s => s with { AutoPlayNext = v })),
            Choice("Skip button", new[] { 30, 60, 85, 90, 120 }.Select(n => (n, $"+{n}s")).ToList(), () => S.SkipSeconds, v => Save(s => s with { SkipSeconds = v })),
            Choice("Seek step", new[] { 5, 10, 15, 30 }.Select(n => (n, $"{n}s")).ToList(), () => S.SeekSeconds, v => Save(s => s with { SeekSeconds = v })),
            Choice("Preferred audio", Languages.Select(l => (l.Code, l.Name)).ToList(), () => S.PreferredAudioLanguage, v => Save(s => s with { PreferredAudioLanguage = v })),
            Choice("Default subtitles", new[] { ("", "Off") }.Concat(Languages.Select(l => (l.Code, l.Name))).ToList(),
                () => S.PreferredSubtitleLanguage, v => Save(s => s with { PreferredSubtitleLanguage = v }))));

        _right.Children.Add(Group("Subtitles"));
        _right.Children.Add(PanelOf(
            Choice("Text size", new List<(float, string)> { (0.8f, "Small"), (1.0f, "Normal"), (1.25f, "Large"), (1.5f, "Extra large") },
                () => S.SubtitleScale, v => Save(s => s with { SubtitleScale = v })),
            Switch("Background box", "Dark box behind subtitle text", () => S.SubtitleBackground, v => Save(s => s with { SubtitleBackground = v }))));

        _right.Children.Add(Group("Reminders & alerts"));
        var (remindersPanel, remindersStack) = Panel();
        remindersStack.Children.Add(Switch("New episode alerts", "A notification on the day a show on your Watchlist airs a new episode",
            () => S.NewEpisodeAlerts, v => Save(s => s with { NewEpisodeAlerts = v })));
        remindersStack.Children.Add(_remindersRows);
        _right.Children.Add(remindersPanel);

        _right.Children.Add(Group("Appearance"));
        _right.Children.Add(PanelOf(
            Switch("Pure black", "True black background for OLED screens", () => S.OledBlack, v => Save(s => s with { OledBlack = v }))));

        _right.Children.Add(Group("App"));
        _right.Children.Add(PanelOf(
            Switch("Keep running in the notification area", "Reminders, new episode alerts and scans keep working after you close the window",
                () => S.RunInBackground, v => Save(s => s with { RunInBackground = v })),
            Switch("Start with Windows", "Opens in the notification area when you sign in",
                () => S.StartWithWindows, v =>
                {
                    if (StartupRegistration.Set(v)) Save(s => s with { StartWithWindows = v });
                    else Controls.Toast.Show("Windows didn't allow that change");
                })));

        _right.Children.Add(Group("TMDB"));
        _right.Children.Add(TmdbKeyPanel());

        _right.Children.Add(Group("About"));
        _right.Children.Add(AboutPanel());

        var root = new StackPanel { Margin = new Thickness(0, 28, 0, 48) };
        root.Children.Add(header);
        root.Children.Add(_columns);

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = root,
        };
        Content = scroll;
        Arrange(840);
        RenderScan();
    }

    private double _lastWidth = -1;

    /// <summary>Two columns at ≥ 840 px; else one column, at most 760 wide, centered.</summary>
    private void Arrange(double width)
    {
        var two = width >= 840;
        if (_lastWidth >= 0 && (_lastWidth >= 840) == two) { _lastWidth = width; return; }
        _lastWidth = width;
        _columns.Children.Clear();
        _columns.ColumnDefinitions.Clear();
        _columns.RowDefinitions.Clear();
        var gutter = width >= 840 ? 40 : width >= 600 ? 28 : 20;
        _columns.Margin = new Thickness(gutter - 8, 0, gutter - 8, 0);
        if (two)
        {
            _columns.MaxWidth = 1400;
            _columns.HorizontalAlignment = HorizontalAlignment.Stretch;
            _columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            _columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(_left, 0); Grid.SetRow(_left, 0);
            Grid.SetColumn(_right, 2); Grid.SetRow(_right, 0);
        }
        else
        {
            _columns.MaxWidth = 760;
            _columns.HorizontalAlignment = HorizontalAlignment.Center;
            _columns.RowDefinitions.Add(new RowDefinition());
            _columns.RowDefinitions.Add(new RowDefinition());
            Grid.SetColumn(_left, 0); Grid.SetRow(_left, 0);
            Grid.SetColumn(_right, 0); Grid.SetRow(_right, 1);
        }
        _columns.Children.Add(_left);
        _columns.Children.Add(_right);
    }

    /// <summary>Another module's UserControl, created by name so Settings builds even while it's missing.</summary>
    private static FrameworkElement? Host(string typeName)
    {
        try
        {
            var type = typeof(SettingsPage).Assembly.GetType(typeName);
            return type == null ? null : Activator.CreateInstance(type) as FrameworkElement;
        }
        catch (Exception ex)
        {
            App.Log(ex);
            return null;
        }
    }

    // ------------------------------------------------------------------ live data

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Db.Changed += OnDbChanged;
        AppServices.Scanner.StateChanged += OnScanChanged;
        _ = Refresh();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Db.Changed -= OnDbChanged;
        AppServices.Scanner.StateChanged -= OnScanChanged;
        _refreshTimer.Stop();
        _scanTimer.Stop();
    }

    private static readonly HashSet<string> Watched = new() { "accounts", "library_folders", "media_files", "archive_files", "reminders" };

    private void OnDbChanged(IReadOnlySet<string> tables)
    {
        if (!tables.Overlaps(Watched)) return;
        Dispatcher.BeginInvoke(() => { if (!_refreshTimer.IsEnabled) _refreshTimer.Start(); });
    }

    private void OnScanChanged(ScanState s) =>
        Dispatcher.BeginInvoke(() => { if (!_scanTimer.IsEnabled) _scanTimer.Start(); });

    private async Task Refresh()
    {
        if (_refreshing) { _refreshAgain = true; return; }
        _refreshing = true;
        try
        {
            do
            {
                _refreshAgain = false;
                var lib = AppServices.Library;
                _data = new Data
                {
                    Accounts = await lib.AccountList(),
                    Folders = await lib.Folders(),
                    Counts = await lib.FolderCounts(),
                    Unmatched = (await lib.Unmatched()).Count,
                    Ignored = (await lib.Ignored()).Count,
                    Archives = (await lib.Archives()).Count,
                    Reminders = await AppServices.Plans.Reminders(),
                };
                RenderSources();
                RenderLibrary();
                RenderReminders();
                RenderScan();
            } while (_refreshAgain);
        }
        catch (Exception ex)
        {
            App.Log(ex);
        }
        finally
        {
            _refreshing = false;
        }
    }

    // ------------------------------------------------------------------ sources

    private void RenderSources()
    {
        _accountsHost.Children.Clear();
        var scan = AppServices.Scanner.State;
        // Network servers get their full panels (sign in again, remove) from NetworkServersSection.
        var accounts = _data.Accounts.OrderByDescending(a => Src.IsLocal(a.Email)).ToList();
        foreach (var account in accounts.Where(a => !Src.IsSmb(a.Email)))
        {
            var (panel, rows) = Panel();
            panel.Margin = new Thickness(0, 0, 0, 12);
            rows.Children.Add(AccountHeader(account));
            var folders = _data.Folders.Where(f => f.AccountEmail == account.Email).ToList();
            if (folders.Count == 0)
            {
                var none = Ui.Text("No library folders yet.", "Text.BodySmall", "Brush.TextMuted");
                none.Margin = new Thickness(16, 0, 16, 10);
                rows.Children.Add(none);
            }
            foreach (var f in folders) rows.Children.Add(FolderRow(f, scan));
            var add = Ui.Button("Add library folder", "Button.Ghost", () => _ = AddFolder(account.Email), "CreateNewFolder");
            add.HorizontalAlignment = HorizontalAlignment.Left;
            add.Margin = new Thickness(12, 4, 12, 12);
            rows.Children.Add(add);
            _accountsHost.Children.Add(panel);
        }
        if (accounts.All(a => !Src.IsLocal(a.Email)))
        {
            var use = Ui.Button("Use files on this PC", "Button.Secondary", () => _ = AddFolder(Src.Device), "Computer");
            use.HorizontalAlignment = HorizontalAlignment.Left;
            use.Margin = new Thickness(0, 0, 0, 4);
            _accountsHost.Children.Add(use);
        }
    }

    private static string AccountSubtitle(AccountEntity a) =>
        Src.IsLocal(a.Email) ? "Folders on this PC, external drives and USB"
        : Src.IsSmb(a.Email) ? $"Network server · {a.Email["smb://".Length..].TrimEnd('/')}"
        : a.Email;

    private FrameworkElement AccountHeader(AccountEntity a)
    {
        var grid = new Grid { Margin = new Thickness(16, 14, 12, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var avatar = Src.IsLocal(a.Email) ? Avatar("Computer", null)
            : Src.IsSmb(a.Email) ? Avatar("Dns", null)
            : Avatar(null, string.IsNullOrEmpty(a.DisplayName) ? a.Email[..1].ToUpperInvariant() : a.DisplayName[..1].ToUpperInvariant());
        grid.Children.Add(avatar);
        var texts = new StackPanel { Margin = new Thickness(14, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.OneLine(string.IsNullOrEmpty(a.DisplayName) ? a.Email : a.DisplayName, "Text.TitleSmall"));
        texts.Children.Add(Ui.OneLine(AccountSubtitle(a), "Text.BodySmall", "Brush.TextMuted"));
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        if (Src.IsLocal(a.Email))
        {
            // Google accounts and network servers are removed in their own sections (they also forget tokens and passwords).
            var remove = Ui.Button("Remove", "Button.TextMuted", () => RemoveDevice(a));
            remove.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(remove, 2);
            grid.Children.Add(remove);
        }
        return grid;
    }

    private FrameworkElement FolderRow(LibraryFolderEntity f, ScanState scan)
    {
        var grid = new Grid { Margin = new Thickness(16, 6, 8, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = Ui.Icon(f.Type == LibraryType.MOVIES ? "Movie" : "LiveTv", 20);
        icon.Margin = new Thickness(0, 0, 14, 0);
        grid.Children.Add(icon);

        var count = _data.Counts.TryGetValue(f.Id, out var n) ? n : 0;
        var hasError = scan.FolderErrors.ContainsKey(f.Id);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.OneLine(f.Name, "Text.TitleSmall"));
        var line = Ui.Text(ScanText.Folder(f, count, scan), "Text.BodySmall", hasError ? "Brush.Danger" : "Brush.TextFaint");
        line.MaxHeight = 36;
        line.TextTrimming = TextTrimming.CharacterEllipsis;
        texts.Children.Add(line);
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        var pill = Pill(f.Type == LibraryType.MOVIES ? "Movies" : "TV");
        pill.Margin = new Thickness(10, 0, 4, 0);
        Grid.SetColumn(pill, 2);
        grid.Children.Add(pill);

        FrameworkElement scanControl;
        if (scan.Running && scan.CurrentFolderId == f.Id)
        {
            var sp = MakeSpinner(18);
            sp.Margin = new Thickness(8);
            scanControl = sp;
        }
        else
        {
            var b = Ui.IconButton("Refresh", "Scan this folder", () =>
            {
                Controls.Toast.Show($"Scanning \"{f.Name}\"");
                _ = AppServices.Scans.RunNow(new HashSet<long> { f.Id });
            });
            b.IsEnabled = !scan.Waiting(f.Id);
            scanControl = b;
        }
        Grid.SetColumn(scanControl, 3);
        grid.Children.Add(scanControl);

        var remove = Ui.IconButton("Close", "Remove folder", async () =>
        {
            try { await AppServices.Library.RemoveFolder(f.Id); }
            catch (Exception ex) { Controls.Toast.Show(ex.Message); }
        });
        Grid.SetColumn(remove, 4);
        grid.Children.Add(remove);
        return grid;
    }

    private async Task AddFolder(string account)
    {
        try
        {
            var picked = await FolderPickerDialog.PickLibraryFolder(Window.GetWindow(this), account);
            if (picked is not { } p) return;
            var id = await AppServices.Library.AddFolder(account, p.Id, p.Name, p.Type);
            if (id is not { } folderId)
            {
                Controls.Toast.Show($"\"{p.Name}\" is already in your library");
                return;
            }
            Controls.Toast.Show($"Added \"{p.Name}\" — scanning now");
            _ = AppServices.Scans.RunNow(new HashSet<long> { folderId });
        }
        catch (Exception ex)
        {
            Controls.Toast.Show(Src.IsLocal(account) ? "Couldn't open that folder" : ex.Message);
        }
    }

    private void RemoveDevice(AccountEntity a)
    {
        var name = string.IsNullOrEmpty(a.DisplayName) ? Src.DeviceDisplayName : a.DisplayName;
        if (!Confirm.Ask(Window.GetWindow(this), $"Remove {name}?",
                "Its folders will be removed from your library. Nothing is deleted from this PC.", "Remove", danger: true))
            return;
        _ = Task.Run(async () =>
        {
            try { await AppServices.Library.RemoveAccount(a.Email); }
            catch (Exception ex) { App.Log(ex); }
        });
    }

    // ------------------------------------------------------------------ library

    private Border BuildScanBlock()
    {
        var spinner = MakeSpinner(20);
        spinner.Margin = new Thickness(0, 2, 14, 0);
        spinner.VerticalAlignment = VerticalAlignment.Top;
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(spinner);
        var texts = new StackPanel();
        texts.Children.Add(_scanTitle);
        _scanStep.Margin = new Thickness(0, 2, 0, 0);
        texts.Children.Add(_scanStep);
        Grid.SetColumn(texts, 1);
        top.Children.Add(texts);
        var cancel = Ui.Button("Cancel", "Button.Text", () => AppServices.Scanner.Cancel());
        cancel.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(cancel, 2);
        top.Children.Add(cancel);

        var counts = new DockPanel();
        DockPanel.SetDock(_scanPercent, Dock.Right);
        counts.Children.Add(_scanPercent);
        counts.Children.Add(_scanCounts);

        var stack = new StackPanel { Margin = new Thickness(16, 14, 16, 14) };
        stack.Children.Add(top);
        stack.Children.Add(_scanBar);
        stack.Children.Add(counts);
        _scanPath.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(_scanPath);
        var footer = Ui.Text("Keeps going if you leave the app.", "Text.BodySmall", "Brush.TextFaint");
        footer.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(footer);
        return new Border { Child = stack };
    }

    private void RenderScan()
    {
        var s = AppServices.Scanner.State;
        if (s.Running)
        {
            _scanTitle.Text = ScanText.Title(s);
            _scanStep.Text = ScanText.Step(s);
            _scanCounts.Text = ScanText.Counts(s);
            if (s.Progress is { } p)
            {
                _scanBar.IsIndeterminate = false;
                _scanBar.BeginAnimation(RangeBase.ValueProperty,
                    new DoubleAnimation(p, TimeSpan.FromMilliseconds(400)) { EasingFunction = new QuadraticEase() });
                _scanPercent.Text = $"{(int)Math.Round(p * 100)}%";
            }
            else
            {
                _scanBar.BeginAnimation(RangeBase.ValueProperty, null);
                _scanBar.IsIndeterminate = true;
                _scanPercent.Text = "";
            }
            _scanPath.Text = s.CurrentPath;
            _scanPath.Visibility = s.ToMatch == 0 && s.CurrentPath != "" ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            _idleSubtitle.Text = ScanText.Idle(s, S.LastScanAt);
            _idleSubtitle.Visibility = Visibility.Visible;
        }
        var first = s.Running ? (UIElement)_scanBlock : _idleRow;
        if (_libraryRows.Children.Count == 0 || _libraryRows.Children[0] != first)
        {
            if (_libraryRows.Children.Count > 0 && (_libraryRows.Children[0] == _scanBlock || _libraryRows.Children[0] == _idleRow))
                _libraryRows.Children.RemoveAt(0);
            _libraryRows.Children.Insert(0, first);
        }
    }

    private void RenderLibrary()
    {
        // Keep the scan row (first); rebuild the rest.
        while (_libraryRows.Children.Count > 1) _libraryRows.Children.RemoveAt(1);
        if (_libraryRows.Children.Count == 0) RenderScan();
        var rest = new List<UIElement?>();
        if (_data.Unmatched > 0)
            rest.Add(Setting("Unmatched files", $"{_data.Unmatched} {(_data.Unmatched == 1 ? "file" : "files")} need identifying", "ErrorOutline",
                () => AppServices.Navigator.Navigate(new FixMatchRoute())).Row);
        if (_data.Ignored > 0)
            rest.Add(Setting("Ignored files", $"{_data.Ignored} kept out of your library", "RemoveDone",
                () => AppServices.Navigator.Navigate(new FixMatchRoute())).Row);
        rest.Add(Setting("ZIP archives", _data.Archives == 0 ? "None found in your library" : $"{_data.Archives} waiting to be extracted", "FolderZip",
            () => AppServices.Navigator.Navigate(new ArchivesRoute())).Row);
        foreach (var r in rest)
        {
            _libraryRows.Children.Add(InsetDivider());
            _libraryRows.Children.Add(r!);
        }
    }

    // ------------------------------------------------------------------ reminders

    private void RenderReminders()
    {
        _remindersRows.Children.Clear();
        var reminders = _data.Reminders;
        if (reminders.Count == 0)
        {
            _remindersRows.Children.Add(InsetDivider());
            _remindersRows.Children.Add(Note("No reminders. Use \"Remind me\" on a movie, show or episode."));
            return;
        }
        if (!ToastNotifier.CanPostNow())
        {
            _remindersRows.Children.Add(InsetDivider());
            var warn = Note("Notifications are off for Veltoret, so reminders can't appear. Turn them on in Windows Settings → System → Notifications.", "Brush.Danger");
            _remindersRows.Children.Add(warn);
            var open = Ui.Button("Open notification settings", "Button.Text", () => Ui.OpenUrl("ms-settings:notifications"));
            open.HorizontalAlignment = HorizontalAlignment.Left;
            open.Margin = new Thickness(8, -8, 0, 8);
            _remindersRows.Children.Add(open);
        }
        var now = DateTime.Now;
        foreach (var r in reminders.OrderBy(r => r.At))
        {
            _remindersRows.Children.Add(InsetDivider());
            var grid = new Grid { Margin = new Thickness(16, 10, 8, 10) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var bell = Ui.Icon("Notifications", 20);
            bell.Margin = new Thickness(0, 0, 14, 0);
            grid.Children.Add(bell);
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Ui.OneLine(r.Title, "Text.TitleSmall"));
            texts.Children.Add(Ui.Text(P.ReminderLabel(r.At, now), "Text.BodySmall", "Brush.TextMuted"));
            Grid.SetColumn(texts, 1);
            grid.Children.Add(texts);
            var id = r.Id;
            var cancel = Ui.IconButton("Close", "Cancel reminder", () => _ = AppServices.Plans.RemoveReminder(id));
            Grid.SetColumn(cancel, 2);
            grid.Children.Add(cancel);
            _remindersRows.Children.Add(grid);
        }
    }

    // ------------------------------------------------------------------ TMDB

    private FrameworkElement TmdbKeyPanel()
    {
        var stack = new StackPanel { Margin = new Thickness(16) };
        var help = "Paste your TMDB API key or API Read Access Token. Get one free at themoviedb.org → Settings → API.";
        if (string.IsNullOrWhiteSpace(S.TmdbKeyOverride) && !string.IsNullOrEmpty(BundledKeys.Tmdb))
            help += "\nCurrently using the key built into this copy of the app. Paste your own to replace it.";
        stack.Children.Add(Ui.Text(help, "Text.BodySmall", "Brush.TextMuted"));

        var label = Ui.Text("TMDB key", "Text.LabelMedium", "Brush.TextMuted");
        label.Margin = new Thickness(0, 14, 0, 6);
        stack.Children.Add(label);

        var hidden = new PasswordBox { Password = S.TmdbKeyOverride };
        Ui.Apply(hidden, "PasswordBox");
        ButtonAssist.SetPlaceholder(hidden, "TMDB key");
        if (Icon.Get("Key") is { } keyIcon) ButtonAssist.SetIcon(hidden, keyIcon);
        var shown = new TextBox { Text = S.TmdbKeyOverride, Visibility = Visibility.Collapsed };
        Ui.Apply(shown, "TextBox");
        ButtonAssist.SetPlaceholder(shown, "TMDB key");
        if (Icon.Get("Key") is { } keyIcon2) ButtonAssist.SetIcon(shown, keyIcon2);

        var fieldGrid = new Grid();
        fieldGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fieldGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fieldGrid.Children.Add(hidden);
        fieldGrid.Children.Add(shown);
        Button? eye = null;
        eye = Ui.IconButton("Visibility", "Show key", () =>
        {
            var show = shown.Visibility != Visibility.Visible;
            if (show) shown.Text = hidden.Password; else hidden.Password = shown.Text;
            shown.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            hidden.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
            eye!.Content = Ui.Icon(show ? "VisibilityOff" : "Visibility", 18, "Brush.TextMuted");
            eye.ToolTip = show ? "Hide key" : "Show key";
        }, 40);
        eye.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(eye, 1);
        fieldGrid.Children.Add(eye);
        stack.Children.Add(fieldGrid);

        string Text() => shown.Visibility == Visibility.Visible ? shown.Text : hidden.Password;
        var save = Ui.Button("Save key", "Button.Primary", () => { });
        save.HorizontalAlignment = HorizontalAlignment.Left;
        save.Margin = new Thickness(0, 12, 0, 0);
        void Update() => save.IsEnabled = Text() != S.TmdbKeyOverride;
        hidden.PasswordChanged += (_, _) => Update();
        shown.TextChanged += (_, _) => Update();
        Update();
        save.Click += async (_, _) =>
        {
            var key = Text().Trim();
            Save(s => s with { TmdbKeyOverride = key });
            hidden.Password = key;
            shown.Text = key;
            Update();
            ButtonAssist.SetIsLoading(save, true);
            try
            {
                await AppServices.Tmdb.ValidateKey();
                Controls.Toast.Show("TMDB key saved");
                _ = AppServices.Scans.RunNow();
            }
            catch (Exception ex)
            {
                Controls.Toast.Show($"TMDB rejected this key: {ex.Message}");
            }
            finally
            {
                ButtonAssist.SetIsLoading(save, false);
            }
        };
        stack.Children.Add(save);

        var (panel, rows) = Panel();
        rows.Children.Add(stack);
        return panel;
    }

    // ------------------------------------------------------------------ about

    private FrameworkElement AboutPanel()
    {
        var version = Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                      ?? Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.0.0";
        var plus = version.IndexOf('+');
        if (plus > 0) version = version[..plus];

        void Link(string url)
        {
            if (!Ui.OpenUrl(url)) Controls.Toast.Show($"No browser to open {url}");
        }

        var (panel, rows) = Panel();
        AddRows(rows, new UIElement?[]
        {
            Setting("Veltoret", $"Version {version} · open source · Developed by PNT Apps", null, null).Row,
            Setting("Website", "pntapps.com", "OpenInNew", () => Link("https://www.pntapps.com")).Row,
            Setting("About us", "Who makes Veltoret", "Info", () => Link("https://www.pntapps.com/about")).Row,
            Setting("Privacy policy", "What happens to your data", "Lock", () => Link("https://www.pntapps.com/privacy")).Row,
            Setting("License", "GNU General Public License v3.0", "Info", () => Link("https://www.gnu.org/licenses/gpl-3.0.html")).Row,
            Setting("Source code", "github.com/pntapps/Veltoret", "OpenInNew", () => Link("https://github.com/pntapps/Veltoret")).Row,
            Setting("Third-party notices", "Libraries and fonts Veltoret uses", "Info", ShowNotices).Row,
        });
        if (Host("Veltoret.App.Controls.TmdbAttribution") is { } tmdb)
        {
            tmdb.Margin = new Thickness(16, 14, 16, 16);
            rows.Children.Add(InsetDivider());
            rows.Children.Add(tmdb);
        }
        else
        {
            rows.Children.Add(InsetDivider());
            rows.Children.Add(Note("This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."));
        }
        return panel;
    }

    private void ShowNotices()
    {
        var notices = new (string Name, string License)[]
        {
            ("LibVLC (VideoLAN)", "GNU LGPL 2.1 or later"),
            ("LibVLCSharp", "GNU LGPL 2.1 or later"),
            ("SMBLibrary", "GNU LGPL 3.0"),
            ("Fraunces and Inter fonts", "SIL Open Font License 1.1"),
            ("SQLite", "Public domain"),
            ("Microsoft.Data.Sqlite, .NET", "MIT"),
            ("Dapper", "Apache 2.0"),
            ("CommunityToolkit.Mvvm, Windows Community Toolkit Notifications", "MIT"),
            ("SharpCompress", "MIT"),
            ("Google.Protobuf", "BSD 3-Clause"),
            ("Makaretu.Dns.Multicast", "MIT"),
            ("TMDB", "Metadata and images from The Movie Database (themoviedb.org)"),
        };
        var stack = new StackPanel { Width = 460 };
        foreach (var (name, license) in notices)
        {
            var item = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
            item.Children.Add(Ui.Text(name, "Text.TitleSmall"));
            item.Children.Add(Ui.Text(license, "Text.BodySmall", "Brush.TextMuted"));
            stack.Children.Add(item);
        }
        stack.Children.Add(Ui.Text("Veltoret is free software under the GNU GPL v3.0. LibVLC and SMBLibrary are used as separate, replaceable libraries under the LGPL.",
            "Text.BodySmall", "Brush.TextFaint"));
        DialogWindow.Show(Window.GetWindow(this), "Third-party notices",
            new ScrollViewer { Content = stack, MaxHeight = 460, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            DialogButton.Ok("Close"));
    }
}
