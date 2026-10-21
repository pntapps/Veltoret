using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Smb;

namespace Veltoret.App.Network;

/// <summary>
/// Settings → network servers: one panel per saved SMB server (name, address, who signs in, its library folders),
/// "Sign in again", "Add library folder", "Remove", and an "Add network server" button.
/// </summary>
public sealed class NetworkServersSection : UserControl
{
    private readonly StackPanel _list = new();
    private bool _refreshing;
    private bool _again;

    public NetworkServersSection()
    {
        var root = new StackPanel();
        root.Children.Add(_list);
        var add = new Button { Style = St("Button.Secondary"), Content = "Add network server", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 0) };
        ButtonAssist.SetIcon(add, Icon.Get("Dns"));
        add.Click += async (_, _) =>
        {
            var account = await AddServerDialog.Show(Window.GetWindow(this));
            if (account != null) _ = Refresh();
        };
        root.Children.Add(add);
        Content = root;

        Loaded += (_, _) =>
        {
            AppServices.SmbServers.Changed += OnServersChanged;
            _ = Refresh();
        };
        Unloaded += (_, _) => AppServices.SmbServers.Changed -= OnServersChanged;
    }

    private void OnServersChanged() => Dispatcher.BeginInvoke(() => _ = Refresh());

    /// <summary>
    /// Asks, then removes a server: its library folders and files, the account row, the saved password and the
    /// open connection. Nothing is deleted from the server. Returns true when removed.
    /// </summary>
    public static async Task<bool> ConfirmAndRemove(Window? owner, string account)
    {
        var server = AppServices.SmbServers.Server(account);
        var name = server?.DisplayName ?? SmbPath.Parse(account).Host;
        if (!Confirm.Ask(owner, $"Remove {name}?",
                "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server.",
                "Remove", danger: true)) return false;
        await RemoveServer(account);
        return true;
    }

    /// <summary>Forgets a server without asking (library rows, password, connection).</summary>
    public static async Task RemoveServer(string account)
    {
        await AppServices.Library.RemoveAccount(account);
        AppServices.SmbFiles.Disconnect(account);
        AppServices.SmbServers.Remove(account);
    }

    private async Task Refresh()
    {
        if (_refreshing) { _again = true; return; }
        _refreshing = true;
        try
        {
            do
            {
                _again = false;
                List<LibraryFolderEntity> folders;
                try { folders = await AppServices.AccountDao.FoldersSorted(); }
                catch (Exception e) { App.Log(e); folders = new(); }
                _list.Children.Clear();
                foreach (var server in AppServices.SmbServers.Servers)
                    _list.Children.Add(ServerPanel(server, folders.Where(f => f.AccountEmail == server.Account).ToList()));
            } while (_again);
        }
        finally
        {
            _refreshing = false;
        }
    }

    private FrameworkElement ServerPanel(SmbServer server, List<LibraryFolderEntity> folders)
    {
        var panel = new StackPanel();

        // Header: icon, name, address · user, Remove.
        var header = new DockPanel { LastChildFill = true, Margin = new Thickness(16, 14, 8, 10) };
        var icon = new Border
        {
            Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Background = Brush("Brush.AmberDim"),
            Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center,
            Child = new Icon { Data = Icon.Get("Dns"), Size = 20, Fill = Brush("Brush.Amber"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        DockPanel.SetDock(icon, Dock.Left);
        header.Children.Add(icon);
        var remove = new Button { Style = St("Button.TextMuted"), Content = "Remove", VerticalAlignment = VerticalAlignment.Center };
        remove.Click += async (_, _) =>
        {
            try
            {
                if (await ConfirmAndRemove(Window.GetWindow(this), server.Account)) _ = Refresh();
            }
            catch (Exception e) { App.Log(e); }
        };
        DockPanel.SetDock(remove, Dock.Right);
        header.Children.Add(remove);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = server.DisplayName, Style = St("Text.TitleMedium"), TextTrimming = TextTrimming.CharacterEllipsis });
        var who = server.Guest ? "Guest" : server.Domain.Length > 0 ? $"{server.Domain}\\{server.Username}" : server.Username;
        text.Children.Add(new TextBlock { Text = $"\\\\{server.Host} · {who}", Style = St("Text.BodySmall"), Foreground = Brush("Brush.TextMuted"), TextTrimming = TextTrimming.CharacterEllipsis });
        if (AppServices.SmbServers.Password(server.Account) == null)
            text.Children.Add(new TextBlock { Text = $"Sign in to {server.DisplayName} again", Style = St("Text.BodySmall"), Foreground = Brush("Brush.Danger") });
        header.Children.Add(text);
        panel.Children.Add(header);

        // Library folders on this server.
        panel.Children.Add(new Border { Style = St("Divider") });
        if (folders.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = "No library folders yet.", Style = St("Text.BodyMedium"), Foreground = Brush("Brush.TextMuted"),
                Margin = new Thickness(16, 12, 16, 12),
            });
        }
        foreach (var folder in folders)
        {
            var row = new DockPanel { LastChildFill = true, Margin = new Thickness(16, 8, 8, 8) };
            var kind = new Icon { Data = Icon.Get(folder.Type == LibraryType.MOVIES ? "Movie" : "LiveTv"), Size = 20, Fill = Brush("Brush.Amber"), Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(kind, Dock.Left);
            row.Children.Add(kind);
            var removeFolder = new Button { Style = St("Button.Icon"), ToolTip = "Remove folder", Content = new Icon { Data = Icon.Get("Close"), Size = 18 } };
            var folderId = folder.Id;
            removeFolder.Click += async (_, _) =>
            {
                try
                {
                    await AppServices.Library.RemoveFolder(folderId);
                    _ = Refresh();
                }
                catch (Exception e) { App.Log(e); }
            };
            DockPanel.SetDock(removeFolder, Dock.Right);
            row.Children.Add(removeFolder);
            var pill = new Border
            {
                Style = St("Pill"), Margin = new Thickness(8, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = folder.Type == LibraryType.MOVIES ? "Movies" : "TV", Style = St("Text.Pill") },
            };
            DockPanel.SetDock(pill, Dock.Right);
            row.Children.Add(pill);
            var where = folder.DriveFolderId;
            try { where = SmbPath.Parse(folder.DriveFolderId).Unc; } catch { }
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            names.Children.Add(new TextBlock { Text = folder.Name, Style = St("Text.BodyLarge"), TextTrimming = TextTrimming.CharacterEllipsis });
            names.Children.Add(new TextBlock { Text = where, Style = St("Text.BodySmall"), Foreground = Brush("Brush.TextFaint"), TextTrimming = TextTrimming.CharacterEllipsis });
            row.Children.Add(names);
            panel.Children.Add(row);
        }

        // Actions.
        panel.Children.Add(new Border { Style = St("Divider") });
        var actions = new WrapPanel { Margin = new Thickness(8, 6, 8, 6) };
        var addFolder = new Button { Style = St("Button.Ghost"), Content = "Add library folder", Margin = new Thickness(4) };
        ButtonAssist.SetIcon(addFolder, Icon.Get("CreateNewFolder"));
        addFolder.Click += async (_, _) => await AddFolder(server);
        actions.Children.Add(addFolder);
        var signIn = new Button { Style = St("Button.Ghost"), Content = "Sign in again", Margin = new Thickness(4) };
        ButtonAssist.SetIcon(signIn, Icon.Get("Key"));
        signIn.Click += async (_, _) =>
        {
            await AddServerDialog.Show(Window.GetWindow(this), server);
            _ = Refresh();
        };
        actions.Children.Add(signIn);
        panel.Children.Add(actions);

        return new Border { Style = St("Panel"), Child = panel, Margin = new Thickness(0, 0, 0, 12) };
    }

    private async Task AddFolder(SmbServer server)
    {
        var owner = Window.GetWindow(this);
        try
        {
            var picked = await FolderPickerDialog.Pick(owner!, server.Account);
            if (picked is not { } p) return;
            var movies = new DialogButton("Movies", DialogButtonKind.Text) { IsDefault = true };
            var shows = new DialogButton("TV Shows", DialogButtonKind.Text);
            var choice = DialogWindow.Show(owner, "Choose a library folder",
                DialogWindow.Message($"What's in \"{p.Name}\"?"), DialogButton.Cancel(), shows, movies);
            if (choice != movies && choice != shows) return;
            var id = await AppServices.Library.AddFolder(server.Account, p.Id, p.Name, choice == movies ? LibraryType.MOVIES : LibraryType.SHOWS);
            if (id is long folder) _ = AppServices.Scans.RunNow(new HashSet<long> { folder });
            _ = Refresh();
        }
        catch (Exception e)
        {
            App.Log(e);
            DialogWindow.Show(owner, "Couldn't open the server", DialogWindow.Message(SmbErrors.Describe(e)), DialogButton.Ok());
        }
    }

    private static Style St(string key) => (Style)Application.Current.FindResource(key);
    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
}
