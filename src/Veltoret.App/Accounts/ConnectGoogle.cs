using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.App.Pages.Files;
using Veltoret.App.Services;
using Veltoret.Core.Auth;
using Veltoret.Core.Data;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.AccountsUi;

/// <summary>
/// "Add Google account" (Android: rememberAccountConnector): makes sure an OAuth client is imported, then runs the
/// browser sign-in with a "Connecting…" dialog that can be cancelled. Failures show as "{title}. {message}";
/// setup problems open a dialog with the details needed to fix the Google Cloud client.
/// </summary>
public static class ConnectGoogle
{
    /// <summary>The setup guide (docs/SETUP.md, "Google Drive").</summary>
    public const string SetupUrl = "https://github.com/pntapps/Veltoret-Windows/blob/main/docs/SETUP.md#google-drive";

    /// <summary>Connects a new account (or reconnects <paramref name="reconnectEmail"/>). Null when it didn't happen.</summary>
    public static async Task<AccountEntity?> Run(Window? owner, string? reconnectEmail = null)
    {
        if (!AppServices.GoogleAuth.HasClient && !ImportClient(owner, firstTime: true)) return null;

        using var cts = new CancellationTokenSource();
        var dlg = new DialogWindow { DialogTitle = reconnectEmail == null ? "Connecting to Google" : $"Reconnecting {reconnectEmail}" };
        var body = new StackPanel { Width = 420 };
        var row = new DockPanel();
        var spinner = new Spinner { Width = 28, Height = 28, Thickness = 2.5, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Top };
        row.Children.Add(spinner);
        var texts = new StackPanel();
        texts.Children.Add(Text("Finish signing in in your browser.", "Text.BodyLarge"));
        var hint = Text("Pick your Google account, click Continue on \"Google hasn't verified this app\", make sure Google Drive access is ticked, " +
                        "then come back here. Veltoret waits up to 5 minutes.", "Text.BodySmall", Brush("TextMuted"));
        hint.Margin = new Thickness(0, 6, 0, 0);
        texts.Children.Add(hint);
        row.Children.Add(texts);
        body.Children.Add(row);
        dlg.Body = body;
        var cancel = DialogButton.Cancel();
        dlg.SetButtons(cancel);

        Task<AccountEntity>? task = null;
        dlg.Loaded += async (_, _) =>
        {
            task = AppServices.GoogleAuth.SignIn(cts.Token, reconnectEmail);
            try { await task; }
            catch (Exception) { }
            if (dlg.IsVisible) dlg.Finish(null);
        };
        dlg.ShowModal(owner);
        if (task == null) return null;
        if (!task.IsCompleted) cts.Cancel();

        try
        {
            var account = await task;
            Toast.Show($"Connected {account.Email}");
            if (reconnectEmail != null) AppServices.Scans?.RequestAutomatic();
            return account;
        }
        catch (ConnectException e)
        {
            if (e.SetupProblem && e.Title != ConnectException.NotGranted().Title) ShowSetupProblem(owner, e);
            else Toast.Show($"{e.Title}. {e.Message}");
        }
        catch (Exception e)
        {
            Toast.Show($"Couldn't connect. {FileUi.Message(e, "Google sign-in failed.")}");
        }
        return null;
    }

    /// <summary>
    /// Explains the Desktop OAuth client and imports its JSON file. Returns true when a client was imported.
    /// </summary>
    public static bool ImportClient(Window? owner, bool firstTime = false)
    {
        var body = new StackPanel { Width = 480 };
        body.Children.Add(Text(
            "Veltoret signs in to Google Drive through your own Google Cloud OAuth client of type \"Desktop app\" — " +
            "nothing goes through anyone else's server. Creating one is free and takes about ten minutes:", "Text.BodyMedium", Brush("TextMuted")));
        var steps = new[]
        {
            "1.  In Google Cloud, create a project and enable the Google Drive API.",
            "2.  Set up Google Auth Platform (Audience: External) and add your Google account as a test user.",
            "3.  Create a client: Application type Desktop app, then Download JSON.",
            "4.  Import that file here.",
        };
        var list = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var s in steps)
        {
            var t = Text(s, "Text.BodyMedium");
            t.Margin = new Thickness(0, 2, 0, 2);
            list.Children.Add(t);
        }
        body.Children.Add(list);
        var link = FileUi.Button("Open the setup guide", "Button.Text", Geo("OpenInNew"), OpenGuide);
        link.HorizontalAlignment = HorizontalAlignment.Left;
        link.Margin = new Thickness(-8, 10, 0, 0);
        body.Children.Add(link);
        var error = Text("", "Text.BodySmall", Brush("Danger"));
        error.Margin = new Thickness(0, 8, 0, 0);
        error.Visibility = Visibility.Collapsed;
        body.Children.Add(error);

