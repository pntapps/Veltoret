using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Drive;
using Veltoret.Core.Library;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.Pages.Files;

/// <summary>
/// "Extract to Google Drive?" (Android: ExtractDialog). Checks free space first and won't start when the files
/// can't fit — unless an earlier attempt's folder is already there (those files are skipped). Starts a
/// background extraction job and says so in a snackbar.
/// </summary>
public sealed class ExtractDialog : DialogWindow
{
    private readonly string _account;
    private readonly string _zipId;
    private readonly string _zipName;
    private readonly long _size;
    private readonly string _parentId;
    private readonly TextBlock _space;
    private readonly CheckBox _wifiOnly;
    private readonly RadioButton _keep, _trash, _delete;
    private readonly DialogButton _confirm;
    private ExtractCheck? _check;
    private readonly CancellationTokenSource _cts = new();

    private ExtractDialog(string account, string zipId, string zipName, long size, string parentId)
    {
        _account = account;
        _zipId = zipId;
        _zipName = zipName;
        _size = size;
        _parentId = parentId;
        DialogTitle = "Extract to Google Drive?";
        var baseName = FilenameParser.BaseName(zipName);

        var body = new StackPanel { Width = 480 };
        var icon = IconOf(Icons.Unarchive, 28, Brush("Amber"));
        icon.HorizontalAlignment = HorizontalAlignment.Left;
        icon.Margin = new Thickness(0, -6, 0, 12);
        body.Children.Add(icon);
        body.Children.Add(Text($"The videos in \"{zipName}\" will be unpacked into a new folder named \"{baseName}\" right next to it, then added to your library.",
            "Text.BodyMedium"));
        var note = Text($"Nothing is saved on this PC — the archive streams through it. It does use about {DriveFormat.Bytes(size * 2)} of data " +
                        "(downloading and uploading once), and runs in the background.", "Text.BodySmall", Brush("TextMuted"));
        note.Margin = new Thickness(0, 10, 0, 0);
        body.Children.Add(note);
        _space = Text("Checking free space in Google Drive…", "Text.BodySmall", Brush("TextMuted"));
        _space.Margin = new Thickness(0, 10, 0, 0);
        body.Children.Add(_space);

        _wifiOnly = new CheckBox { Content = "Only on Wi-Fi", Style = FileUi.Style("CheckBox"), IsChecked = true, Margin = new Thickness(0, 16, 0, 0) };
        _wifiOnly.ToolTip = "Waits for an unmetered network (not a metered connection or a phone hotspot).";
        body.Children.Add(_wifiOnly);

        var section = Text("When it's done", "Text.LabelLarge", Brush("Amber"));
        section.Margin = new Thickness(0, 18, 0, 6);
        body.Children.Add(section);
        _keep = Radio("Keep the ZIP", null, true);
        _trash = Radio("Move the ZIP to trash", "Recoverable for 30 days. It keeps using space until Drive's trash is emptied.", false);
        _delete = Radio("Delete the ZIP permanently", "Frees the space now. This can't be undone.", false);
        body.Children.Add(_keep);
        body.Children.Add(_trash);
        body.Children.Add(_delete);
        var faint = Text("The ZIP is only removed after every file inside it has been extracted successfully, so it can't make room during extraction.",
            "Text.BodySmall", Brush("TextFaint"));
        faint.Margin = new Thickness(0, 10, 0, 0);
        body.Children.Add(faint);
        Body = body;

        _confirm = new DialogButton("Extract", DialogButtonKind.Primary) { IsDefault = true, IsEnabled = false };
        SetButtons(DialogButton.Cancel(), _confirm);
        foreach (var r in new[] { _keep, _trash, _delete })
            r.Checked += (_, _) => { if (_confirm.Control != null) _confirm.Control.Content = _delete.IsChecked == true ? "Extract & delete ZIP" : "Extract"; };

        Loaded += async (_, _) => await Check();
        Closed += (_, _) => _cts.Cancel();
    }

    private RadioButton Radio(string title, string? text, bool selected)
    {
        var content = new StackPanel();
        content.Children.Add(Text(title, "Text.BodyMedium"));
        if (text != null) content.Children.Add(Text(text, "Text.BodySmall", Brush("TextMuted")));
        return new RadioButton
        {
            Content = content,
            GroupName = "after-" + GetHashCode(),
            IsChecked = selected,
            Foreground = Brush("Text"),
            Margin = new Thickness(0, 4, 0, 4),
            VerticalContentAlignment = VerticalAlignment.Top,
            Cursor = System.Windows.Input.Cursors.Hand,
        };
    }

    private async Task Check()
    {
        try
        {
            _check = await AppServices.Transfers.CheckExtract(_account, _zipName, _size, _parentId, _cts.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception)
        {
            _check = new ExtractCheck(null, false, _size);
        }
        var c = _check;
        if (c.Free == null)
        {
            _space.Visibility = Visibility.Collapsed; // unlimited or unknown quota
        }
        else
        {
            var line = $"Needs about {DriveFormat.Bytes(_size)} of free space in Google Drive. You have {DriveFormat.Bytes(c.Free.Value)} free.";
            if (c.TooBig) line += " Free up space first (Gmail and Google Photos share it), or the extraction would stop part-way.";
            else if (c.Resuming && c.Free < _size) line += " Files from an earlier attempt are already there and are skipped, so it may fit.";
            _space.Text = line;
            _space.Foreground = c.TooBig ? Brush("Danger") : Brush("TextMuted");
        }
        _confirm.IsEnabled = !c.TooBig;
    }

    private ZipAfterExtract After => _delete.IsChecked == true ? ZipAfterExtract.Delete : _trash.IsChecked == true ? ZipAfterExtract.Trash : ZipAfterExtract.Keep;

    /// <summary>Shows the dialog; true when an extraction was started.</summary>
    public static bool Show(Window? owner, string account, string zipId, string zipName, long size, string parentId)
    {
        var dlg = new ExtractDialog(account, zipId, string.IsNullOrEmpty(zipName) ? "Archive.zip" : zipName, size, parentId);
        var r = dlg.ShowModal(owner);
        if (r != dlg._confirm) return false;
        AppServices.Transfers.Extract(account, zipId, dlg._zipName, size, parentId, dlg.After, dlg._wifiOnly.IsChecked == true);
        Toast.Show($"Extracting {dlg._zipName} in the background");
        return true;
    }
}
