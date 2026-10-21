using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.Core.Data;
using Veltoret.Core.Drive;
using Veltoret.Core.Storage;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.Pages.Files;

/// <summary>The Files screen's dialogs, with the Android app's exact text (FileDialog.*).</summary>
internal static class FileDialogs
{
    /// <summary>"Rename": field pre-filled, the base name selected for files. Returns the trimmed new name or null.</summary>
    public static string? Rename(Window? owner, StorageItem item) =>
        AskName(owner, "Rename", item.Name, "Rename", selectBase: !item.IsFolder);

    /// <summary>"New folder": empty field, "Create".</summary>
    public static string? NewFolder(Window? owner) => AskName(owner, "New folder", "", "Create", selectBase: false);

    private static string? AskName(Window? owner, string title, string initial, string confirm, bool selectBase)
    {
        var box = new TextBox { Style = FileUi.Style("TextBox"), Text = initial, Width = 400 };
        var ok = new DialogButton(confirm, DialogButtonKind.Text) { IsDefault = true, IsEnabled = initial.Trim().Length > 0 };
        box.TextChanged += (_, _) => ok.IsEnabled = box.Text.Trim().Length > 0;
        box.Loaded += (_, _) =>
        {
            box.Focus();
            var dot = initial.LastIndexOf('.');
            if (selectBase && dot > 0) box.Select(0, dot);
            else box.SelectAll();
        };
        var result = DialogWindow.Show(owner, title, box, DialogButton.Cancel(), ok);
        return result == ok && box.Text.Trim().Length > 0 ? box.Text.Trim() : null;
    }

    /// <summary>Drive: "Move to trash?"; This PC: to the Recycle Bin; network server: deleted permanently.</summary>
    public static bool Trash(Window? owner, string account, string label, string? serverName)
    {
        string title, text, confirm;
        if (Accounts.IsLocal(account))
        {
            title = "Delete?";
            text = $"\"{label}\" moves to the Recycle Bin on this PC. You can restore it from there.";
            confirm = "Delete";
        }
        else if (Accounts.IsSmb(account))
        {
            title = "Delete permanently?";
            text = $"\"{label}\" will be deleted permanently from {serverName ?? "the server"}. Network shares have no trash, so this can't be undone.";
            confirm = "Delete";
        }
        else
        {
            title = "Move to trash?";
            text = $"\"{label}\" will be moved to Google Drive's trash. You can restore it from Drive for 30 days.";
            confirm = "Move to trash";
        }
        return Confirm.Ask(owner, title, text, confirm, danger: true);
    }

    /// <summary>Drive only: files.delete, skipping the trash.</summary>
    public static bool DeleteForever(Window? owner, string label, bool hasFolder) =>
        Confirm.Ask(owner, "Delete permanently?",
            $"\"{label}\"" + (hasFolder ? " and everything in it" : "") +
            " will be deleted from Google Drive right away. It won't go to the trash, so this can't be undone.",
            "Delete", danger: true);

    /// <summary>"Deleted 1 item" / "Moved to trash" … for the snackbar after a delete.</summary>
    public static string DeletedMessage(string account, int n, bool permanent)
    {
        if (permanent || !Accounts.IsDrive(account)) return n == 1 ? "Deleted 1 item" : $"Deleted {n} items";
        return n == 1 ? "Moved to trash" : $"{n} items moved to trash";
    }

    /// <summary>Details: Type, Size (files), Modified, Resolution, Duration.</summary>
    public static void Details(Window? owner, StorageItem item)
    {
        var grid = new Grid { MinWidth = 360 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rows = new List<(string, string)> { ("Type", item.IsFolder ? "Folder" : string.IsNullOrEmpty(item.MimeType) ? "—" : item.MimeType) };
        if (!item.IsFolder) rows.Add(("Size", DriveFormat.Bytes(item.SizeBytes)));
        rows.Add(("Modified", DriveFormat.DriveDate(item.ModifiedTime) ?? "—"));
        if (item.Width is > 0 && item.Height is > 0) rows.Add(("Resolution", $"{item.Width} × {item.Height}"));
        if (item.DurationMs is > 0) rows.Add(("Duration", DriveFormat.Clock(item.DurationMs.Value)));
        for (var i = 0; i < rows.Count; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = Text(rows[i].Item1, "Text.BodyMedium", Brush("TextMuted"));
            var value = Text(rows[i].Item2, "Text.BodyMedium");
            label.Margin = value.Margin = new Thickness(0, 4, 0, 4);
            Grid.SetRow(label, i);
            Grid.SetRow(value, i);
            Grid.SetColumn(value, 1);
            grid.Children.Add(label);
            grid.Children.Add(value);
        }
        var w = new DialogWindow { DialogTitle = item.Name, Body = grid };
        w.SetButtons(new DialogButton("Close", DialogButtonKind.Text) { IsDefault = true, IsCancel = true });
        w.ShowModal(owner);
    }

    /// <summary>
    /// After picking a folder on this PC: "What's in "{folder}"?" with Movies / TV Shows (dismiss "Not now").
    /// </summary>
    public static LibraryType? LibraryType(Window? owner, string folder, string dismiss = "Not now")
    {
        var movies = new DialogButton("Movies", DialogButtonKind.Primary);
        var shows = new DialogButton("TV Shows", DialogButtonKind.Secondary);
        var r = DialogWindow.Show(owner, $"What's in \"{folder}\"?",
            DialogWindow.Message("Veltoret will scan it and match everything with TMDB."),
            DialogButton.Cancel(dismiss), shows, movies);
        return r == movies ? Core.Data.LibraryType.MOVIES : r == shows ? Core.Data.LibraryType.SHOWS : null;
    }
}
