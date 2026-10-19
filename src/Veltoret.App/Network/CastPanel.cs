using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Cast;
using Veltoret.Core.TvLink;

namespace Veltoret.App.Network;

/// <summary>
/// The cast panel (Android CastDialog + CastingScreen): lists TVs on the network, Veltoret TVs first ("Play on TV":
/// every audio track and subtitle, pairs with a code once), then Chromecasts. A TV that has both shows once, as
/// Veltoret, with "Use Chromecast instead". While connected it is the remote. Modeless, one at a time.
/// </summary>
public sealed class CastPanel : DialogWindow
{
    private static CastPanel? _open;

    private readonly StackPanel _picker = new() { MinWidth = 380 };
    private CastRemote? _remote;
    private CastDevice? _pairing;
    private TextBox? _code;
    private bool _busy;
    private string? _message;
    private bool _showAllChromecasts;
    private string _mode = "";

    public static void Open(Window? owner)
    {
        if (_open != null)
        {
            _open.Activate();
            return;
        }
        var panel = new CastPanel();
        var o = ResolveOwner(owner);
        if (o != null) panel.Owner = o;
        else panel.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _open = panel;
        panel.Show();
    }

    private CastPanel()
    {
        var cast = AppServices.Cast;
        cast.StartDiscovery();
        cast.DevicesChanged += OnDevices;
        cast.StateChanged += OnState;
        Closed += (_, _) =>
        {
            cast.DevicesChanged -= OnDevices;
            cast.StateChanged -= OnState;
            cast.StopDiscovery();
            _open = null;
        };
        Render();
    }

    private void OnDevices() => Dispatcher.BeginInvoke(() => { if (_mode == "picker") Render(); });

    private void OnState(CastState s) => Dispatcher.BeginInvoke(() =>
    {
        // The remote updates itself; switch screens only when connecting or disconnecting.
        var mode = ModeFor(s);
        if (mode != _mode || mode == "picker") Render();
    });

    private string ModeFor(CastState s) => s.Connected ? "remote" : _pairing != null ? "pairing" : "picker";

    private void Render()
    {
        var s = AppServices.Cast.State;
        _mode = ModeFor(s);
        switch (_mode)
        {
            case "remote":
                DialogTitle = "Casting";
                _remote ??= new CastRemote();
                Body = _remote;
                SetButtons(new DialogButton("Close", DialogButtonKind.Text) { IsCancel = true, IsDefault = true });
                break;
            case "pairing":
                RenderPairing(_pairing!);
                break;
            default:
                RenderPicker(s);
                break;
        }
    }

    // ---- Device list --------------------------------------------------------------------------------

    private void RenderPicker(CastState s)
    {
        DialogTitle = "Cast to";
        _picker.Children.Clear();
        var devices = AppServices.Cast.Devices;
        var tvs = devices.Where(d => d.Kind == CastDeviceKind.Veltoret).ToList();
        var chromecasts = devices.Where(d => d.Kind == CastDeviceKind.Chromecast).ToList();
        var linkNames = tvs.Select(t => t.Name.ToLowerInvariant()).ToHashSet();
        var hidden = chromecasts.Where(c => linkNames.Contains(c.Name.ToLowerInvariant())).ToList();
        var shown = _showAllChromecasts ? chromecasts : chromecasts.Except(hidden).ToList();

        if (s.Connecting)
        {
            _picker.Children.Add(BusyRow($"Connecting to {s.DeviceName ?? "the TV"}…"));
        }
        else if (devices.Count == 0)
        {
            _picker.Children.Add(BusyRow("Looking for TVs…"));
            var hint = UiKit.Text("This PC and the TV or Chromecast must be on the same network.", "Text.BodySmall", "TextMuted");
            hint.Margin = new Thickness(0, 14, 0, 0);
            _picker.Children.Add(hint);
        }
        else
        {
            foreach (var tv in tvs) _picker.Children.Add(DeviceRow(CastIcons.Tv, tv.Name, tv.Detail, () => _ = Choose(tv)));
            foreach (var c in shown)
                _picker.Children.Add(DeviceRow(CastIcons.Cast, c.Name, "Chromecast", () => _ = Choose(c)));
            if (hidden.Count > 0 && !_showAllChromecasts)
            {
                var more = UiKit.Button("Use Chromecast instead", "Button.TextMuted");
                more.HorizontalAlignment = HorizontalAlignment.Left;
                more.Click += (_, _) => { _showAllChromecasts = true; Render(); };
                _picker.Children.Add(more);
            }
        }
        if (_busy && !s.Connecting) _picker.Children.Add(Spin());
        var error = _message ?? s.Error;
        if (error != null)
        {
            var t = UiKit.Text(error, "Text.BodySmall", "Danger");
            t.Margin = new Thickness(0, 10, 0, 0);
            t.MaxWidth = 420;
            _picker.Children.Add(t);
        }
        Body = _picker;
        SetButtons(DialogButton.Cancel());
    }

