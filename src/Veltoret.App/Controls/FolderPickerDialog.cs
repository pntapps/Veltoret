using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Storage;
using VIcon = Veltoret.App.Controls.Icon;

namespace Veltoret.App.Controls;

using Accounts = Veltoret.Core.Storage.Accounts;

/// <summary>
/// Picks a folder from any source. This PC uses the native Windows folder dialog; Google Drive and network
/// servers are browsed through <c>AppServices.Storage</c>. A network server's top level (its list of shares)
/// can't be chosen — only a shared folder or something inside it.
/// </summary>
public sealed class FolderPickerDialog : DialogWindow
{
    private readonly string _account;
    private readonly ObservableCollection<StorageItem> _items = new();
    private readonly List<(string Id, string Name)> _path = new();
    private readonly ListBox _list;
    private readonly StackPanel _crumbs;
    private readonly TextBlock _status;
    private readonly Spinner _spinner;
    private readonly IReadOnlyList<DialogButton> _choose;
    private CancellationTokenSource? _cts;

    private FolderPickerDialog(string account, string title, IReadOnlyList<DialogButton> chooseButtons)
    {
        _account = account;
        _choose = chooseButtons;
        DialogTitle = title;
        var app = Application.Current;

        _crumbs = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        _list = new ListBox
        {
            Style = (Style)app.FindResource("ListBox.Plain"),
            ItemsSource = _items,
            Height = 360,
            ItemTemplate = BuildItemTemplate(),
        };
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        _list.MouseDoubleClick += (_, _) => { if (_list.SelectedItem is StorageItem it) Open(it); };
        _list.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter && _list.SelectedItem is StorageItem it) { Open(it); e.Handled = true; } };
        _list.PreviewMouseLeftButtonUp += (_, e) =>
        {
            // Single click opens a folder (like Android's picker).
            if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement(_list, d) is ListBoxItem { DataContext: StorageItem it }) Open(it);
        };
        _status = new TextBlock
        {
            Style = (Style)app.FindResource("Text.BodyMedium"),
            Foreground = (Brush)app.FindResource("Brush.TextMuted"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(24),
        };
        _spinner = new Spinner { Width = 32, Height = 32, Thickness = 2.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var listHost = new Grid();
        listHost.Children.Add(_list);
        listHost.Children.Add(_status);
        listHost.Children.Add(_spinner);
        var frame = new Border
        {
            BorderBrush = (Brush)app.FindResource("Brush.Outline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Background = (Brush)app.FindResource("Brush.Surface"),
            Padding = new Thickness(6),
            Child = listHost,
        };
        var body = new DockPanel { Width = 520 };
        DockPanel.SetDock(_crumbs, Dock.Top);
        body.Children.Add(_crumbs);
        body.Children.Add(frame);
        Body = body;

        var buttons = new List<DialogButton> { DialogButton.Cancel() };
        buttons.AddRange(chooseButtons);
        SetButtons(buttons.ToArray());

        string rootName;
        try { rootName = AppServices.Storage.RootName(account); }
        catch (Exception) { rootName = account; }
        _path.Add((AppServices.Storage.RootId(account), rootName));
        Loaded += (_, _) => _ = Load();
    }

    /// <summary>The folder currently shown.</summary>
    public (string Id, string Name) Current => _path[^1];

    private DataTemplate BuildItemTemplate()
    {
        var t = new DataTemplate(typeof(StorageItem));
        var row = new FrameworkElementFactory(typeof(StackPanel));
        row.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        var icon = new FrameworkElementFactory(typeof(VIcon));
        icon.SetValue(VIcon.DataProperty, Application.Current.FindResource("Icon.Folder"));
        icon.SetValue(VIcon.SizeProperty, 20.0);
        icon.SetValue(VIcon.FillProperty, Application.Current.FindResource("Brush.Amber"));
        icon.SetValue(MarginProperty, new Thickness(0, 0, 14, 0));
        icon.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        row.AppendChild(icon);
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(StorageItem.Name)));
        text.SetValue(StyleProperty, Application.Current.FindResource("Text.BodyLarge"));
        text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        text.SetValue(TextBlock.TextWrappingProperty, TextWrapping.NoWrap);
        text.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        row.AppendChild(text);
        t.VisualTree = row;
        return t;
    }

    private void Open(StorageItem folder)
    {
        _path.Add((folder.Id, folder.Name));
        _ = Load();
    }

    private void GoTo(int index)
    {
        if (index >= _path.Count - 1) return;
        _path.RemoveRange(index + 1, _path.Count - index - 1);
        _ = Load();
    }

    private bool AtSmbServerTop => Accounts.IsSmb(_account) && _path.Count == 1;

    private void RenderCrumbs()
    {
        _crumbs.Children.Clear();
        var app = Application.Current;
        for (var i = 0; i < _path.Count; i++)
        {
            var index = i;
            if (i > 0)
                _crumbs.Children.Add(new VIcon { Data = (Geometry)app.FindResource("Icon.ChevronRight"), Size = 18, Fill = (Brush)app.FindResource("Brush.TextFaint"), VerticalAlignment = VerticalAlignment.Center });
            var last = i == _path.Count - 1;
            var b = new Button
            {
                Content = new TextBlock { Text = _path[i].Name, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 },
                Style = (Style)app.FindResource(last ? "Button.Text" : "Button.TextMuted"),
                Foreground = (Brush)app.FindResource(last ? "Brush.Text" : "Brush.TextMuted"),
            };
            b.Click += (_, _) => GoTo(index);
            _crumbs.Children.Add(b);
        }
        // Show only the last few crumbs when deep.
        while (_crumbs.Children.Count > 7) _crumbs.Children.RemoveAt(0);
    }

    private async Task Load()
    {
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        RenderCrumbs();
        _items.Clear();
        _status.Visibility = Visibility.Collapsed;
        _spinner.Visibility = Visibility.Visible;
        foreach (var b in _choose) b.IsEnabled = !AtSmbServerTop;
        try
        {
            var list = await AppServices.Storage.List(_account, Current.Id, cts.Token);
            if (cts.IsCancellationRequested) return;
            foreach (var f in list.Where(f => f.IsFolder).OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)) _items.Add(f);
            if (_items.Count == 0)
            {
                _status.Text = AtSmbServerTop ? "No shared folders on this server." : "No folders here";
                _status.Visibility = Visibility.Visible;
            }
            else if (AtSmbServerTop)
            {
                _status.Visibility = Visibility.Collapsed;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (cts.IsCancellationRequested) return;
            _status.Text = ex.Message;
            _status.Visibility = Visibility.Visible;
        }
        finally
        {
            if (!cts.IsCancellationRequested) _spinner.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>Picks a folder; returns its id (a path on This PC) and display name, or null when cancelled.</summary>
    public static Task<(string Id, string Name)?> Pick(Window? owner, string account)
    {
        if (Accounts.IsLocal(account)) return Task.FromResult(PickLocal(owner));
        var choose = new DialogButton("Choose this folder", DialogButtonKind.Text) { IsDefault = true };
        var dlg = new FolderPickerDialog(account, "Choose a folder", new[] { choose });
        var result = dlg.ShowModal(owner);
        return Task.FromResult<(string Id, string Name)?>(result == choose ? dlg.Current : null);
    }

    /// <summary>
    /// Picks a library folder and its kind. Drive / network: the picker's actions are "Movies" / "TV Shows";
    /// This PC: the Windows folder dialog, then a library-type dialog.
    /// </summary>
    public static async Task<(string Id, string Name, LibraryType Type)?> PickLibraryFolder(Window? owner, string account)
    {
        if (Accounts.IsLocal(account))
        {
            var picked = PickLocal(owner);
            if (picked == null) return null;
            var type = AskLibraryType(owner, picked.Value.Name);
            return type == null ? null : (picked.Value.Id, picked.Value.Name, type.Value);
        }
        var movies = new DialogButton("Movies", DialogButtonKind.Text);
        var shows = new DialogButton("TV Shows", DialogButtonKind.Text);
        var dlg = new FolderPickerDialog(account, "Choose a folder", new[] { movies, shows });
        var result = dlg.ShowModal(owner);
        await Task.Yield();
        if (result == movies) return (dlg.Current.Id, dlg.Current.Name, LibraryType.MOVIES);
        if (result == shows) return (dlg.Current.Id, dlg.Current.Name, LibraryType.SHOWS);
        return null;
    }

    /// <summary>"What's in {name}?" — Movies / TV Shows (dismiss: Cancel).</summary>
    public static LibraryType? AskLibraryType(Window? owner, string folderName)
    {
        var movies = new DialogButton("Movies", DialogButtonKind.Text);
        var shows = new DialogButton("TV Shows", DialogButtonKind.Text);
        var r = DialogWindow.Show(owner, $"What's in {folderName}?",
            DialogWindow.Message("Tell Veltoret whether this folder holds movies or TV shows."),
            DialogButton.Cancel(), movies, shows);
        return r == movies ? LibraryType.MOVIES : r == shows ? LibraryType.SHOWS : null;
    }

    private static (string Id, string Name)? PickLocal(Window? owner)
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Choose a folder", Multiselect = false };
        var o = ResolveOwner(owner);
        var ok = o != null ? dlg.ShowDialog(o) : dlg.ShowDialog();
        if (ok != true || string.IsNullOrEmpty(dlg.FolderName)) return null;
        var path = dlg.FolderName;
        var name = dlg.SafeFolderName;
        if (string.IsNullOrEmpty(name)) name = Path.GetFileName(path.TrimEnd('\\'));
        if (string.IsNullOrEmpty(name)) name = path;
        return (path, name);
    }
}
