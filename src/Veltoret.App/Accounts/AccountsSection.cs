using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.App.Pages.Files;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Storage;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.AccountsUi;

/// <summary>
/// Settings section for Google Drive: connected Google accounts (avatar, name, email; "Reconnect" when Google
/// refused the stored sign-in; "Remove"), "Add Google account", and the "Google sign-in" panel that imports the
/// user's own Desktop OAuth client file.
/// </summary>
public sealed class AccountsSection : UserControl
{
    private readonly StackPanel _accounts = new();
    private readonly StackPanel _client = new();
    private readonly Button _add;
    private bool _connecting;

    /// <summary>
    /// List every Google account (default). A host that already shows account panels can turn this off; accounts
    /// that need reconnecting are listed either way.
    /// </summary>
    public bool ShowAccounts { get; set; } = true;

    public AccountsSection()
    {
        var root = new StackPanel();
        root.Children.Add(_accounts);

        _add = FileUi.Button("Add Google account", "Button.Secondary", Geo("PersonAdd"), () => _ = Connect(null));
        _add.HorizontalAlignment = HorizontalAlignment.Left;
        _add.Margin = new Thickness(0, 4, 0, 16);
        root.Children.Add(_add);

        var clientPanel = new Border { Style = FileUi.Style("Panel"), Child = _client };
        root.Children.Add(clientPanel);
        Content = root;

        Loaded += async (_, _) =>
        {
            AppServices.Db.Changed += OnDbChanged;
            AppServices.GoogleAuth.Changed += OnAuthChanged;
            await Reload();
        };
        Unloaded += (_, _) =>
        {
            AppServices.Db.Changed -= OnDbChanged;
            AppServices.GoogleAuth.Changed -= OnAuthChanged;
        };
    }

    private void OnDbChanged(IReadOnlySet<string> tables)
    {
        if (tables.Contains("accounts")) Dispatcher.InvokeAsync(async () => await Reload());
    }

    private void OnAuthChanged() => Dispatcher.InvokeAsync(async () => await Reload());

    private async Task Reload()
    {
        List<AccountEntity> accounts;
        try { accounts = (await AppServices.AccountDao.Accounts()).Where(a => Accounts.IsDrive(a.Email)).ToList(); }
        catch (Exception e)
        {
            App.Log(e);
            return;
        }
        _accounts.Children.Clear();
        // With ShowAccounts off (the host already lists accounts), still surface the ones that need reconnecting.
        foreach (var a in accounts.Where(a => ShowAccounts || AppServices.GoogleAuth.NeedsReconnect(a.Email)))
            _accounts.Children.Add(AccountRow(a));
        RenderClient();
    }

    private FrameworkElement AccountRow(AccountEntity a)
    {
        var panel = new Border { Style = FileUi.Style("Panel"), Margin = new Thickness(0, 0, 0, 10), Padding = new Thickness(14, 12, 10, 12) };
        var row = new DockPanel();
        var avatar = Avatar(a, 40);
        avatar.Margin = new Thickness(0, 0, 14, 0);
        row.Children.Add(avatar);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(actions, Dock.Right);
        var needsReconnect = AppServices.GoogleAuth.NeedsReconnect(a.Email);
        if (needsReconnect)
            actions.Children.Add(FileUi.Button("Reconnect", "Button.Text", null, () => _ = Connect(a.Email)));
        actions.Children.Add(FileUi.Button("Remove", "Button.TextMuted", null, () => _ = Remove(a)));
        row.Children.Add(actions);

        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Text(AccountName(a), "Text.TitleSmall", wrap: false));
        texts.Children.Add(Text(a.Email, "Text.BodySmall", Brush("TextMuted"), wrap: false));
        if (needsReconnect)
            texts.Children.Add(Text("Needs reconnecting: Google asked to sign in again.", "Text.BodySmall", Brush("Danger")));
        row.Children.Add(texts);
        panel.Child = row;
        return panel;
    }

    private void RenderClient()
    {
        _client.Children.Clear();
        _client.Children.Add(Text("Google sign-in", "Text.TitleSmall"));
        var client = AppServices.GoogleAuth.Client;
        if (client != null)
        {
            var status = Text($"OAuth client {client.MaskedId} · Desktop app", "Text.BodySmall", Brush("TextMuted"));
            status.Margin = new Thickness(0, 4, 0, 10);
            _client.Children.Add(status);
            var change = FileUi.Button("Change client file", "Button.Ghost", null, () => ConnectGoogle.ImportClient(Window.GetWindow(this)));
            change.HorizontalAlignment = HorizontalAlignment.Left;
            _client.Children.Add(change);
        }
        else
        {
            var help = Text("To connect Google Drive, Veltoret uses your own Google Cloud OAuth client (type \"Desktop app\"). " +
                            "Create one, download its JSON file, and import it here.", "Text.BodySmall", Brush("TextMuted"));
            help.Margin = new Thickness(0, 4, 0, 10);
            _client.Children.Add(help);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            buttons.Children.Add(FileUi.Button("Import client file", "Button.Secondary", null, () => ConnectGoogle.ImportClient(Window.GetWindow(this))));
            var guide = FileUi.Button("How to create one", "Button.Text", Geo("OpenInNew"), ConnectGoogle.OpenGuide);
            guide.Margin = new Thickness(8, 0, 0, 0);
            buttons.Children.Add(guide);
            _client.Children.Add(buttons);
        }
    }

    private async Task Connect(string? reconnect)
    {
        if (_connecting) return;
        _connecting = true;
        ButtonAssist.SetIsLoading(_add, true);
        try { await ConnectGoogle.Run(Window.GetWindow(this), reconnect); }
        finally
        {
            _connecting = false;
            ButtonAssist.SetIsLoading(_add, false);
        }
        await Reload();
    }

    /// <summary>"Remove {email}?": drops its library folders and this PC's sign-in; nothing is deleted from Drive.</summary>
    private async Task Remove(AccountEntity a)
    {
        await ConfirmAndRemove(Window.GetWindow(this), a);
        await Reload();
    }

    /// <summary>
    /// Asks "Remove {email}?" and removes a Google account: its library rows and this PC's stored sign-in.
    /// Settings should call this (not just <c>Library.RemoveAccount</c>) so the refresh token is deleted too.
    /// </summary>
    public static async Task<bool> ConfirmAndRemove(Window? owner, AccountEntity a)
    {
        if (!RemoveDialog(owner, a)) return false;
        try
        {
            await AppServices.Library.RemoveAccount(a.Email);
            if (Accounts.IsDrive(a.Email)) await AppServices.GoogleAuth.SignOut(a.Email);
            return true;
        }
        catch (Exception e)
        {
            Toast.Show(FileUi.Message(e));
            return false;
        }
    }

    /// <summary>The Remove account dialog for any source (texts per source, as on Android).</summary>
    public static bool RemoveDialog(Window? owner, AccountEntity a)
    {
        string title, text;
        if (Accounts.IsLocal(a.Email))
        {
            title = $"Remove {Accounts.DeviceDisplayName}?";
            text = "Its folders will be removed from your library. Nothing is deleted from this PC.";
        }
        else if (Accounts.IsSmb(a.Email))
        {
            title = $"Remove {AccountName(a)}?";
            text = "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server.";
        }
        else
        {
            title = $"Remove {a.Email}?";
            text = "Its folders will be removed from your library. Nothing is deleted from Google Drive.";
        }
        return Confirm.Ask(owner, title, text, "Remove", danger: true);
    }
}