    private static FrameworkElement BusyRow(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new Spinner { Width = 20, Height = 20, Thickness = 2, Stroke = UiKit.Brush("Amber"), Margin = new Thickness(0, 0, 14, 0) });
        var t = UiKit.Text(text, "Text.BodyLarge", wrap: false);
        t.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(t);
        return row;
    }

    private static FrameworkElement Spin() => new Spinner
    {
        Width = 20, Height = 20, Thickness = 2, Stroke = UiKit.Brush("Amber"),
        HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(6, 10, 0, 0),
    };

    private static Button DeviceRow(Geometry icon, string name, string detail, Action onClick)
    {
        var row = new DockPanel();
        var i = new Icon { Data = icon, Size = 24, Fill = UiKit.Brush("Amber"), Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(i, Dock.Left);
        row.Children.Add(i);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(UiKit.Text(name, "Text.TitleMedium", maxLines: 1));
        text.Children.Add(UiKit.Text(detail, "Text.BodySmall", "TextMuted", maxLines: 1));
        row.Children.Add(text);
        var b = new Button { Style = UiKit.Style("Button.Row"), Content = row, Padding = new Thickness(6, 12, 6, 12), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        b.Click += (_, _) => onClick();
        return b;
    }

    private async Task Choose(CastDevice device)
    {
        if (_busy) return;
        _message = null;
        var cast = AppServices.Cast;
        if (device.Kind == CastDeviceKind.Chromecast || cast.TvLink.Store.Secret(device.Id) != null)
        {
            try { await cast.Connect(device); }
            catch (Exception e) { _message = e.Message; }
            Render();
            return;
        }
        _busy = true;
        Render();
        try
        {
            await cast.TvLink.StartPairing(device.AsLinkTv());
            _pairing = device;
        }
        catch (LinkException e)
        {
            _message = e.Message;
        }
        catch (Exception e)
        {
            App.Log(e);
            _message = $"Couldn't reach {device.Name}. Check it's on and on the same Wi-Fi.";
        }
        finally
        {
            _busy = false;
        }
        Render();
    }

    // ---- Pairing ------------------------------------------------------------------------------------

    private void RenderPairing(CastDevice tv)
    {
        DialogTitle = $"Pair with {tv.Name}";
        var body = new StackPanel { MinWidth = 380, MaxWidth = 440 };
        body.Children.Add(UiKit.Text($"Enter the 6-digit code shown on {tv.Name}. You only do this once.", "Text.BodyMedium", "TextMuted"));
        _code = new TextBox { Style = UiKit.Style("TextBox"), MaxLength = 6, Margin = new Thickness(0, 14, 0, 0), FontSize = 20 };
        ButtonAssist.SetPlaceholder(_code, "Code");
        InputMethod.SetIsInputMethodEnabled(_code, false);
        _code.PreviewTextInput += (_, e) => e.Handled = !e.Text.All(char.IsAsciiDigit);
        DataObject.AddPastingHandler(_code, (_, e) =>
        {
            if (e.DataObject.GetData(typeof(string)) is string text)
            {
                var digits = new string(text.Where(char.IsAsciiDigit).Take(6).ToArray());
                e.CancelCommand();
                _code.Text = digits;
                _code.CaretIndex = digits.Length;
            }
        });
        var pair = new DialogButton("Pair", DialogButtonKind.Text, async () => { await Pair(tv); return false; }) { IsDefault = true, IsEnabled = false };
        _code.TextChanged += (_, _) =>
        {
            pair.IsEnabled = _code.Text.Length == 6 && !_busy;
            if (_code.Text.Length == 6 && !_busy) _ = Pair(tv);
        };
        body.Children.Add(_code);
        if (_message != null)
        {
            var t = UiKit.Text(_message, "Text.BodySmall", "Danger");
            t.Margin = new Thickness(0, 10, 0, 0);
            body.Children.Add(t);
        }
        Body = body;
        var back = new DialogButton("Back", DialogButtonKind.Muted, () =>
        {
            _pairing = null;
            _message = null;
            Render();
            return Task.FromResult(false);
        });
        SetButtons(back, pair);
        Dispatcher.BeginInvoke(() => _code?.Focus(), System.Windows.Threading.DispatcherPriority.Input);
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
            _pairing = null;
            AppServices.Cast.RefreshPairing();
            await AppServices.Cast.Connect(tv with { Paired = true });
        }
        catch (LinkException e)
        {
            // A wrong code: the TV shows a new one, so start over with an empty field.
            _message = e.Message;
        }
        catch (Exception e)
        {
            App.Log(e);
            _message = $"Couldn't pair with {tv.Name}";
        }
        finally
        {
            _busy = false;
        }
        Render();
    }
}
