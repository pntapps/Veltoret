using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Veltoret.App.Shell;

/// <summary>Dark caption (Windows 10 2004+: immersive dark mode; Windows 11: caption color = page background).</summary>
public static class DarkTitleBar
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
    private const int DWMWA_CAPTION_COLOR = 35;
    private const int DWMWA_TEXT_COLOR = 36;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// <summary>Call from SourceInitialized (or any time after the handle exists).</summary>
    public static void Apply(Window window, uint captionRgb = 0x0B0B0D, uint textRgb = 0xF3EFE6)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        try
        {
            var on = 1;
            if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref on, sizeof(int));
            var caption = ToColorRef(captionRgb);
            DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
            var text = ToColorRef(textRgb);
            DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, ref text, sizeof(int));
        }
        catch (Exception) { /* older Windows: keep the default caption */ }
    }

    /// <summary>Applies the dark caption to <paramref name="window"/> once its handle exists.</summary>
    public static void Attach(Window window)
    {
        if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Apply(window);
        else window.SourceInitialized += (_, _) => Apply(window);
    }

    // COLORREF is 0x00BBGGRR.
    private static int ToColorRef(uint rgb) => (int)(((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF));
}
