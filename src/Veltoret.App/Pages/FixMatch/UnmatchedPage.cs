using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.Core.Data;

namespace Veltoret.App.Pages.FixMatch;

/// <summary>A group of unmatched (or ignored) files with the same kind and parsed title.</summary>
public sealed record FileGroup(MediaKind Kind, string Title, IReadOnlyList<MediaFileEntity> Files)
{
    public IReadOnlyList<string> Ids => Files.Select(f => f.DriveId).ToList();

    public static List<FileGroup> Of(IEnumerable<MediaFileEntity> files) =>
        files.GroupBy(f => (f.Kind, Title: string.IsNullOrWhiteSpace(f.ParsedTitle) ? f.Name : f.ParsedTitle))
            .Select(g => new FileGroup(g.Key.Kind, g.Key.Title, g.ToList()))
            .OrderBy(g => g.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();
}

/// <summary>"Needs a match": files we couldn't identify, grouped; Ignore / Restore.</summary>
public sealed class UnmatchedPage : LivePage
{
    private readonly ContentControl _body = new() { Focusable = false };
    private readonly VirtualGrid _grid = new() { MinCellWidth = 420, HGap = 10, VGap = 10, TopPadding = 20, BottomPadding = 20 };

    public UnmatchedPage()
    {
        var header = new ScreenHeader("Needs a match", "Files we couldn't identify automatically", back: true);
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        dock.Children.Add(_body);
        _body.Content = new LoadingBox();
        Content = dock;
    }

    protected override IReadOnlyCollection<string> Tables { get; } = new[] { "media_files" };

    protected override async Task Refresh()
    {
        var unmatched = FileGroup.Of(await AppServices.Library.Unmatched());
        var ignored = FileGroup.Of(await AppServices.Library.Ignored());
        if (unmatched.Count == 0 && ignored.Count == 0)
        {
            _body.Content = new EmptyState("CheckCircle", "All matched", "Every file in your library has been identified.");
            return;
        }
        var items = new List<object>();
        if (unmatched.Count == 0) items.Add(UiKit.Text("Everything else is matched.", "Text.BodyMedium", "TextMuted"));
        foreach (var g in unmatched) items.Add(new UiCell("u" + g.Kind + g.Title + g.Files.Count, () => UnmatchedCard(g)));
        if (ignored.Count > 0)
        {
            var head = new StackPanel { Margin = new Thickness(0, 18, 0, 10) };
            head.Children.Add(UiKit.Text("Ignored", "Text.TitleLarge"));
            head.Children.Add(UiKit.Text("Kept out of your library. Restore one to match it again.", "Text.BodySmall", "TextMuted"));
            items.Add(head);
            foreach (var g in ignored) items.Add(new UiCell("i" + g.Kind + g.Title + g.Files.Count, () => IgnoredCard(g)));
        }
        _grid.Source = items;
        _body.Content = _grid;
    }

    private static string Count(FileGroup g) =>
        (g.Kind == MediaKind.MOVIE ? "Movie · " : "TV · ") + Formats.Plural(g.Files.Count, "file", "files");

    private static string PathOf(MediaFileEntity f) => string.IsNullOrEmpty(f.RelativePath) ? f.Name : f.RelativePath + "/" + f.Name;

    private static FrameworkElement UnmatchedCard(FileGroup g)
    {
        var dock = new DockPanel();
        var chevron = UiKit.Icon("ChevronRight", 22, "TextMuted");
        DockPanel.SetDock(chevron, Dock.Right);
        dock.Children.Add(chevron);
        var ignore = UiKit.Button("Ignore", "Button.TextMuted", onClick: async () =>
        {
            try { await AppServices.Scanner.Ignore(g.Ids); }
            catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
        });
        ignore.Margin = new Thickness(8, 0, 4, 0);
        DockPanel.SetDock(ignore, Dock.Right);
        dock.Children.Add(ignore);
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        col.Children.Add(UiKit.Text(g.Title, "Text.TitleMedium", maxLines: 1));
        var count = UiKit.Text(Count(g), "Text.BodySmall", "Amber", maxLines: 1);
        count.Margin = new Thickness(0, 2, 0, 0);
        col.Children.Add(count);
        var path = UiKit.Text(PathOf(g.Files[0]), "Text.BodySmall", "TextMuted", maxLines: 1);
        path.ToolTip = string.Join("\n", g.Files.Take(12).Select(PathOf));
        col.Children.Add(path);
        dock.Children.Add(col);
        return UiKit.ClickPanel(dock, () => AppServices.Navigator.Navigate(new FixMatchRoute(g.Ids, g.Kind.ToString(), g.Title)));
    }

    private static FrameworkElement IgnoredCard(FileGroup g)
    {
        var dock = new DockPanel();
        var restore = UiKit.Button("Restore", "Button.Text", onClick: async () =>
        {
            try
            {
                await AppServices.Scanner.Restore(g.Ids);
                _ = AppServices.Scans.RunNow(g.Files.Select(f => f.LibraryFolderId).ToHashSet());
            }
            catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
        });
        DockPanel.SetDock(restore, Dock.Right);
        dock.Children.Add(restore);
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        col.Children.Add(UiKit.Text(g.Title, "Text.TitleSmall", "TextMuted", maxLines: 1));
        col.Children.Add(UiKit.Text(g.Files[0].Name, "Text.BodySmall", "TextFaint", maxLines: 1));
        dock.Children.Add(col);
        return UiKit.Panel(dock);
    }
}