        var import = new DialogButton("Import client file", DialogButtonKind.Primary) { IsDefault = true };
        import.OnClick = () =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Import Google OAuth client",
                Filter = "Google client file (*.json)|*.json|All files (*.*)|*.*",
            };
            var w = DialogWindow.ResolveOwner(null);
            if ((w != null ? dlg.ShowDialog(w) : dlg.ShowDialog()) != true) return Task.FromResult(false);
            try
            {
                AppServices.GoogleAuth.ImportClientJson(dlg.FileName);
                Toast.Show("Google sign-in is set up");
                return Task.FromResult(true);
            }
            catch (FormatException e)
            {
                error.Text = e.Message;
                error.Visibility = Visibility.Visible;
                return Task.FromResult(false);
            }
        };
        var title = firstTime ? "Set up Google sign-in" : "Import client file";
        var r = DialogWindow.Show(owner, title, body, DialogButton.Cancel(), import);
        return r == import;
    }

    public static void OpenGuide()
    {
        try { Process.Start(new ProcessStartInfo(SetupUrl) { UseShellExecute = true }); }
        catch (Exception e) { Toast.Show(FileUi.Message(e, "Couldn't open your web browser")); }
    }

    /// <summary>"Google sign-in isn't set up for this build" and friends, with what to check in Google Cloud.</summary>
    private static void ShowSetupProblem(Window? owner, ConnectException e)
    {
        var body = new StackPanel { Width = 480 };
        body.Children.Add(Text(e.Message, "Text.BodyMedium", Brush("TextMuted")));
        var section = Text("Setup details for this PC", "Text.LabelLarge", Brush("Amber"));
        section.Margin = new Thickness(0, 16, 0, 6);
        body.Children.Add(section);
        var client = AppServices.GoogleAuth.Client;
        body.Children.Add(DetailRow("Client ID", client?.MaskedId ?? "None imported", client?.ClientId));
        body.Children.Add(DetailRow("Application type", "Desktop app", "Desktop app"));
        body.Children.Add(DetailRow("Redirect", "http://127.0.0.1:<port>/ (any port, nothing to enter)", null));
        var guide = FileUi.Button("Open the setup guide", "Button.Text", Geo("OpenInNew"), OpenGuide);
        guide.HorizontalAlignment = HorizontalAlignment.Left;
        guide.Margin = new Thickness(-8, 10, 0, 0);
        body.Children.Add(guide);

        var import = new DialogButton("Import client file", DialogButtonKind.Text);
        var r = DialogWindow.Show(owner, e.Title, body, DialogButton.Cancel("Close"), import);
        if (r == import) ImportClient(owner);
    }

    private static FrameworkElement DetailRow(string label, string value, string? copy)
    {
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
        var l = Text(label, "Text.BodySmall", Brush("TextMuted"), wrap: false);
        l.Width = 120;
        row.Children.Add(l);
        if (copy != null)
        {
            var b = FileUi.IconButton(Geo("DoneAll"), "Copy", () =>
            {
                try { Clipboard.SetText(copy); Toast.Show("Copied"); }
                catch (Exception) { }
            }, "Button.IconFlat");
            DockPanel.SetDock(b, Dock.Right);
            row.Children.Add(b);
        }
        row.Children.Add(Text(value, "Text.BodySmall", wrap: true));
        return row;
    }
}
