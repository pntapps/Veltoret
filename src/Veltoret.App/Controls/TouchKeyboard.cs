using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Veltoret.App.Controls;

/// <summary>
/// Keeps the field being typed in visible above the touch keyboard. Windows doesn't resize desktop windows for it,
/// so when it opens (IFrameworkInputPane) a dialog moves up (and scrolls if it's still too tall), and other windows
/// leave room at the bottom so their pages can scroll the field into view.
/// </summary>
public static class TouchKeyboard
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [ComImport, Guid("5752238B-24F0-495A-82F1-2FD593056796"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFrameworkInputPane
    {
        [PreserveSig] int Advise([MarshalAs(UnmanagedType.IUnknown)] object pWindow, IFrameworkInputPaneHandler pHandler, out int pdwCookie);
        [PreserveSig] int AdviseWithHWND(IntPtr hwnd, IFrameworkInputPaneHandler pHandler, out int pdwCookie);
        [PreserveSig] int Unadvise(int dwCookie);
        [PreserveSig] int Location(out RECT prcInputPaneScreenLocation);
    }

    [ComImport, Guid("226C537B-1E76-4D9E-A760-33DB29922F18"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFrameworkInputPaneHandler
    {
        [PreserveSig] int Showing(ref RECT prcInputPaneScreenLocation, int fEnsureFocusedElementInView);
        [PreserveSig] int Hiding(int fEnsureFocusedElementInView);
    }

    [ComVisible(true)]
    private sealed class Handler(Window window) : IFrameworkInputPaneHandler
    {
        public int Showing(ref RECT r, int ensureInView)
        {
            var rect = new Rect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            window.Dispatcher.BeginInvoke(() => Apply(window, rect));
            return 0;
        }

        public int Hiding(int ensureInView)
        {
            window.Dispatcher.BeginInvoke(() => Apply(window, null));
            return 0;
        }
    }

    private static IFrameworkInputPane? _pane;
    private static readonly Dictionary<Window, (int Cookie, Handler Handler)> Advised = new();

    /// <summary>The keyboard's area in screen pixels while it's open.</summary>
    public static Rect? Occluded { get; private set; }

    internal static void Install()
    {
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("D5120AA3-46BA-44C5-822D-CA8092C1FC72"));
            _pane = type != null ? Activator.CreateInstance(type) as IFrameworkInputPane : null;
        }
        catch (Exception) { _pane = null; } // no input pane service (Server Core, very old builds)
        if (_pane == null) return;
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler(OnWindowLoaded));
        EventManager.RegisterClassHandler(typeof(UIElement), Keyboard.GotKeyboardFocusEvent, new KeyboardFocusChangedEventHandler(OnFocus), true);
    }

    private static void OnWindowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Window w || Advised.ContainsKey(w) || _pane == null) return;
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        var handler = new Handler(w);
        try
        {
            if (_pane.AdviseWithHWND(hwnd, handler, out var cookie) != 0) return;
            Advised[w] = (cookie, handler);
            w.Closed += (_, _) =>
            {
                if (Advised.Remove(w, out var a)) try { _pane?.Unadvise(a.Cookie); } catch (Exception) { }
            };
        }
        catch (Exception) { }
    }

    /// <summary>Moving to another field while the keyboard is open keeps that one in view too.</summary>
    private static void OnFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (!ReferenceEquals(sender, e.NewFocus) || Occluded == null || e.NewFocus is not (TextBox or PasswordBox)) return;
        if (Window.GetWindow((DependencyObject)e.NewFocus) is { } w) Apply(w, Occluded);
    }

    private static readonly DependencyProperty SavedProperty = DependencyProperty.RegisterAttached(
        "Saved", typeof(Thickness?), typeof(TouchKeyboard), new PropertyMetadata(null));

    private static void Apply(Window window, Rect? keyboard)
    {
        Occluded = keyboard;
        if (!window.IsLoaded || PresentationSource.FromVisual(window) is not { CompositionTarget: { } target }) return;
        // Keyboard top edge in this window's DIPs (Top/Left units).
        double? top = keyboard is { } k ? target.TransformFromDevice.Transform(new Point(k.Left, k.Top)).Y : null;
        if (window is DialogWindow dialog)
        {
            dialog.AvoidKeyboard(top);
        }
        else if (window.Content is FrameworkElement root)
        {
            var saved = (Thickness?)root.GetValue(SavedProperty);
            var bottom = top is { } t && window.WindowState != WindowState.Minimized
                ? Math.Max(0, root.PointToScreenDip(window, root.ActualHeight) - t)
                : 0;
            if (bottom > 0)
            {
                saved ??= root.Margin;
                root.SetValue(SavedProperty, saved);
                root.Margin = new Thickness(saved.Value.Left, saved.Value.Top, saved.Value.Right, saved.Value.Bottom + bottom);
            }
            else if (saved is { } s)
            {
                root.Margin = s;
                root.ClearValue(SavedProperty);
            }
        }
        BringFocusedIntoView(window);
    }

    /// <summary>Bottom edge of <paramref name="root"/> (at <paramref name="y"/>) in screen DIPs.</summary>
    private static double PointToScreenDip(this FrameworkElement root, Window window, double y)
    {
        var px = root.PointToScreen(new Point(0, y));
        return PresentationSource.FromVisual(window)!.CompositionTarget!.TransformFromDevice.Transform(px).Y;
    }

    private static void BringFocusedIntoView(Window window) =>
        window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (Keyboard.FocusedElement is FrameworkElement f && Window.GetWindow(f) == window && f is TextBox or PasswordBox)
                f.BringIntoView(new Rect(-8, -24, f.ActualWidth + 16, f.ActualHeight + 48));
        });
}
