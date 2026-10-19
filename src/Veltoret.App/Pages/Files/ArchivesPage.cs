using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Drive;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.Pages.Files;

/// <summary>
/// Settings → "ZIP archives" (Android: ArchivesScreen): ZIPs the scanner found in Drive library folders, each with
/// its latest extraction job or an "Extract to Drive" button.
/// </summary>
public sealed class ArchivesPage : UserControl
{
    private const double MinColumnWidth = 420;
    private readonly UniformGrid _grid = new() { Columns = 1 };
    private readonly ContentControl _state = new();
    private List<ArchiveFileEntity> _archives = new();
    private readonly System.Windows.Threading.DispatcherTimer _throttle = new() { Interval = TimeSpan.FromMilliseconds(300) };

    public ArchivesPage()
    {
        SetResourceReference(BackgroundProperty, "Brush.Background");
        FontFamily = (FontFamily)Application.Current.FindResource("Font.Sans");
        _throttle.Tick += (_, _) => { _throttle.Stop(); Render(); };

        var back = FileUi.IconButton(Geo("ArrowBack"), "Back", () => AppServices.Navigator.GoBack());
        back.Margin = new Thickness(0, 0, 16, 0);
        back.VerticalAlignment = VerticalAlignment.Top;
        var titles = new StackPanel();
        titles.Children.Add(Text("Archives", "Text.DisplaySmall", wrap: false));
        titles.Children.Add(Text("ZIP files in your library folders", "Text.BodyMedium", Brush("TextMuted")));
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        header.Children.Add(back);
        header.Children.Add(titles);

        var intro = Text("Videos inside a ZIP can't be streamed. Extracting unpacks them into a folder next to the ZIP without saving anything on this PC.",
            "Text.BodyMedium", Brush("TextMuted"));
        intro.MaxWidth = 720;
        intro.HorizontalAlignment = HorizontalAlignment.Left;
        intro.Margin = new Thickness(0, 0, 0, 18);

        var stack = new StackPanel { Margin = new Thickness(32, 24, 32, 40) };
        stack.Children.Add(header);
        stack.Children.Add(intro);
        stack.Children.Add(_state);
        stack.Children.Add(_grid);
        _grid.SizeChanged += (_, e) =>
        {
            var cols = Math.Max(1, (int)(e.NewSize.Width / MinColumnWidth));
            if (cols != _grid.Columns) _grid.Columns = cols;
        };
        Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

        Loaded += async (_, _) =>
        {
            AppServices.Db.Changed += OnDbChanged;
            AppServices.Transfers.JobChanged += OnJob;
            AppServices.Transfers.JobRemoved += OnJobRemoved;
            await Reload();
        };
        Unloaded += (_, _) =>
        {
            AppServices.Db.Changed -= OnDbChanged;
            AppServices.Transfers.JobChanged -= OnJob;
            AppServices.Transfers.JobRemoved -= OnJobRemoved;
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && AppServices.Navigator.GoBack()) e.Handled = true;
        };
    }

    private void OnDbChanged(IReadOnlySet<string> tables)
    {
        if (tables.Contains("archive_files")) Dispatcher.InvokeAsync(async () => await Reload());
    }

    private void OnJob(TransferJob job)
    {
        if (job.Kind == TransferKind.Extract) Dispatcher.InvokeAsync(() => { if (!_throttle.IsEnabled) _throttle.Start(); });
    }

    private void OnJobRemoved(string id) => Dispatcher.InvokeAsync(() => { if (!_throttle.IsEnabled) _throttle.Start(); });

    private async Task Reload()
    {
        try { _archives = (await AppServices.Library.Archives()).Where(a => Core.Storage.Accounts.IsDrive(a.AccountEmail)).ToList(); }
        catch (Exception ex) { App.Log(ex); }
        Render();
    }

    private void Render()
    {
        _grid.Children.Clear();
        _state.Content = null;
        if (_archives.Count == 0)
        {
            var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 520, Margin = new Thickness(0, 24, 0, 0) };
            s.Children.Add(Text("No archives", "Text.HeadlineSmall"));
            var m = Text("When a ZIP turns up in your Movies or TV folders, it appears here so you can unpack it into Drive.", "Text.BodyMedium", Brush("TextMuted"));
            m.Margin = new Thickness(0, 6, 0, 0);
            s.Children.Add(m);
            _state.Content = s;
            return;
        }
        foreach (var a in _archives) _grid.Children.Add(Card(a));
    }

    private FrameworkElement Card(ArchiveFileEntity archive)
    {
        var card = new Border { Style = FileUi.Style("Panel"), Margin = new Thickness(0, 0, 12, 12) };
        var stack = new StackPanel();
        var head = new DockPanel();
        var tile = Tile(Geo("FolderZip"), Brush("AmberSoft"));
        tile.Margin = new Thickness(0, 0, 14, 0);
        tile.VerticalAlignment = VerticalAlignment.Top;
        head.Children.Add(tile);
        var texts = new StackPanel();
        var name = Text(archive.Name, "Text.TitleSmall");
        name.MaxHeight = 40;
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        texts.Children.Add(name);
        var where = string.Join(" · ", new[] { DriveFormat.Bytes(archive.SizeBytes), archive.RelativePath, archive.AccountEmail }.Where(s => !string.IsNullOrEmpty(s)));
        texts.Children.Add(Text(where, "Text.BodySmall", Brush("TextMuted")));
        head.Children.Add(texts);
        stack.Children.Add(head);

        var job = AppServices.Transfers.LatestForZip(archive.DriveId);
        if (job != null)
        {
            var transfer = new TransferCard(job, job.IsActive ? "Extracting" : "Extraction", dismissible: false) { Margin = new Thickness(0, 14, 0, 0) };
            stack.Children.Add(transfer);
            if (job.State == TransferState.Failed)
            {
                var retry = FileUi.Button("Try again", "Button.Secondary", Icons.Unarchive, () => Extract(archive));
                retry.HorizontalAlignment = HorizontalAlignment.Left;
                retry.Margin = new Thickness(0, 10, 0, 0);
                stack.Children.Add(retry);
            }
        }
        else
        {
            var extract = FileUi.Button("Extract to Drive", "Button.Primary", Icons.Unarchive, () => Extract(archive));
            extract.HorizontalAlignment = HorizontalAlignment.Left;
            extract.Margin = new Thickness(0, 14, 0, 0);
            stack.Children.Add(extract);
        }
        card.Child = stack;
        return card;
    }

    private void Extract(ArchiveFileEntity archive)
    {
        if (ExtractDialog.Show(Window.GetWindow(this), archive.AccountEmail, archive.DriveId, archive.Name, archive.SizeBytes, archive.ParentId))
            Render();
    }
}
