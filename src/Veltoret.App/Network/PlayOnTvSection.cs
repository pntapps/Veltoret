using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Cast;
using Veltoret.Core.TvLink;

namespace Veltoret.App.Network;

/// <summary>
/// Settings → Play on TV: the TVs this PC is paired with (Forget), and "Pair with a TV" (find Veltoret TVs on the
/// network, then enter the 6-digit code the TV shows).
/// </summary>
public sealed class PlayOnTvSection : UserControl
{
    private readonly StackPanel _list = new();

    public PlayOnTvSection()
    {
        var root = new StackPanel();
        var intro = UiKit.Text(
            "Send what you watch to Veltoret on an Android TV, with every audio track and subtitle. The TV plays its own copy when it has one, or streams from this PC.",
            "Text.BodyMedium", "TextMuted");
        intro.Margin = new Thickness(0, 0, 0, 12);
        intro.MaxWidth = 640;
        intro.HorizontalAlignment = HorizontalAlignment.Left;
        root.Children.Add(intro);
        root.Children.Add(_list);
        var pair = UiKit.Button("Pair with a TV", "Button.Secondary");
        ButtonAssist.SetIcon(pair, CastIcons.Tv);
        pair.HorizontalAlignment = HorizontalAlignment.Left;
        pair.Margin = new Thickness(0, 4, 0, 0);
        pair.Click += (_, _) =>
        {
            PlayOnTvPairDialog.Run(Window.GetWindow(this));
            Refresh();
        };
        root.Children.Add(pair);
        Content = root;

        Loaded += (_, _) =>
        {
            AppServices.TvLinks.Changed += OnChanged;
            Refresh();
        };
        Unloaded += (_, _) => AppServices.TvLinks.Changed -= OnChanged;
    }

    private void OnChanged() => Dispatcher.BeginInvoke(Refresh);

