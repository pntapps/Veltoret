using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Cast;

namespace Veltoret.App.Network;

/// <summary>
/// The Cast button: amber while connected. Opens the cast panel (device picker, pairing, and the remote while
/// casting). Placed in the player's CastButtonHost and on Home.
/// </summary>
public sealed class CastButton : UserControl
{
    private readonly Button _button;
    private readonly Icon _icon;

    /// <param name="onImage">Over video or artwork (the player's top bar): a dimmed disc instead of a surface one.</param>
    public CastButton(bool onImage = false, double size = 42)
    {
        _icon = new Icon { Data = CastIcons.Cast, Size = size * 0.5 };
        _button = new Button { Style = UiKit.Style(onImage ? "Button.IconOnImage" : "Button.Icon"), Width = size, Height = size, Content = _icon };
        _button.Click += (_, _) => CastPanel.Open(Window.GetWindow(this));
        Content = _button;
        Focusable = false;
        Loaded += (_, _) =>
        {
            AppServices.Cast.StateChanged += OnState;
            Apply(AppServices.Cast.State);
        };
        Unloaded += (_, _) => AppServices.Cast.StateChanged -= OnState;
        Apply(AppServices.Cast?.State ?? new CastState());
    }

    public CastButton() : this(false) { }

    private void OnState(CastState s) => Dispatcher.BeginInvoke(() => Apply(s));

    private void Apply(CastState s)
    {
        _icon.Data = s.Connected ? CastIcons.CastConnected : CastIcons.Cast;
        var label = s.Connected ? $"Casting to {s.DeviceName ?? "TV"}" : s.Connecting ? $"Connecting to {s.DeviceName ?? "TV"}…" : "Cast to a TV";
        _button.ToolTip = label;
        System.Windows.Automation.AutomationProperties.SetName(_button, label);
        _button.Foreground = s.Connected || s.Connecting ? UiKit.Brush("Amber") : UiKit.Brush("Text");
    }
}
