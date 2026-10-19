using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Smb;
using Glyph = Veltoret.App.Controls.Icon;

namespace Veltoret.App.Network;

/// <summary>
/// "Add network server": servers found on the network (live), or an address typed or pasted the way File Explorer
/// takes it (\\192.168.0.10\Movies); a username and password or guest access. The details are checked by signing in
/// before anything is saved. Then the dialog offers the Movies / TV Shows folders on the server.
/// </summary>
public sealed class AddServerDialog : DialogWindow
{
    private readonly AddServerViewModel _vm = new();
    private readonly SmbServer? _editing;
    private string? _account;

    // Step 1
    private readonly TextBox _address = new();
    private readonly ToggleButton _userChip = new() { Content = "Username and password" };
    private readonly ToggleButton _guestChip = new() { Content = "Guest" };
    private readonly TextBox _username = new();
    private readonly PasswordBox _password = new();
    private readonly TextBox _passwordShown = new() { Visibility = Visibility.Collapsed };
    private readonly Button _reveal = new();
    private readonly StackPanel _loginFields = new();
    private readonly TextBlock _error = new();
    private readonly StackPanel _found = new();
    private readonly TextBlock _noneFound = new();
    private readonly StackPanel _scanState = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _scanAgain = new();
    private DialogButton _connect = null!;

    // Step 2
    private readonly StackPanel _added = new();

    private AddServerDialog(SmbServer? editing)
    {
        _editing = editing;
        DialogTitle = editing == null ? "Add network server" : $"Sign in to {editing.DisplayName}";
        BodyWidth = 560;
        Body = BuildLogin();
        _connect = new DialogButton("Connect", DialogButtonKind.Primary, ConnectClicked) { IsDefault = true };
        SetButtons(DialogButton.Cancel(), _connect);

        _vm.PropertyChanged += OnVmChanged;
        _vm.Found.CollectionChanged += (_, _) => RenderFound();
        Loaded += (_, _) =>
        {
            if (_editing == null) _vm.Scan();
            else _password.Focus();
        };
        Closed += (_, _) => _vm.CancelScan();
        if (editing != null)
        {
            _address.Text = editing.Host;
            _username.Text = editing.Domain.Length > 0 ? $"{editing.Domain}\\{editing.Username}" : editing.Username;
            SetGuest(editing.Guest);
        }
        else
        {
            SetGuest(false);
        }
        RenderFound();
        UpdateScanState();
    }

    /// <summary>Shows the dialog; returns the server's account id ("smb://host") once it's saved, else null.</summary>
    public static Task<string?> Show(Window? owner) => Show(owner, null);

    /// <summary>Signs in to a saved server again (new password or user), keeping its library folders.</summary>
    public static Task<string?> Show(Window? owner, SmbServer? editing)
    {
        var dialog = new AddServerDialog(editing);
        dialog.ShowModal(owner);
        return Task.FromResult(dialog._account);
    }

    // ---------------------------------------------------------------------------------------------
    // Step 1: find or type the server, sign in

    private FrameworkElement BuildLogin()
    {
        var root = new StackPanel();
        if (_editing == null)
        {
            root.Children.Add(Muted("Shared folders on a router, NAS or computer.", "Text.BodyMedium", bottom: 6));
            root.Children.Add(Muted(
                "Pick a server found on your network, or enter the address you'd use in File Explorer. " +
                "You can paste the full path to your movies folder, or just the server's address and pick the folder next.",
                "Text.BodyMedium", bottom: 16));

            var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8), LastChildFill = true };
            _scanAgain.Style = St("Button.Text");
            _scanAgain.Content = "Scan again";
            ButtonAssist.SetIcon(_scanAgain, Glyph.Get("Refresh"));
            _scanAgain.Click += (_, _) => _vm.Scan();
            _scanState.Children.Add(new Spinner { Width = 16, Height = 16, Margin = new Thickness(0, 0, 8, 0) });
            _scanState.Children.Add(Muted("Searching…", "Text.BodySmall"));
            DockPanel.SetDock(_scanAgain, Dock.Right);
            DockPanel.SetDock(_scanState, Dock.Right);
            header.Children.Add(_scanAgain);
            header.Children.Add(_scanState);
            header.Children.Add(new TextBlock { Text = "On your network", Style = St("Text.TitleSmall"), VerticalAlignment = VerticalAlignment.Center });
            root.Children.Add(header);

