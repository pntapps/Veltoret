using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Drive;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;
using static Veltoret.App.Pages.Files.FileUi;
using VIcon = Veltoret.App.Controls.Icon;

namespace Veltoret.App.Pages.Files;

public enum FileSort { Name, LastModified, Size }

/// <summary>
/// The file manager (Android: FilesScreen + FilesViewModel) for every source: Google Drive (My Drive / Shared with
/// me), This PC and network servers. Browse with breadcrumbs, search, sort, multi-select, rename, move, new
/// folder, delete (Drive: trash or permanently), upload to Drive, play videos, extract ZIPs, and set library folders.
/// Back (Esc / Alt+Left / mouse back): clears the selection, closes search, then goes up a folder.
/// </summary>
public sealed class FilesPage : UserControl
{
    private sealed record Crumb(string Id, string Name);

    /// <summary>One virtualized row of the adaptive grid (min column width 360).</summary>
    private sealed record RowModel(FilesPage Page, IReadOnlyList<StorageItem> Items, int Columns);

    private const double MinColumnWidth = 360;

    // ---- state (FilesState) ----
    private List<AccountEntity> _accounts = new();
    private string? _account;
    private bool _sharedRoot;
    private List<Crumb> _stack = new();
    private List<StorageItem> _items = new();
    private bool _loading = true;
    private string? _error;
    private bool _errorNeedsSignIn;
    private FileSort _sort = FileSort.Name;
    private readonly HashSet<string> _selection = new();
    private string? _anchor;
    private string? _searchQuery;
    private StorageSpace? _space;
    private string? _spaceKey;
    private Dictionary<string, LibraryType> _libraryFolders = new();
    private CancellationTokenSource? _loadCts;
    private bool _online = true;
    private int _columns = 1;
    private readonly string? _initialAccount;
    private readonly string? _initialFolder;

