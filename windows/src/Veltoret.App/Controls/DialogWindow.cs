using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Veltoret.App.Controls;

public enum DialogButtonKind { Text, Muted, Primary, Secondary, Danger }

/// <summary>
/// One button of a <see cref="DialogWindow"/>. <see cref="OnClick"/> may return false to keep the dialog open
/// (validation); while it runs the button shows a spinner.
/// </summary>
public sealed class DialogButton
{
    public DialogButton(string text, DialogButtonKind kind = DialogButtonKind.Text, Func<Task<bool>>? onClick = null)
    {
        Text = text;
        Kind = kind;
        OnClick = onClick;
    }

    public string Text { get; set; }
    public DialogButtonKind Kind { get; set; }
    public Func<Task<bool>>? OnClick { get; set; }
    /// <summary>Enter presses it.</summary>
    public bool IsDefault { get; set; }
    /// <summary>Esc presses it (a dialog without one closes on Esc with a null result).</summary>
    public bool IsCancel { get; set; }
    public object? Tag { get; set; }

    private bool _enabled = true;
    public bool IsEnabled
    {
        get => _enabled;
        set { _enabled = value; if (Control != null) Control.IsEnabled = value; }
    }

    /// <summary>The rendered button (null until the dialog is shown).</summary>
    public Button? Control { get; internal set; }

    public static DialogButton Cancel(string text = "Cancel") => new(text, DialogButtonKind.Muted) { IsCancel = true };
    public static DialogButton Ok(string text = "OK", Func<Task<bool>>? onClick = null) =>
        new(text, DialogButtonKind.Text, onClick) { IsDefault = true };
}

/// <summary>
/// Borderless dark modal window (Material AlertDialog look: SurfaceHigh, corner 20, hairline, title in serif).
/// Use <see cref="Show(Window?, string, FrameworkElement, DialogButton[])"/> or subclass it: set
/// <see cref="DialogTitle"/>, <see cref="Body"/> and <see cref="SetButtons"/> then <c>ShowDialog()</c>.
/// </summary>
public class DialogWindow : Window
{
    private readonly TextBlock _title;
    private readonly ContentControl _body;
    private readonly StackPanel _buttons;
    private readonly Border _frame;

    /// <summary>The button that closed the dialog; null when dismissed (Esc / click outside handlers).</summary>
    public DialogButton? Result { get; private set; }

    public DialogWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        UseLayoutRounding = true;
        FontFamily = (FontFamily)Application.Current.FindResource("Font.Sans");
        Foreground = (Brush)Application.Current.FindResource("Brush.Text");
        MinWidth = 360;
        MaxWidth = 720;

