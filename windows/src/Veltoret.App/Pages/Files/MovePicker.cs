using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Drive;
using Veltoret.Core.Storage;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.Pages.Files;

/// <summary>
/// Folder picker for "Move to" (Android: DriveFolderPicker): folders only, Drive's "My Drive" / "Shared with me"
/// chips, breadcrumbs, and the items being moved greyed out (they can't be entered or picked). "Move here" is
/// disabled at "Shared with me", at the top of This PC or a network server, and inside a disabled folder.
/// </summary>
internal sealed class MovePicker : DialogWindow
{
    private readonly string _account;
    private readonly IReadOnlySet<string> _disabled;
    private readonly List<(string Id, string Name)> _stack = new();
    private bool _shared;
    private readonly StackPanel _chips = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
    private readonly WrapPanel _crumbs = new() { Margin = new Thickness(0, 0, 0, 8) };
    private readonly StackPanel _list = new();
    private readonly ContentControl _state = new();
    private readonly TextBlock _current = Text("", "Text.BodySmall", null, wrap: false);
    private readonly DialogButton _moveHere = new("Move here", DialogButtonKind.Primary) { IsDefault = true };
    private CancellationTokenSource? _cts;

    private MovePicker(string account, IReadOnlySet<string> disabled, string? startFolder)
    {
        _account = account;
        _disabled = disabled;
        DialogTitle = "Move to";
        _stack.Add((AppServices.Storage.RootId(account), AppServices.Storage.RootName(account)));

        var subtitle = Text(Accounts.IsDrive(account) ? account : AppServices.Storage.RootName(account), "Text.BodySmall", Brush("TextMuted"), wrap: false);
        subtitle.Margin = new Thickness(0, -10, 0, 12);
        var scroll = new ScrollViewer
        {
            Content = _list,
            Height = 360,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var listHost = new Grid();
        listHost.Children.Add(scroll);
        listHost.Children.Add(_state);
        var frame = new Border
        {
            BorderBrush = Brush("Outline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Background = Brush("Surface"),
            Padding = new Thickness(6),
            Child = listHost,
        };
        _current.Foreground = Brush("TextMuted");
        _current.Margin = new Thickness(0, 12, 0, 0);
        var body = new StackPanel { Width = 540 };
        body.Children.Add(subtitle);
        if (Accounts.IsDrive(account)) body.Children.Add(_chips);
        body.Children.Add(_crumbs);
        body.Children.Add(frame);
        body.Children.Add(_current);
        Body = body;
        SetButtons(DialogButton.Cancel(), _moveHere);
        Loaded += (_, _) => _ = Load();
        _ = startFolder;
    }

    private (string Id, string Name) Current => _stack[^1];
    private bool AtSharedRoot => _shared && _stack.Count == 1;
    private bool AtPermanentRoot => !Accounts.IsDrive(_account) && _stack.Count == 1;

    private void RenderHeader()
    {
        _chips.Children.Clear();
        _chips.Children.Add(Chip("My Drive", !_shared, () => SetShared(false)));
        _chips.Children.Add(Chip("Shared with me", _shared, () => SetShared(true)));

        _crumbs.Children.Clear();
        for (var i = 0; i < _stack.Count; i++)
        {
            var index = i;
            if (i > 0) _crumbs.Children.Add(IconOf(Geo("ChevronRight"), 18, Brush("TextFaint")));
            var last = i == _stack.Count - 1;
            var b = new Button
            {
                Content = new TextBlock { Text = _stack[i].Name, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 },
                Style = FileUi.Style(last ? "Button.Text" : "Button.TextMuted"),
                Foreground = Brush(last ? "Text" : "TextMuted"),
            };
            b.Click += (_, _) =>
            {
                if (index >= _stack.Count - 1) return;
                _stack.RemoveRange(index + 1, _stack.Count - index - 1);
                _ = Load();
            };
            _crumbs.Children.Add(b);
        }
        _current.Text = $"Current folder: {Current.Name}";
        _moveHere.IsEnabled = !AtSharedRoot && !AtPermanentRoot && !_disabled.Contains(Current.Id);
    }

    private void SetShared(bool shared)
    {
        if (_shared == shared) return;
        _shared = shared;
        _stack.Clear();
        _stack.Add(shared ? (DriveFileSource.SharedRoot, "Shared with me") : (DriveFileSource.RootFolder, "My Drive"));
        _ = Load();
    }

    private async Task Load()
    {
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        RenderHeader();
        _list.Children.Clear();
        _state.Content = new Spinner { Width = 30, Height = 30, Thickness = 2.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        try
        {
            var items = await AppServices.Storage.List(_account, Current.Id, cts.Token);
            if (cts.IsCancellationRequested) return;
            var folders = items.Where(f => f.IsFolder).OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
            foreach (var f in folders) _list.Children.Add(Row(f));
            _state.Content = folders.Count == 0 ? Message("No subfolders", "You can pick this folder, or go back up.") : null;
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            _state.Content = Message("Couldn't load folders", FileUi.Message(e));
        }
    }

    private static FrameworkElement Message(string title, string text)
    {
        var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(24) };
        var t = Text(title, "Text.TitleSmall");
        t.TextAlignment = TextAlignment.Center;
        var m = Text(text, "Text.BodySmall", Brush("TextMuted"));
        m.TextAlignment = TextAlignment.Center;
        m.Margin = new Thickness(0, 4, 0, 0);
        s.Children.Add(t);
        s.Children.Add(m);
        return s;
    }

    private FrameworkElement Row(StorageItem folder)
    {
        var disabled = _disabled.Contains(folder.Id);
        var row = new DockPanel();
        var icon = IconOf(Geo("Folder"), 20, disabled ? Brush("TextFaint") : Brush("Amber"));
        icon.Margin = new Thickness(0, 0, 14, 0);
        row.Children.Add(icon);
        row.Children.Add(Text(folder.Name, "Text.BodyLarge", disabled ? Brush("TextFaint") : null, wrap: false));
        var b = new Button { Style = FileUi.Style("Button.Row"), Content = row, IsEnabled = !disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        b.Click += (_, _) =>
        {
            _stack.Add((folder.Id, folder.Name));
            _ = Load();
        };
        return b;
    }

    /// <summary>Returns the folder to move into, or null when cancelled.</summary>
    public static (string Id, string Name)? Pick(Window? owner, string account, IReadOnlySet<string> disabled, bool startShared = false)
    {
        var dlg = new MovePicker(account, disabled, null);
        if (startShared && Accounts.IsDrive(account))
        {
            dlg._shared = true;
            dlg._stack.Clear();
            dlg._stack.Add((DriveFileSource.SharedRoot, "Shared with me"));
        }
        var r = dlg.ShowModal(owner);
        dlg._cts?.Cancel();
        return r == dlg._moveHere ? dlg.Current : null;
    }
}