    // ---- views ----
    private readonly ContentControl _header = new();
    private readonly Border _searchRow = new() { Margin = new Thickness(0, 14, 0, 0) };
    private readonly TextBox _searchBox;
    private readonly StackPanel _chipsRow = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0) };
    private readonly WrapPanel _crumbsRow = new() { Margin = new Thickness(-8, 10, 0, 0) };
    private readonly StackPanel _spaceRow = new() { Margin = new Thickness(0, 8, 0, 4), MaxWidth = 480, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ItemsControl _list;
    private readonly ContentControl _state = new();
    private readonly StackPanel _transfers = new() { Width = 300, Margin = new Thickness(0, 0, 0, 14) };
    private readonly Button _fab;
    private readonly DispatcherTimer _searchDebounce = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private readonly DispatcherTimer _transferThrottle = new() { Interval = TimeSpan.FromMilliseconds(250) };

    static FilesPage()
    {
        // The shell handles Back in Preview handlers on the window. Class handlers run before those, so the Files
        // page gets the first say: clear the selection, close search, go up a folder; only then leave the page.
        EventManager.RegisterClassHandler(typeof(Window), Keyboard.PreviewKeyDownEvent, new KeyEventHandler(OnWindowPreviewKey));
        EventManager.RegisterClassHandler(typeof(Window), Mouse.PreviewMouseDownEvent, new MouseButtonEventHandler(OnWindowPreviewMouse));
    }

    private static FilesPage? ShownPage(object sender) =>
        sender is Window w && w == Application.Current?.MainWindow && AppServices.Navigator?.Current?.Page is FilesPage { IsLoaded: true } page
            ? page
            : null;

    private static void OnWindowPreviewKey(object sender, KeyEventArgs e)
    {
        if (e.Handled || ShownPage(sender) is not { } page) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var inText = Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase or PasswordBox;
        var back = (key == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt) || key == Key.BrowserBack
                   || (key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None && (!inText || Keyboard.FocusedElement == page._searchBox))
                   || (key == Key.Back && Keyboard.Modifiers == ModifierKeys.None && !inText);
        if (back && page.HandleBack()) e.Handled = true;
        else if (key == Key.F && Keyboard.Modifiers == ModifierKeys.Control && page._account != null)
        {
            // In Files, Ctrl+F searches the source (the Drive or this folder) rather than the library.
            page.SetSearch(page._searchQuery ?? "");
            e.Handled = true;
        }
    }

    private static void OnWindowPreviewMouse(object sender, MouseButtonEventArgs e)
    {
        if (e.Handled || e.ChangedButton != MouseButton.XButton1 || ShownPage(sender) is not { } page) return;
        if (page.HandleBack()) e.Handled = true;
    }

    public FilesPage(string? account = null, string? folderId = null)
    {
        _initialAccount = account;
        _initialFolder = folderId;
        Focusable = true;
        SetResourceReference(BackgroundProperty, "Brush.Background");
        FontFamily = (FontFamily)Application.Current.FindResource("Font.Sans");

        _searchBox = new TextBox { Style = FileUi.Style("TextBox"), MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
        _searchBox.TextChanged += (_, _) =>
        {
            if (_searchQuery == null) return;
            _searchQuery = _searchBox.Text;
            _searchDebounce.Stop();
            _searchDebounce.Start();
        };
        _searchBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { SetSearch(null); e.Handled = true; }
        };
        _searchRow.Child = _searchBox;
        _searchDebounce.Tick += (_, _) =>
        {
            _searchDebounce.Stop();
            if (_searchQuery == null || _searchQuery.Trim().Length >= 2) _ = Load();
        };
        _transferThrottle.Tick += (_, _) => { _transferThrottle.Stop(); RenderTransfers(); };

        _list = BuildList();
        _list.SizeChanged += (_, e) =>
        {
            var cols = Math.Max(1, (int)((e.NewSize.Width - 8) / MinColumnWidth));
            if (cols != _columns) { _columns = cols; RenderItems(); }
        };

        var top = new StackPanel();
        top.Children.Add(_header);
        top.Children.Add(_searchRow);
        top.Children.Add(_chipsRow);
        top.Children.Add(_crumbsRow);
        top.Children.Add(_spaceRow);

        var content = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        content.Children.Add(_list);
        content.Children.Add(_state);

        var main = new DockPanel { Margin = new Thickness(32, 24, 24, 0) };
        DockPanel.SetDock(top, Dock.Top);
        main.Children.Add(top);
        main.Children.Add(content);

        _fab = new Button
        {
            Style = FileUi.Style("Button.Primary"),
            Width = 58,
            Height = 58,
            Padding = new Thickness(0),
            ToolTip = "Add",
            HorizontalAlignment = HorizontalAlignment.Right,
            Content = IconOf(Geo("Add"), 26, Brush("OnAmber")),
            HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        System.Windows.Automation.AutomationProperties.SetName(_fab, "Add");
        _fab.Click += (_, _) => ShowAddMenu();
        _fab.Loaded += (_, _) => RoundFab();

        var overlay = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 32, 28) };
        overlay.Children.Add(_transfers);
        overlay.Children.Add(_fab);

        var root = new Grid();
        root.Children.Add(main);
        root.Children.Add(overlay);
        Content = root;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        KeyDown += OnKey;
    }

    private void RoundFab()
    {
        // Android: 58×58, corner 18 (the shared primary style uses corner 12; round the template's borders a bit more).
        foreach (var b in FindVisualChildren<Border>(_fab)) b.CornerRadius = new CornerRadius(18);
    }

    private static IEnumerable<T> FindVisualChildren<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T t) yield return t;
            foreach (var c in FindVisualChildren<T>(child)) yield return c;
        }
    }

    private Window? Owner => Window.GetWindow(this);

    // ---- lifecycle -----------------------------------------------------------------------------------------

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Db.Changed += OnDbChanged;
        AppServices.Transfers.JobChanged += OnJobChanged;
        AppServices.Transfers.JobRemoved += OnJobRemoved;
        if (AppServices.Connectivity != null) AppServices.Connectivity.OnlineChanged += OnOnlineChanged;
        _online = AppServices.Connectivity?.IsOnline ?? true;
        RenderTransfers();
        if (_account == null) await LoadAccounts(initial: true);
        else Render();
        Focus();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Db.Changed -= OnDbChanged;
        AppServices.Transfers.JobChanged -= OnJobChanged;
        AppServices.Transfers.JobRemoved -= OnJobRemoved;
        if (AppServices.Connectivity != null) AppServices.Connectivity.OnlineChanged -= OnOnlineChanged;
    }

    private void OnDbChanged(IReadOnlySet<string> tables)
    {
        if (tables.Contains("accounts")) Dispatcher.InvokeAsync(async () => await LoadAccounts(initial: false));
        else if (tables.Contains("library_folders")) Dispatcher.InvokeAsync(async () => { await LoadLibraryFolders(); RenderItems(); });
    }

    private void OnOnlineChanged(bool online) => Dispatcher.InvokeAsync(() =>
    {
        var was = _online;
        _online = online;
        if (_account == null) return;
        if (!was && online && !Accounts.IsLocal(_account)) _ = Load(refresh: true);
        else Render();
    });

    private void OnJobRemoved(string id) => Dispatcher.InvokeAsync(() => _transferThrottle.Start());

    private void OnJobChanged(TransferJob job) => Dispatcher.InvokeAsync(() =>
    {
        if (!_transferThrottle.IsEnabled) _transferThrottle.Start();
        if (job.State != TransferState.Succeeded || job.Account != _account) return;
        // Show the new files: an upload into the open folder, or any finished extraction.
        if (job.Kind == TransferKind.Extract || job.ParentId == Current?.Id) _ = Load(refresh: true);
    });

    private async Task LoadAccounts(bool initial)
    {
        try { _accounts = await AppServices.AccountDao.Accounts(); }
        catch (Exception ex) { App.Log(ex); }
        if (initial && _initialAccount != null && _accounts.Any(a => a.Email == _initialAccount))
        {
            SelectAccount(_initialAccount, _initialFolder);
            return;
        }
        if (_account == null || _accounts.All(a => a.Email != _account))
        {
            var first = _accounts.FirstOrDefault();
            if (first != null) SelectAccount(first.Email);
            else
            {
                _account = null;
                _loading = false;
                Render();
            }
            return;
        }
        Render();
    }

    private async Task LoadLibraryFolders()
    {
        try
        {
            var folders = await AppServices.AccountDao.Folders();
            _libraryFolders = folders.Where(f => f.AccountEmail == _account)
                .GroupBy(f => f.DriveFolderId).ToDictionary(g => g.Key, g => g.First().Type);
        }
        catch (Exception ex) { App.Log(ex); }
    }

    // ---- navigation (FilesViewModel) ---------------------------------------------------------------------

    private Crumb? Current => _stack.Count > 0 ? _stack[^1] : null;
    private bool AtSharedRoot => _sharedRoot && _stack.Count == 1;
    private bool Selecting => _selection.Count > 0;
    private bool IsDrive => Accounts.IsDrive(_account);
    private bool IsLocal => Accounts.IsLocal(_account);
    private bool IsSmb => Accounts.IsSmb(_account);
    private bool Permanent => IsLocal || IsSmb;
    private bool Movable => !(Permanent && _stack.Count == 1);
    private bool OfflineHere => !_online && !IsLocal;
    private AccountEntity? CurrentAccount => _accounts.FirstOrDefault(a => a.Email == _account);
    private string? ServerName => IsSmb ? CurrentAccount is { } a ? AccountName(a) : null : null;

    private void SelectAccount(string email, string? folderId = null)
    {
        _account = email;
        _sharedRoot = false;
        _selection.Clear();
        _searchQuery = null;
        _searchBox.Text = "";
        _space = null;
        _spaceKey = null;
        _items = new();
        _error = null;
        string rootId, rootName;
        try
        {
            rootId = AppServices.Storage.RootId(email);
            rootName = AppServices.Storage.RootName(email);
        }
        catch (Exception)
        {
            rootId = DriveFileSource.RootFolder;
            rootName = email;
        }
        _stack = new List<Crumb> { new(rootId, rootName) };
        if (!string.IsNullOrEmpty(folderId) && folderId != rootId)
            _stack.Add(new Crumb(folderId, Accounts.IsLocal(email) ? Path.GetFileName(folderId.TrimEnd('\\')) is { Length: > 0 } n ? n : folderId : "Folder"));
        _ = LoadLibraryFolders().ContinueWith(_ => Dispatcher.InvokeAsync(RenderItems));
        _ = Load();
    }

    private void SetSharedRoot(bool shared)
    {
        if (_sharedRoot == shared && _stack.Count == 1) return;
        _sharedRoot = shared;
        _stack = new List<Crumb> { shared ? new(DriveFileSource.SharedRoot, "Shared with me") : new(DriveFileSource.RootFolder, "My Drive") };
        _selection.Clear();
        CloseSearchSilently();
        _ = Load();
    }

    private void Open(StorageItem folder)
    {
        _stack.Add(new Crumb(folder.Id, folder.Name));
        _selection.Clear();
        CloseSearchSilently();
        _ = Load();
    }

    private void GoTo(int index)
    {
        if (index >= _stack.Count - 1) return;
        _stack.RemoveRange(index + 1, _stack.Count - index - 1);
        _selection.Clear();
        CloseSearchSilently();
        _ = Load();
    }

    /// <summary>Selection → clear; search open → close; deeper than the root → up one level.</summary>
    public bool HandleBack()
    {
        if (Selecting)
        {
            _selection.Clear();
            Render();
            return true;
        }
        if (_searchQuery != null)
        {
            SetSearch(null);
            return true;
        }
        if (_stack.Count > 1)
        {
            GoTo(_stack.Count - 2);
            return true;
        }
        return false;
    }

    private void CloseSearchSilently()
    {
        _searchQuery = null;
        _searchBox.Text = "";
    }

    private void SetSearch(string? q)
    {
        _searchQuery = q;
        _searchDebounce.Stop();
        if (q == null)
        {
            _searchBox.Text = "";
            _ = Load();
            Focus();
        }
        else
        {
            _searchBox.Text = q;
            Render();
            Dispatcher.InvokeAsync(() => { _searchBox.Focus(); _searchBox.SelectAll(); }, DispatcherPriority.Input);
        }
    }

    private async Task Load(bool refresh = false)
    {
        if (_account == null || Current == null) return;
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        var account = _account;
        var folder = Current;
        _loading = !refresh || _items.Count == 0;
        _error = null;
        Render();
        _ = RefreshSpace(refresh);

        if (OfflineHere)
        {
            _loading = false;
            _items = new();
            Render();
            return;
        }
        try
        {
            List<StorageItem> items;
            var q = _searchQuery?.Trim();
            if (q is { Length: >= 2 }) items = await AppServices.Storage.Search(account, q, folder.Id, cts.Token);
            else if (AtSharedRoot) items = await AppServices.Storage.List(account, DriveFileSource.SharedRoot, cts.Token);
            else items = await AppServices.Storage.List(account, folder.Id, cts.Token);
            if (cts.IsCancellationRequested || account != _account) return;
            _items = items.Where(IsUseful).ToList();
            _selection.IntersectWith(_items.Select(i => i.Id));
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            _items = new();
            _error = string.IsNullOrWhiteSpace(e.Message) ? "Couldn't load this folder" : e.Message;
            _errorNeedsSignIn = e is Core.Auth.AuthRequiredException;
        }
        _loading = false;
        Render();
    }

    private async Task RefreshSpace(bool force)
    {
        if (_account == null || Current == null) return;
        var account = _account;
        string? key;
        try { key = AppServices.Storage.SpaceKey(account, Current.Id); }
        catch (Exception) { key = null; }
        if (key == _spaceKey && !force && _space != null) return;
        if (key != _spaceKey) _space = null;
        _spaceKey = key;
        RenderSpace();
        if (key == null || OfflineHere) return;
        try
        {
            var space = await AppServices.Storage.Space(account, Current.Id);
            if (account != _account || key != _spaceKey) return;
            _space = space;
        }
        catch (Exception)
        {
            if (account == _account && key == _spaceKey) _space = null;
        }
        RenderSpace();
    }

    private List<StorageItem> Sorted()
    {
        IEnumerable<StorageItem> Order(IEnumerable<StorageItem> xs) => _sort switch
        {
            FileSort.LastModified => xs.OrderByDescending(i => i.ModifiedTime ?? "", StringComparer.Ordinal),
            FileSort.Size => xs.OrderByDescending(i => i.SizeBytes),
            _ => xs.OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase),
        };
        return Order(_items.Where(i => i.IsFolder)).Concat(Order(_items.Where(i => !i.IsFolder))).ToList();
    }

    // ---- rendering -----------------------------------------------------------------------------------------

    private void Render()
    {
        RenderHeader();
        var searchOpen = _searchQuery != null;
        _searchRow.Visibility = searchOpen && _account != null ? Visibility.Visible : Visibility.Collapsed;
        ButtonAssist.SetPlaceholder(_searchBox, IsDrive ? "Search this Drive" : "Search this folder");

        _chipsRow.Children.Clear();
        _chipsRow.Visibility = !searchOpen && IsDrive && _online ? Visibility.Visible : Visibility.Collapsed;
        if (_chipsRow.Visibility == Visibility.Visible)
        {
            _chipsRow.Children.Add(Chip("My Drive", !_sharedRoot, () => SetSharedRoot(false)));
            _chipsRow.Children.Add(Chip("Shared with me", _sharedRoot, () => SetSharedRoot(true)));
        }
        RenderCrumbs(!searchOpen && _account != null && !OfflineHere);
        RenderSpace();
        RenderItems();
        RenderState();
        _fab.Visibility = _account != null && !Selecting && !AtSharedRoot && !OfflineHere && !(IsSmb && _stack.Count == 1)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void RenderHeader()
    {
        if (Selecting)
        {
            var bar = new DockPanel { Height = 76 };
            var close = FileUi.IconButton(Geo("Close"), "Cancel selection", () => { _selection.Clear(); Render(); });
            close.Margin = new Thickness(0, 0, 14, 0);
            bar.Children.Add(close);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            DockPanel.SetDock(actions, Dock.Right);
            var move = FileUi.IconButton(Icons.DriveFileMove, "Move", MoveSelection);
            move.Margin = new Thickness(8, 0, 0, 0);
            actions.Children.Add(move);
            var del = FileUi.IconButton(Icons.Delete, IsDrive ? "Move to trash" : "Delete", TrashSelection);
            del.Foreground = Brush("Danger");
            del.Margin = new Thickness(8, 0, 0, 0);
            actions.Children.Add(del);
            var selected = SelectedItems();
            if (IsDrive && selected.Count > 0 && selected.All(i => i.CanDelete))
            {
                var forever = FileUi.IconButton(Icons.DeleteForever, "Delete permanently", DeleteSelectionForever);
                forever.Foreground = Brush("Danger");
                forever.Margin = new Thickness(8, 0, 0, 0);
                actions.Children.Add(forever);
            }
            if (!Movable) move.IsEnabled = del.IsEnabled = false;
            bar.Children.Add(actions);
            var count = Text($"{_selection.Count} selected", "Text.HeadlineSmall", wrap: false);
            count.VerticalAlignment = VerticalAlignment.Center;
            bar.Children.Add(count);
            _header.Content = bar;
            return;
        }

        var header = new DockPanel { MinHeight = 76 };
        var tools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(tools, Dock.Right);
        if (_account != null)
        {
            var search = FileUi.IconButton(Geo("Search"), IsDrive ? "Search Drive" : "Search this folder",
                () => SetSearch(_searchQuery == null ? "" : null));
            if (_searchQuery != null) search.Foreground = Brush("Amber");
            var sort = FileUi.IconButton(Geo("Sort"), "Sort", () => { });
            sort.Click += (_, _) => ShowSortMenu(sort);
            var refresh = FileUi.IconButton(Geo("Refresh"), "Refresh (F5)", () => _ = Load(refresh: true));
            sort.Margin = refresh.Margin = new Thickness(8, 0, 0, 0);
            tools.Children.Add(search);
            tools.Children.Add(sort);
            tools.Children.Add(refresh);
        }
        header.Children.Add(tools);

        var titles = new StackPanel();
        titles.Children.Add(Text("Files", "Text.DisplaySmall", wrap: false));
        if (CurrentAccount is { } acc)
        {
            var switcher = new Button
            {
                Style = FileUi.Style("Button.Text"),
                Content = SwitcherName(acc) + "  ▾",
                Foreground = Brush("TextMuted"),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(-8, 2, 0, 0),
                ToolTip = "Switch source",
            };
            switcher.Click += (_, _) => ShowAccountMenu(switcher);
            titles.Children.Add(switcher);
        }
        header.Children.Add(titles);
        _header.Content = header;
    }

    private void RenderCrumbs(bool visible)
    {
        _crumbsRow.Children.Clear();
        _crumbsRow.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        for (var i = 0; i < _stack.Count; i++)
        {
            var index = i;
            if (i > 0) _crumbsRow.Children.Add(IconOf(Geo("ChevronRight"), 18, Brush("TextFaint")));
            var last = i == _stack.Count - 1;
            var b = new Button
            {
                Content = new TextBlock { Text = _stack[i].Name, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 },
                Style = FileUi.Style(last ? "Button.Text" : "Button.TextMuted"),
                Foreground = Brush(last ? "Text" : "TextMuted"),
            };
            b.Click += (_, _) => GoTo(index);
            _crumbsRow.Children.Add(b);
        }
    }

    private void RenderSpace()
    {
        _spaceRow.Children.Clear();
        var visible = _space != null && _searchQuery == null && !OfflineHere && _account != null;
        _spaceRow.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        var space = _space!;
        _spaceRow.Children.Add(Text(DriveFormat.StorageSummary(space), "Text.BodySmall", Brush("TextMuted")));
        if (DriveFormat.StorageFraction(space) is { } fraction)
        {
            var track = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Brush("Outline"), Margin = new Thickness(0, 6, 0, 0) };
            var fill = new Border
            {
                Height = 4,
                CornerRadius = new CornerRadius(2),
                Background = DriveFormat.StorageAlmostFull(space) ? Brush("Danger") : Brush("Amber"),
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            track.Child = fill;
            track.SizeChanged += (_, e) => fill.Width = Math.Max(0, e.NewSize.Width * fraction);
            _spaceRow.Children.Add(track);
        }
    }

    private void RenderItems()
    {
        if (_loading || _error != null || OfflineHere || _account == null)
        {
            _list.ItemsSource = null;
            return;
        }
        var sorted = Sorted();
        var rows = new List<RowModel>();
        for (var i = 0; i < sorted.Count; i += _columns)
            rows.Add(new RowModel(this, sorted.Skip(i).Take(_columns).ToList(), _columns));
        _list.ItemsSource = rows;
    }

    private void RenderState()
    {
        _state.Content = null;
        if (_account == null)
        {
            _state.Content = StateView("Nothing connected yet",
                "Add a folder from this PC or an external drive. To browse Google Drive, connect an account in Settings.",
                "Add a folder from this PC", () => _ = AddLocalFolder());
            return;
        }
        if (OfflineHere)
        {
            _state.Content = StateView("You're offline",
                IsSmb ? "Network servers need this PC to be on their network. Folders on this PC still work."
                      : "Google Drive needs an internet connection. Folders on this PC still work.",
                "Show This PC", () => _ = ShowThisPc());
            return;
        }
        if (_loading)
        {
            _state.Content = new Spinner { Width = 36, Height = 36, Thickness = 3, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            return;
        }
        if (_error != null)
        {
            var title = IsLocal ? "Couldn't open this folder" : IsSmb ? $"Couldn't reach {ServerName ?? "the server"}" : "Couldn't reach Drive";
            if (_errorNeedsSignIn && IsDrive) _state.Content = StateView(title, _error, "Reconnect", () => _ = Reconnect());
            else _state.Content = StateView(title, _error, "Retry", () => _ = Load());
            return;
        }
        if (_items.Count == 0)
        {
            if (_searchQuery is { } q && q.Trim().Length >= 2)
                _state.Content = StateView("Nothing found", $"No folders, videos, subtitles or ZIPs match \"{q.Trim()}\".", null, null);
            else if (IsLocal && _stack.Count == 1)
                _state.Content = StateView("No folders yet", "Pick a folder on this PC or an external drive. Veltoret only scans the folders you choose.",
                    "Add a folder", () => _ = AddLocalFolder());
            else if (_searchQuery == null)
                _state.Content = StateView("This folder is empty",
                    IsDrive ? "Upload files or create a folder with the + button." : "Create a folder with the + button.", null, null);
        }
    }

    private static FrameworkElement StateView(string title, string text, string? action, Action? onAction)
    {
        var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460, Margin = new Thickness(24, 24, 24, 120) };
        var t = Text(title, "Text.HeadlineSmall");
        t.TextAlignment = TextAlignment.Center;
        var m = Text(text, "Text.BodyMedium", Brush("TextMuted"));
        m.TextAlignment = TextAlignment.Center;
        m.Margin = new Thickness(0, 8, 0, 0);
        s.Children.Add(t);
        s.Children.Add(m);
        if (action != null && onAction != null)
        {
            var b = FileUi.Button(action, "Button.Secondary", click: onAction);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            b.Margin = new Thickness(0, 18, 0, 0);
            s.Children.Add(b);
        }
        return s;
    }

    private void RenderTransfers()
    {
        _transfers.Children.Clear();
        var jobs = AppServices.Transfers.Jobs.OrderBy(j => j.CreatedAt).ToList();
        var shown = jobs.Where(j => j.Kind == TransferKind.Extract && (j.IsActive || j.State == TransferState.Failed)).Take(2)
            .Concat(jobs.Where(j => j.Kind == TransferKind.Upload && (j.IsActive || j.State == TransferState.Failed)).Take(3));
        foreach (var j in shown)
        {
            var card = new TransferCard(j) { Margin = new Thickness(0, 0, 0, 8) };
            _transfers.Children.Add(card);
        }
        _transfers.Visibility = _transfers.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---- the list ------------------------------------------------------------------------------------------

    private ItemsControl BuildList()
    {
        var list = new ItemsControl { Focusable = false };
        var template = new DataTemplate(typeof(RowModel)) { VisualTree = new FrameworkElementFactory(typeof(RowHost)) };
        list.ItemTemplate = template;
        list.ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(VirtualizingStackPanel)));
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        VirtualizingPanel.SetScrollUnit(list, ScrollUnit.Pixel);
        ScrollViewer.SetCanContentScroll(list, true);
        var scroll = new FrameworkElementFactory(typeof(ScrollViewer));
        scroll.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Disabled);
        scroll.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        scroll.SetValue(ScrollViewer.CanContentScrollProperty, true);
        scroll.SetValue(FocusableProperty, false);
        var presenter = new FrameworkElementFactory(typeof(ItemsPresenter));
        presenter.SetValue(MarginProperty, new Thickness(0, 0, 8, 120)); // room for the + button
        scroll.AppendChild(presenter);
        list.Template = new ControlTemplate(typeof(ItemsControl)) { VisualTree = scroll };
        return list;
    }

    /// <summary>Builds one grid row from its <see cref="RowModel"/> when the virtualizing panel shows it.</summary>
    private sealed class RowHost : Grid
    {
        public RowHost()
        {
            DataContextChanged += (_, e) => Build(e.NewValue as RowModel);
        }

        private void Build(RowModel? model)
        {
            Children.Clear();
            ColumnDefinitions.Clear();
            if (model == null) return;
            for (var c = 0; c < model.Columns; c++) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (var c = 0; c < model.Items.Count; c++)
            {
                var cell = model.Page.Cell(model.Items[c]);
                SetColumn(cell, c);
                Children.Add(cell);
            }
        }
    }

    private FrameworkElement Cell(StorageItem item)
    {
        var selected = _selection.Contains(item.Id);
        var (icon, color) = Look(item);
        var cell = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(10, 8, 6, 8),
            Margin = new Thickness(0, 2, 8, 2),
            Background = selected ? Brush("AmberDim") : Brushes.Transparent,
            Cursor = Cursors.Hand,
            ToolTip = item.Name,
        };
        var row = new DockPanel();
        var tile = Tile(icon, color, selected);
        tile.Margin = new Thickness(0, 0, 14, 0);
        DockPanel.SetDock(tile, Dock.Left);
        row.Children.Add(tile);
        if (!Selecting)
        {
            var more = FileUi.IconButton(Geo("MoreVert"), "More", () => { }, "Button.IconFlat");
            more.Width = more.Height = 36;
            ButtonAssist.SetIconSize(more, 20);
            more.Click += (_, _) => ShowMenu(ItemMenu(item), more);
            DockPanel.SetDock(more, Dock.Right);
            row.Children.Add(more);
        }
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Text(item.Name, "Text.TitleSmall", wrap: false));
        var second = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
        if (item.IsFolder && _libraryFolders.TryGetValue(item.Id, out var type))
        {
            var pill = new Border { Style = FileUi.Style("Pill"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            pill.Child = Text(type == LibraryType.MOVIES ? "Movies library" : "TV library", "Text.LabelSmall", Brush("AmberSoft"), wrap: false);
            second.Children.Add(pill);
        }
        var meta = new List<string>();
        if (!item.IsFolder) meta.Add(DriveFormat.Bytes(item.SizeBytes));
        if (DriveFormat.DriveDate(item.ModifiedTime) is { } date) meta.Add(date);
        if (meta.Count > 0) second.Children.Add(Text(string.Join(" · ", meta), "Text.BodySmall", Brush("TextMuted"), wrap: false));
        texts.Children.Add(second);
        row.Children.Add(texts);
        cell.Child = row;

        cell.MouseEnter += (_, _) => { if (!_selection.Contains(item.Id)) cell.Background = Brush("Hover"); };
        cell.MouseLeave += (_, _) => { if (!_selection.Contains(item.Id)) cell.Background = Brushes.Transparent; };
        cell.MouseLeftButtonUp += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject d && IsInsideButton(d, cell)) return;
            e.Handled = true;
            OnItemClick(item);
        };
        cell.MouseRightButtonUp += (_, e) =>
        {
            e.Handled = true;
            if (Selecting) { Toggle(item); return; }
            var menu = ItemMenu(item);
            menu.PlacementTarget = cell;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            menu.IsOpen = true;
        };
        return cell;
    }

    private static bool IsInsideButton(DependencyObject d, DependencyObject stop)
    {
        for (var x = d; x != null && x != stop; x = VisualTreeHelper.GetParent(x))
            if (x is ButtonBase) return true;
        return false;
    }

    private void OnItemClick(StorageItem item)
    {
        var mods = Keyboard.Modifiers;
        if (mods.HasFlag(ModifierKeys.Shift) && _anchor != null)
        {
            var sorted = Sorted();
            var a = sorted.FindIndex(i => i.Id == _anchor);
            var b = sorted.FindIndex(i => i.Id == item.Id);
            if (a >= 0 && b >= 0)
            {
                foreach (var i in sorted.Skip(Math.Min(a, b)).Take(Math.Abs(a - b) + 1)) _selection.Add(i.Id);
                Render();
                return;
            }
        }
        if (Selecting || mods.HasFlag(ModifierKeys.Control))
        {
            Toggle(item);
            return;
        }
        Activate(item);
    }

    private void Toggle(StorageItem item)
    {
        if (!_selection.Remove(item.Id)) _selection.Add(item.Id);
        _anchor = item.Id;
        Render();
    }

    private void Activate(StorageItem item)
    {
        if (item.IsFolder) Open(item);
        else if (IsVideo(item)) Play(item);
        else if (IsZip(item) && IsDrive) Extract(item);
        else FileDialogs.Details(Owner, item);
    }

    private List<StorageItem> SelectedItems() => _items.Where(i => _selection.Contains(i.Id)).ToList();

    // ---- menus ---------------------------------------------------------------------------------------------

    private ContextMenu ItemMenu(StorageItem item)
    {
        var items = new List<MenuItem>();
        if (IsVideo(item)) items.Add(Item("Play", () => Play(item), Geo("Play")));
        if (item.IsFolder && !_libraryFolders.ContainsKey(item.Id))
        {
            items.Add(Item("Use as Movies library", () => _ = SetLibrary(item, LibraryType.MOVIES), Geo("Movie")));
            items.Add(Item("Use as TV library", () => _ = SetLibrary(item, LibraryType.SHOWS), Geo("LiveTv")));
        }
        if (item.CanRename) items.Add(Item("Rename", () => _ = Rename(item), Geo("Edit")));
        if (Movable) items.Add(Item("Move", () => _ = Move(new[] { item }), Icons.DriveFileMove));
        if (IsZip(item) && IsDrive) items.Add(Item("Extract to Drive", () => Extract(item), Icons.Unarchive));
        items.Add(Item("Details", () => FileDialogs.Details(Owner, item), Geo("Info")));
        if (item.CanTrash && Movable) items.Add(Item(IsDrive ? "Move to trash" : "Delete", () => _ = Trash(new[] { item }), Icons.Delete, danger: true));
        if (IsDrive && item.CanDelete && Movable) items.Add(Item("Delete permanently", () => _ = DeleteForever(new[] { item }), Icons.DeleteForever, danger: true));
        return Menu(items.ToArray());
    }

    private void ShowSortMenu(UIElement target)
    {
        MenuItem SortItem(string text, FileSort sort)
        {
            var m = Item(text, () => { _sort = sort; RenderItems(); });
            if (_sort == sort) m.Foreground = Brush("Amber");
            return m;
        }
        ShowMenu(Menu(SortItem("Name", FileSort.Name), SortItem("Last modified", FileSort.LastModified), SortItem("Size", FileSort.Size)), target);
    }

    private void ShowAccountMenu(UIElement target)
    {
        var menu = new ContextMenu { Style = FileUi.Style("ContextMenu") };
        foreach (var a in _accounts)
        {
            var email = a.Email;
            var row = new DockPanel { MinWidth = 280 };
            var avatar = Avatar(a, 32);
            avatar.Margin = new Thickness(0, 0, 12, 0);
            row.Children.Add(avatar);
            if (a.Email == _account)
            {
                var check = IconOf(Geo("CheckCircle"), 18, Brush("Amber"));
                check.Margin = new Thickness(12, 0, 0, 0);
                DockPanel.SetDock(check, Dock.Right);
                row.Children.Add(check);
            }
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Text(AccountName(a), "Text.TitleSmall", wrap: false));
            texts.Children.Add(Text(AccountSubtitle(a), "Text.BodySmall", Brush("TextMuted"), wrap: false));
            row.Children.Add(texts);
            var m = new MenuItem { Header = row, Style = FileUi.Style("MenuItem") };
            m.Click += (_, _) => { if (email != _account) SelectAccount(email); };
            menu.Items.Add(m);
        }
        if (_accounts.All(a => !Accounts.IsLocal(a.Email)))
            menu.Items.Add(Item("Files on this PC", () => _ = ShowThisPc(), Geo("Computer")));
        ShowMenu(menu, target);
    }

    private void ShowAddMenu()
    {
        var items = new List<MenuItem>();
        if (IsLocal && _stack.Count == 1) items.Add(Item("Add a folder from this PC", () => _ = AddLocalFolder(), Geo("Folder")));
        else items.Add(Item("New folder", () => _ = NewFolder(), Geo("CreateNewFolder")));
        if (IsDrive) items.Add(Item("Upload files", Upload, Icons.Upload));
        var menu = Menu(items.ToArray());
        menu.PlacementTarget = _fab;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        menu.IsOpen = true;
    }

    // ---- actions -------------------------------------------------------------------------------------------

    private void Play(StorageItem item)
    {
        if (_account == null) return;
        var account = _account;
        _ = Run(() => AppServices.Playback.PlayItem(account, item.Id, item.Name));
    }

    private void Extract(StorageItem item)
    {
        if (_account == null || Current == null) return;
        var parent = item.Parents.FirstOrDefault() ?? Current.Id;
        ExtractDialog.Show(Owner, _account, item.Id, item.Name, item.SizeBytes, parent);
        RenderTransfers();
    }

    private async Task ShowThisPc()
    {
        await Run(async () =>
        {
            await AppServices.Library.EnsureDeviceAccount();
            _accounts = await AppServices.AccountDao.Accounts();
            SelectAccount(Accounts.Device);
        });
    }

    /// <summary>Folder on this PC → "What's in …?" → add to the library and scan it.</summary>
    private async Task AddLocalFolder()
    {
        (string Id, string Name)? picked;
        try { picked = await FolderPickerDialog.Pick(Owner, Accounts.Device); }
        catch (Exception e) { Toast.Show(FileUi.Message(e, "Couldn't open that folder")); return; }
        if (picked == null) return;
        var type = FileDialogs.LibraryType(Owner, picked.Value.Name);
        await Run(async () =>
        {
            await AppServices.Library.EnsureDeviceAccount();
            if (type != null) await AddToLibrary(Accounts.Device, picked.Value.Id, picked.Value.Name, type.Value);
            if (_account != Accounts.Device)
            {
                _accounts = await AppServices.AccountDao.Accounts();
                SelectAccount(Accounts.Device);
            }
        });
    }

    private static async Task AddToLibrary(string account, string folderId, string name, LibraryType type)
    {
        var id = await AppServices.Library.AddFolder(account, folderId, name, type);
        Toast.Show($"{name} added to your {(type == LibraryType.MOVIES ? "Movies" : "TV Shows")} library");
        if (id != null) _ = AppServices.Scans.RunNow(new HashSet<long> { id.Value });
    }

    private Task SetLibrary(StorageItem folder, LibraryType type)
    {
        var account = _account!;
        return Run(async () =>
        {
            await AddToLibrary(account, folder.Id, folder.Name, type);
            await LoadLibraryFolders();
            RenderItems();
        });
    }

    private Task Rename(StorageItem item)
    {
        var name = FileDialogs.Rename(Owner, item);
        if (name == null || name == item.Name) return Task.CompletedTask;
        var account = _account!;
        return Mutate(async () =>
        {
            var newId = await AppServices.Storage.Rename(account, item.Id, name);
            if (newId == item.Id)
            {
                await AppServices.Scanner.OnFileRenamed(item.Id, newId, name);
                if (item.IsFolder) AppServices.Scans.RequestAutomatic();
            }
            else
            {
                await AppServices.Scanner.OnFilesRemoved(new[] { item.Id });
                AppServices.Scans.RequestAutomatic();
            }
        });
    }

    private Task NewFolder()
    {
        if (Current == null) return Task.CompletedTask;
        var name = FileDialogs.NewFolder(Owner);
        if (name == null) return Task.CompletedTask;
        var account = _account!;
        var parent = Current.Id;
        return Mutate(async () =>
        {
            await AppServices.Storage.CreateFolder(account, parent, name);
            Toast.Show("Folder created");
        });
    }

    private async Task Reconnect()
    {
        if (_account == null) return;
        if (await AccountsUi.ConnectGoogle.Run(Owner, _account) != null) await Load();
    }

    private void TrashSelection() => _ = Trash(SelectedItems());
    private void DeleteSelectionForever() => _ = DeleteForever(SelectedItems());
    private void MoveSelection() => _ = Move(SelectedItems());

    private static string Label(IReadOnlyList<StorageItem> items) => items.Count == 1 ? items[0].Name : $"{items.Count} items";

    private Task Trash(IReadOnlyList<StorageItem> items)
    {
        if (items.Count == 0 || _account == null) return Task.CompletedTask;
        var account = _account;
        if (!FileDialogs.Trash(Owner, account, Label(items), ServerName)) return Task.CompletedTask;
        return Mutate(async () =>
        {
            foreach (var i in items) await AppServices.Storage.Remove(account, i.Id);
            await AfterRemoved(items);
            Toast.Show(FileDialogs.DeletedMessage(account, items.Count, permanent: false));
        });
    }

    private Task DeleteForever(IReadOnlyList<StorageItem> items)
    {
        if (items.Count == 0 || _account == null) return Task.CompletedTask;
        var account = _account;
        if (!FileDialogs.DeleteForever(Owner, Label(items), items.Any(i => i.IsFolder))) return Task.CompletedTask;
        return Mutate(async () =>
        {
            foreach (var i in items) await AppServices.Storage.DeletePermanently(account, i.Id);
            await AfterRemoved(items);
            Toast.Show(FileDialogs.DeletedMessage(account, items.Count, permanent: true));
        });
    }

    private async Task AfterRemoved(IReadOnlyList<StorageItem> items)
    {
        await AppServices.Scanner.OnFilesRemoved(items.Select(i => i.Id).ToList());
        _selection.Clear();
        if (items.Any(i => i.IsFolder)) AppServices.Scans.RequestAutomatic();
    }

    private Task Move(IReadOnlyList<StorageItem> items)
    {
        if (items.Count == 0 || _account == null || Current == null) return Task.CompletedTask;
        var account = _account;
        var current = Current.Id;
        var target = MovePicker.Pick(Owner, account, items.Where(i => i.IsFolder).Select(i => i.Id).ToHashSet(), startShared: AtSharedRoot);
        if (target == null) return Task.CompletedTask;
        return Mutate(async () =>
        {
            foreach (var i in items)
                await AppServices.Storage.Move(account, i.Id, i.Parents.FirstOrDefault() ?? current, target.Value.Id);
            if (!Accounts.IsDrive(account)) await AppServices.Scanner.OnFilesRemoved(items.Select(i => i.Id).ToList());
            _selection.Clear();
            AppServices.Scans.RequestAutomatic();
            Toast.Show($"Moved to {target.Value.Name}");
        });
    }

    private void Upload()
    {
        if (_account == null || Current == null) return;
        if (AtSharedRoot)
        {
            Toast.Show("Open a folder first to upload into it");
            return;
        }
        var dlg = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Upload to Google Drive" };
        var ok = Owner != null ? dlg.ShowDialog(Owner) : dlg.ShowDialog();
        if (ok != true || dlg.FileNames.Length == 0) return;
        AppServices.Transfers.Upload(_account, Current.Id, dlg.FileNames);
        var n = dlg.FileNames.Length;
        Toast.Show(n == 1 ? "Uploading 1 file" : $"Uploading {n} files");
        RenderTransfers();
    }

    /// <summary>Runs a change, then refreshes the folder. Errors → snackbar.</summary>
    private async Task Mutate(Func<Task> change)
    {
        try { await change(); }
        catch (Exception e)
        {
            Toast.Show(FileUi.Message(e));
        }
        Render();
        await Load(refresh: true);
    }

    private static async Task Run(Func<Task> action)
    {
        try { await action(); }
        catch (Exception e) { Toast.Show(FileUi.Message(e)); }
    }

    // ---- keyboard ------------------------------------------------------------------------------------------

    private void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape || (key == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt) || key == Key.BrowserBack)
        {
            if (HandleBack()) e.Handled = true;
            return;
        }
        if (e.OriginalSource is TextBox) return;
        switch (key)
        {
            case Key.F5:
                _ = Load(refresh: true);
                e.Handled = true;
                break;
            case Key.A when Keyboard.Modifiers == ModifierKeys.Control && _items.Count > 0:
                foreach (var i in _items) _selection.Add(i.Id);
                Render();
                e.Handled = true;
                break;
            case Key.Delete when Selecting && Movable:
                if (Keyboard.Modifiers == ModifierKeys.Shift && IsDrive && SelectedItems().All(i => i.CanDelete)) DeleteSelectionForever();
                else TrashSelection();
                e.Handled = true;
                break;
            case Key.F2 when _selection.Count == 1:
                var item = SelectedItems().FirstOrDefault();
                if (item is { CanRename: true }) _ = Rename(item);
                e.Handled = true;
                break;
        }
    }
}