        _title = new TextBlock { Style = (Style)Application.Current.FindResource("Text.HeadlineSmall"), Margin = new Thickness(0, 0, 0, 16) };
        _body = new ContentControl { Focusable = false };
        _buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 24, -8, -8) };
        var stack = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_title, Dock.Top);
        DockPanel.SetDock(_buttons, Dock.Bottom);
        stack.Children.Add(_title);
        stack.Children.Add(_buttons);
        // The body scrolls when the dialog is taller than the screen (a tablet at 150 %, or with the touch keyboard open).
        var bodyScroll = new ScrollViewer
        {
            Content = _body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        stack.Children.Add(bodyScroll);
        _frame = new Border
        {
            Background = (Brush)Application.Current.FindResource("Brush.SurfaceHigh"),
            BorderBrush = (Brush)Application.Current.FindResource("Brush.Outline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(24, 22, 24, 20),
            Margin = new Thickness(12),
            Child = stack,
        };
        Content = _frame;
        _frame.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource == _frame || e.OriginalSource == stack || e.OriginalSource == _title) try { DragMove(); } catch (InvalidOperationException) { }
        };
        PreviewKeyDown += OnKey;
        // Content can grow after it opens (servers found, an error shown): stay on the screen.
        SizeChanged += (_, _) => { if (IsLoaded && _topBeforeKeyboard == null) FitToScreen(); };
        Loaded += (_, _) =>
        {
            FitToScreen();
            _frame.Opacity = 0;
            var s = new ScaleTransform(0.96, 0.96);
            _frame.RenderTransformOrigin = new Point(0.5, 0.5);
            _frame.RenderTransform = s;
            var d = TimeSpan.FromMilliseconds(160);
            _frame.BeginAnimation(OpacityProperty, new DoubleAnimation(1, d));
            s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, d) { EasingFunction = new CubicEase() });
            s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, d) { EasingFunction = new CubicEase() });
            // Focus the first focusable thing in the body, else the default button.
            if (_body.Content is UIElement el && el.MoveFocus(new TraversalRequest(FocusNavigationDirection.First))) return;
            _buttons.Children.OfType<Button>().LastOrDefault()?.Focus();
        };
    }

    private double? _topBeforeKeyboard;

    /// <summary>Never taller than the work area of the screen the dialog is on.</summary>
    private void FitToScreen()
    {
        var work = SystemParameters.WorkArea;
        MaxHeight = Math.Max(240, work.Height);
        if (double.IsNaN(Top)) return;
        if (Top + ActualHeight > work.Bottom) Top = Math.Max(work.Top, work.Bottom - ActualHeight);
        if (Top < work.Top) Top = work.Top;
    }

    /// <summary>
    /// The touch keyboard opened with its top edge at <paramref name="keyboardTop"/> (DIPs; null = it closed):
    /// move up so the dialog sits above it, and if it still doesn't fit, shrink it so the body scrolls.
    /// </summary>
    internal void AvoidKeyboard(double? keyboardTop)
    {
        var work = SystemParameters.WorkArea;
        if (keyboardTop is not { } kb || kb >= Top + ActualHeight)
        {
            if (keyboardTop == null && _topBeforeKeyboard is { } top)
            {
                MaxHeight = Math.Max(240, work.Height);
                Top = top;
                _topBeforeKeyboard = null;
            }
            return;
        }
        _topBeforeKeyboard ??= Top;
        var room = kb - work.Top;
        MaxHeight = Math.Max(200, room);
        Top = Math.Max(work.Top, kb - Math.Min(ActualHeight, MaxHeight));
    }

    public string DialogTitle
    {
        get => _title.Text;
        set { _title.Text = value; _title.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible; }
    }

    public object? Body { get => _body.Content; set => _body.Content = value; }

    /// <summary>Width of the content area; dialogs default to their content's width.</summary>
    public double BodyWidth { set => _body.Width = value; }

    private IReadOnlyList<DialogButton> _buttonDefs = Array.Empty<DialogButton>();

    public void SetButtons(params DialogButton[] buttons)
    {
        _buttonDefs = buttons;
        _buttons.Children.Clear();
        _buttons.Visibility = buttons.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var def in buttons)
        {
            var style = def.Kind switch
            {
                DialogButtonKind.Primary => "Button.Primary",
                DialogButtonKind.Secondary => "Button.Secondary",
                DialogButtonKind.Danger => "Button.Text",
                DialogButtonKind.Muted => "Button.TextMuted",
                _ => "Button.Text",
            };
            var b = new Button
            {
                Content = def.Text,
                Style = (Style)Application.Current.FindResource(style),
                Margin = new Thickness(8, 0, 0, 0),
                IsEnabled = def.IsEnabled,
                IsDefault = def.IsDefault,
                MinWidth = def.Kind is DialogButtonKind.Primary or DialogButtonKind.Secondary ? 0 : 64,
            };
            if (def.Kind is DialogButtonKind.Text or DialogButtonKind.Muted or DialogButtonKind.Danger) b.Padding = new Thickness(12, 10, 12, 10);
            if (def.Kind == DialogButtonKind.Danger) b.Foreground = (Brush)Application.Current.FindResource("Brush.Danger");
            def.Control = b;
            b.Click += async (_, _) => await Press(def);
            _buttons.Children.Add(b);
        }
    }

    private async Task Press(DialogButton def)
    {
        if (def.OnClick != null)
        {
            var b = def.Control;
            if (b != null) ButtonAssist.SetIsLoading(b, true);
            bool close;
            try { close = await def.OnClick(); }
            finally { if (b != null) ButtonAssist.SetIsLoading(b, false); }
            if (!close) return;
        }
        Finish(def);
    }

    /// <summary>Closes with <paramref name="result"/> (null = dismissed).</summary>
    public void Finish(DialogButton? result)
    {
        Result = result;
        try { DialogResult = result != null && !result.IsCancel; }
        catch (InvalidOperationException) { Close(); }
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        e.Handled = true;
        var cancel = _buttonDefs.FirstOrDefault(b => b.IsCancel);
        Finish(cancel);
    }

    /// <summary>A window to own dialogs: the given one, else the active window, else the main window.</summary>
    public static Window? ResolveOwner(Window? owner)
    {
        if (owner is { IsLoaded: true }) return owner;
        var active = Application.Current?.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive);
        if (active != null) return active;
        var main = Application.Current?.MainWindow;
        return main is { IsVisible: true } ? main : null;
    }

    /// <summary>Shows a modal dialog and returns the button that closed it (null if dismissed).</summary>
    public static DialogButton? Show(Window? owner, string title, FrameworkElement content, params DialogButton[] buttons)
    {
        var w = new DialogWindow { DialogTitle = title, Body = content };
        w.SetButtons(buttons);
        return w.ShowModal(owner);
    }

    /// <summary>Shows this dialog modally over <paramref name="owner"/>.</summary>
    public DialogButton? ShowModal(Window? owner)
    {
        var o = ResolveOwner(owner);
        if (o != null && o != this) Owner = o;
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowDialog();
        return Result;
    }

    /// <summary>A wrapped body paragraph (bodyMedium, TextMuted) for simple dialogs.</summary>
    public static TextBlock Message(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.FindResource("Text.BodyMedium"),
        Foreground = (Brush)Application.Current.FindResource("Brush.TextMuted"),
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 480,
    };
}

/// <summary>Yes/no confirmation.</summary>
public static class Confirm
{
    public static bool Ask(Window? owner, string title, string message, string confirmText, bool danger = false)
    {
        var ok = new DialogButton(confirmText, danger ? DialogButtonKind.Danger : DialogButtonKind.Text) { IsDefault = !danger };
        var result = DialogWindow.Show(owner, title, DialogWindow.Message(message), DialogButton.Cancel(), ok);
        return result == ok;
    }
}