    private void Refresh()
    {
        _list.Children.Clear();
        var peers = AppServices.TvLinks.Peers;
        if (peers.Count == 0) return;
        var panel = new StackPanel();
        for (var i = 0; i < peers.Count; i++)
        {
            var peer = peers[i];
            if (i > 0) panel.Children.Add(UiKit.Divider());
            var row = new DockPanel { Margin = new Thickness(16, 12, 8, 12) };
            var icon = new Border
            {
                Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Background = UiKit.Brush("AmberDim"),
                Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center,
                Child = new Icon { Data = CastIcons.Tv, Size = 20, Fill = UiKit.Brush("Amber"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            };
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            var forget = UiKit.Button("Forget", "Button.TextMuted");
            forget.VerticalAlignment = VerticalAlignment.Center;
            forget.Click += async (_, _) =>
            {
                if (!Confirm.Ask(Window.GetWindow(this), $"Forget {peer.Name}?",
                        "To play on it again, you'll pair with the code it shows.", "Forget", danger: true)) return;
                var cast = AppServices.Cast;
                if (cast.State.Link?.Id == peer.Id)
                {
                    try { await cast.Disconnect(); } catch (Exception e) { App.Log(e); }
                }
                cast.TvLink.Forget(peer.Id);
                cast.RefreshPairing();
            };
            DockPanel.SetDock(forget, Dock.Right);
            row.Children.Add(forget);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(UiKit.Text(peer.Name, "Text.TitleMedium", maxLines: 1));
            text.Children.Add(UiKit.Text("Paired · all audio tracks and subtitles", "Text.BodySmall", "TextMuted", maxLines: 1));
            row.Children.Add(text);
            panel.Children.Add(row);
        }
        _list.Children.Add(new Border { Style = UiKit.Style("Panel"), Child = panel, Margin = new Thickness(0, 0, 0, 12) });
    }
}

/// <summary>Finds Veltoret TVs and pairs with one using the code it shows (no casting starts).</summary>
public sealed class PlayOnTvPairDialog : DialogWindow
{
    private readonly StackPanel _body = new() { MinWidth = 380, MaxWidth = 440 };
    private CastDevice? _target;
    private TextBox? _code;
    private bool _busy;
    private string? _message;

    public static void Run(Window? owner) => new PlayOnTvPairDialog().ShowModal(owner);

    private PlayOnTvPairDialog()
    {
        var cast = AppServices.Cast;
        cast.StartDiscovery();
        cast.DevicesChanged += OnDevices;
        Closed += (_, _) =>
        {
            cast.DevicesChanged -= OnDevices;
            cast.StopDiscovery();
        };
        Body = _body;
        Render();
    }

    private void OnDevices() => Dispatcher.BeginInvoke(() => { if (_target == null) Render(); });

    private void Render()
    {
        _body.Children.Clear();
        if (_target is { } tv)
        {
            DialogTitle = $"Pair with {tv.Name}";
            _body.Children.Add(UiKit.Text($"Enter the 6-digit code shown on {tv.Name}. You only do this once.", "Text.BodyMedium", "TextMuted"));
            _code = new TextBox { Style = UiKit.Style("TextBox"), MaxLength = 6, Margin = new Thickness(0, 14, 0, 0), FontSize = 20 };
            ButtonAssist.SetPlaceholder(_code, "Code");
            InputMethod.SetIsInputMethodEnabled(_code, false);
            _code.PreviewTextInput += (_, e) => e.Handled = !e.Text.All(char.IsAsciiDigit);
            var pair = new DialogButton("Pair", DialogButtonKind.Text, async () => { await Pair(tv); return false; }) { IsDefault = true, IsEnabled = false };
            _code.TextChanged += (_, _) =>
            {
                pair.IsEnabled = _code.Text.Length == 6 && !_busy;
                if (_code.Text.Length == 6 && !_busy) _ = Pair(tv);
            };
            _body.Children.Add(_code);
            AddMessage();
            var back = new DialogButton("Back", DialogButtonKind.Muted, () =>
            {
                _target = null;
                _message = null;
                Render();
                return Task.FromResult(false);
            });
            SetButtons(back, pair);
            Dispatcher.BeginInvoke(() => _code?.Focus(), System.Windows.Threading.DispatcherPriority.Input);
            return;
        }

        DialogTitle = "Pair with a TV";
        var tvs = AppServices.Cast.Devices.Where(d => d.Kind == CastDeviceKind.Veltoret).ToList();
        if (tvs.Count == 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new Spinner { Width = 20, Height = 20, Thickness = 2, Stroke = UiKit.Brush("Amber"), Margin = new Thickness(0, 0, 14, 0) });
            var t = UiKit.Text("Looking for TVs…", "Text.BodyLarge", wrap: false);
            t.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(t);
            _body.Children.Add(row);
            var hint = UiKit.Text("Open Veltoret on the TV and turn on \"Play from your phone\" in its settings. This PC and the TV must be on the same network.",
                "Text.BodySmall", "TextMuted");
            hint.Margin = new Thickness(0, 14, 0, 0);
            _body.Children.Add(hint);
        }
        foreach (var tv2 in tvs)
        {
            var device = tv2;
            var row = new DockPanel();
            var i = new Icon { Data = CastIcons.Tv, Size = 24, Fill = UiKit.Brush("Amber"), Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(i, Dock.Left);
            row.Children.Add(i);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(UiKit.Text(device.Name, "Text.TitleMedium", maxLines: 1));
            text.Children.Add(UiKit.Text(device.Paired ? "Paired" : "Veltoret · pair once with a code", "Text.BodySmall", "TextMuted", maxLines: 1));
            row.Children.Add(text);
            var b = new Button { Style = UiKit.Style("Button.Row"), Content = row, Padding = new Thickness(6, 12, 6, 12), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            b.Click += async (_, _) => await Start(device);
            _body.Children.Add(b);
        }
        if (_busy)
            _body.Children.Add(new Spinner { Width = 20, Height = 20, Thickness = 2, Stroke = UiKit.Brush("Amber"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(6, 10, 0, 0) });
        AddMessage();
        SetButtons(DialogButton.Cancel("Close"));
    }

    private void AddMessage()
    {
        if (_message == null) return;
        var t = UiKit.Text(_message, "Text.BodySmall", "Danger");
        t.Margin = new Thickness(0, 10, 0, 0);
        _body.Children.Add(t);
    }

    private async Task Start(CastDevice tv)
    {
        if (_busy) return;
        _busy = true;
        _message = null;
        Render();
        try
        {
            await AppServices.Cast.TvLink.StartPairing(tv.AsLinkTv());
            _target = tv;
        }
        catch (LinkException e) { _message = e.Message; }
        catch (Exception e)
        {
            App.Log(e);
            _message = $"Couldn't reach {tv.Name}. Check it's on and on the same Wi-Fi.";
        }
        finally { _busy = false; }
        Render();
    }

    private async Task Pair(CastDevice tv)
    {
        var code = _code?.Text ?? "";
        if (_busy || code.Length != 6) return;
        _busy = true;
        _message = null;
        if (_code != null) _code.IsEnabled = false;
        try
        {
            await AppServices.Cast.TvLink.Pair(tv.AsLinkTv(), code);
            AppServices.Cast.RefreshPairing();
            _busy = false;
            Toast.Show($"Paired with {tv.Name}");
            Finish(new DialogButton("ok"));
            return;
        }
        catch (LinkException e) { _message = e.Message; }
        catch (Exception e)
        {
            App.Log(e);
            _message = $"Couldn't pair with {tv.Name}";
        }
        finally { _busy = false; }
        Render();
    }
}