            _noneFound.Text = "No servers found. Check that this PC is on the same network as the server, or type its address below.";
            _noneFound.Style = St("Text.BodySmall");
            _noneFound.Foreground = Brush("Brush.TextMuted");
            _noneFound.TextWrapping = TextWrapping.Wrap;
            _noneFound.Margin = new Thickness(0, 0, 0, 8);
            root.Children.Add(_noneFound);
            root.Children.Add(new ScrollViewer
            {
                Content = _found,
                MaxHeight = 240,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Margin = new Thickness(0, 0, 0, 16),
            });
        }

        root.Children.Add(FieldLabel("Server address"));
        _address.Style = St("TextBox");
        ButtonAssist.SetPlaceholder(_address, "\\\\192.168.0.10\\Movies");
        _address.TextChanged += (_, _) => _vm.ShowError(null);
        _address.IsReadOnly = _editing != null;
        root.Children.Add(_address);

        var chips = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 14) };
        _userChip.Style = St("Chip");
        _guestChip.Style = St("Chip");
        _guestChip.Margin = new Thickness(8, 0, 0, 0);
        _userChip.Click += (_, _) => SetGuest(false);
        _guestChip.Click += (_, _) => SetGuest(true);
        chips.Children.Add(_userChip);
        chips.Children.Add(_guestChip);
        root.Children.Add(chips);

        _loginFields.Children.Add(FieldLabel("Username"));
        _username.Style = St("TextBox");
        ButtonAssist.SetPlaceholder(_username, "Username (or WORKGROUP\\username)");
        _username.TextChanged += (_, _) => _vm.ShowError(null);
        _loginFields.Children.Add(_username);

        var pwLabel = FieldLabel("Password");
        pwLabel.Margin = new Thickness(0, 12, 0, 6);
        _loginFields.Children.Add(pwLabel);
        var pwGrid = new Grid();
        pwGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pwGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _password.Style = St("PasswordBox");
        ButtonAssist.SetPlaceholder(_password, "Password");
        _password.PasswordChanged += (_, _) => { if (_passwordShown.Visibility != Visibility.Visible) _passwordShown.Text = _password.Password; _vm.ShowError(null); };
        _passwordShown.Style = St("TextBox");
        _passwordShown.TextChanged += (_, _) => { if (_passwordShown.Visibility == Visibility.Visible) _password.Password = _passwordShown.Text; };
        _reveal.Style = St("Button.Icon");
        _reveal.Margin = new Thickness(6, 0, 0, 0);
        _reveal.ToolTip = "Show password";
        _reveal.Content = new Icon { Data = Glyph.Get("Visibility"), Size = 20 };
        _reveal.Click += (_, _) => TogglePasswordShown();
        pwGrid.Children.Add(_password);
        pwGrid.Children.Add(_passwordShown);
        Grid.SetColumn(_reveal, 1);
        pwGrid.Children.Add(_reveal);
        _loginFields.Children.Add(pwGrid);
        _loginFields.Children.Add(Muted("The password is stored encrypted on this PC and is only sent to this server.", "Text.BodySmall", top: 8, faint: true));
        root.Children.Add(_loginFields);

        _error.Style = St("Text.BodyMedium");
        _error.Foreground = Brush("Brush.Danger");
        _error.TextWrapping = TextWrapping.Wrap;
        _error.Margin = new Thickness(0, 14, 0, 0);
        _error.Visibility = Visibility.Collapsed;
        root.Children.Add(_error);
        return root;
    }

    private void SetGuest(bool guest)
    {
        _guestChip.IsChecked = guest;
        _userChip.IsChecked = !guest;
        _loginFields.Visibility = guest ? Visibility.Collapsed : Visibility.Visible;
        _vm.ShowError(null);
    }

    private void TogglePasswordShown()
    {
        var show = _passwordShown.Visibility != Visibility.Visible;
        if (show) _passwordShown.Text = _password.Password;
        _passwordShown.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _password.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        _reveal.ToolTip = show ? "Hide password" : "Show password";
        _reveal.Content = new Icon { Data = Glyph.Get(show ? "VisibilityOff" : "Visibility"), Size = 20 };
        (show ? (Control)_passwordShown : _password).Focus();
    }

    private void RenderFound()
    {
        if (_editing != null) return;
        _found.Children.Clear();
        foreach (var row in _vm.Found)
        {
            var selected = _vm.Picked?.Address == row.Address;
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = row.Label, Style = St("Text.BodyLarge"), TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(Muted(row.Subtitle, "Text.BodySmall"));
            var line = new DockPanel { LastChildFill = true };
            var icon = new Icon { Data = Glyph.Get(row.IsRouter ? "Devices" : "Dns"), Size = 22, Fill = Brush("Brush.AmberSoft"), Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(icon, Dock.Left);
            line.Children.Add(icon);
            if (selected)
            {
                var check = new Icon { Data = Glyph.Get("CheckCircle"), Size = 22, Fill = Brush("Brush.Amber"), VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(check, Dock.Right);
                line.Children.Add(check);
            }
            line.Children.Add(text);
            var card = new Border
            {
                Background = Brush(selected ? "Brush.AmberDim" : "Brush.Surface"),
                BorderBrush = Brush(selected ? "Brush.Amber" : "Brush.Outline"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 12, 14, 12),
                Child = line,
            };
            var button = new Button { Style = St("Button.Plain"), Content = card, Margin = new Thickness(0, 0, 0, 8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            var server = row.Server;
            button.Click += (_, _) =>
            {
                _vm.Pick(server);
                _address.Text = server.Address;
                RenderFound();
            };
            _found.Children.Add(button);
        }
        _noneFound.Visibility = _vm.Found.Count == 0 && !_vm.Scanning ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateScanState()
    {
        if (_editing != null) return;
        _scanState.Visibility = _vm.Scanning ? Visibility.Visible : Visibility.Collapsed;
        _scanAgain.Visibility = _vm.Scanning ? Visibility.Collapsed : Visibility.Visible;
        _noneFound.Visibility = _vm.Found.Count == 0 && !_vm.Scanning ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AddServerViewModel.Scanning):
                UpdateScanState();
                break;
            case nameof(AddServerViewModel.Error):
                _error.Text = _vm.Error ?? "";
                _error.Visibility = string.IsNullOrEmpty(_vm.Error) ? Visibility.Collapsed : Visibility.Visible;
                break;
            case nameof(AddServerViewModel.Busy):
                if (_connect.Control != null) _connect.Control.Content = _vm.Busy ? "Connecting…" : "Connect";
                _address.IsEnabled = _username.IsEnabled = _password.IsEnabled = _passwordShown.IsEnabled = !_vm.Busy;
                _userChip.IsEnabled = _guestChip.IsEnabled = !_vm.Busy;
                break;
        }
    }

    private async Task<bool> ConnectClicked()
    {
        var guest = _guestChip.IsChecked == true;
        var password = _passwordShown.Visibility == Visibility.Visible ? _passwordShown.Text : _password.Password;
        var error = await _vm.Attempt(_address.Text, guest, _username.Text, password, _editing?.Name);
        if (error != null || _vm.AddedServer == null) return false;
        _account = _vm.AddedServer.Account;
        _vm.CancelScan();
        ShowFolderStep(_vm.AddedServer, _vm.AddedCrumbs);
        return false; // stay open on the folder step
    }

    // ---------------------------------------------------------------------------------------------
    // Step 2: choose Movies / TV Shows folders on the server

    private void ShowFolderStep(SmbServer server, IReadOnlyList<SmbCrumb> crumbs)
    {
        DialogTitle = $"Connected to {server.DisplayName}";
        var root = new StackPanel();
        root.Children.Add(Muted("Choose a Movies or TV Shows folder. Veltoret scans it and keeps your library up to date.", "Text.BodyMedium", bottom: 16));
        if (crumbs.Count > 0)
        {
            var target = crumbs[^1];
            root.Children.Add(FolderOffer(server.Account, target.Id, target.Name));
        }
        var choose = new Button { Style = St("Button.Secondary"), Content = "Choose a folder…", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 0) };
        ButtonAssist.SetIcon(choose, Glyph.Get("Folder"));
        choose.Click += async (_, _) =>
        {
            try
            {
                var picked = await FolderPickerDialog.Pick(this, server.Account);
                if (picked is { } p)
                {
                    var index = root.Children.IndexOf(choose);
                    root.Children.Insert(index, FolderOffer(server.Account, p.Id, p.Name));
                }
            }
            catch (Exception ex)
            {
                AddNote(SmbErrors.Describe(ex), "Brush.Danger");
            }
        };
        root.Children.Add(choose);
        _added.Margin = new Thickness(0, 14, 0, 0);
        root.Children.Add(_added);
        Body = root;
        SetButtons(new DialogButton("Done", DialogButtonKind.Primary) { IsDefault = true });
    }

    /// <summary>A folder with "Movies" and "TV Shows" buttons that add it to the library.</summary>
    private FrameworkElement FolderOffer(string account, string folderId, string name)
    {
        var line = new DockPanel { LastChildFill = true };
        var icon = new Icon { Data = Glyph.Get("Folder"), Size = 22, Fill = Brush("Brush.AmberSoft"), Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(icon, Dock.Left);
        line.Children.Add(icon);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(buttons, Dock.Right);
        line.Children.Add(buttons);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        text.Children.Add(new TextBlock { Text = name, Style = St("Text.BodyLarge"), TextTrimming = TextTrimming.CharacterEllipsis });
        string where;
        try { where = SmbPath.Parse(folderId).Unc; } catch { where = folderId; }
        text.Children.Add(new TextBlock { Text = where, Style = St("Text.BodySmall"), Foreground = Brush("Brush.TextMuted"), TextTrimming = TextTrimming.CharacterEllipsis });
        line.Children.Add(text);

        foreach (var (label, type) in new[] { ("Movies", LibraryType.MOVIES), ("TV Shows", LibraryType.SHOWS) })
        {
            var b = new Button { Style = St("Button.Text"), Content = label, Margin = new Thickness(4, 0, 0, 0) };
            b.Click += async (_, _) =>
            {
                foreach (var other in buttons.Children.OfType<Button>()) other.IsEnabled = false;
                ButtonAssist.SetIsLoading(b, true);
                try
                {
                    var id = await AppServices.Library.AddFolder(account, folderId, name, type);
                    if (id is long folder)
                    {
                        AddNote($"Added \"{name}\" — scanning now", "Brush.Success");
                        _ = AppServices.Scans.RunNow(new HashSet<long> { folder });
                    }
                    else
                    {
                        AddNote($"\"{name}\" is already in your library", "Brush.TextMuted");
                    }
                }
                catch (Exception ex)
                {
                    App.Log(ex);
                    AddNote(ex.Message, "Brush.Danger");
                    foreach (var other in buttons.Children.OfType<Button>()) other.IsEnabled = true;
                }
                finally
                {
                    ButtonAssist.SetIsLoading(b, false);
                }
            };
            buttons.Children.Add(b);
        }
        return new Border
        {
            Background = Brush("Brush.Surface"),
            BorderBrush = Brush("Brush.Outline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 10, 8, 10),
            Margin = new Thickness(0, 0, 0, 8),
            Child = line,
        };
    }

    private void AddNote(string text, string brush) =>
        _added.Children.Add(new TextBlock { Text = text, Style = St("Text.BodyMedium"), Foreground = Brush(brush), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4) });

    // ---------------------------------------------------------------------------------------------

    private static Style St(string key) => (Style)Application.Current.FindResource(key);
    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    private static TextBlock FieldLabel(string text) => new()
    {
        Text = text,
        Style = St("Text.LabelMedium"),
        Foreground = Brush("Brush.TextMuted"),
        Margin = new Thickness(0, 0, 0, 6),
    };

    private static TextBlock Muted(string text, string style, double top = 0, double bottom = 0, bool faint = false) => new()
    {
        Text = text,
        Style = St(style),
        Foreground = Brush(faint ? "Brush.TextFaint" : "Brush.TextMuted"),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, top, 0, bottom),
    };
}
