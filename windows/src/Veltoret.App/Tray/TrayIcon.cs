using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Veltoret.App.Tray;

/// <summary>
/// Veltoret's icon in the notification area (Shell_NotifyIcon, no WinForms). Click opens the window; the right-click
/// menu has Open Veltoret, Scan library and Quit. Its hidden window also hears the PC resuming and clock changes
/// (<see cref="Resumed"/>), and puts the icon back when Explorer restarts.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private const int CallbackMessage = 0x8000 + 0x56; // WM_APP + 'V'
    private const int WmLButtonUp = 0x0202, WmLButtonDblClk = 0x0203, WmRButtonUp = 0x0205, WmContextMenu = 0x007B;
    private const int WmPowerBroadcast = 0x0218, PbtApmResumeAutomatic = 0x0012, PbtApmResumeSuspend = 0x0007, WmTimeChange = 0x001E;
    private const int NimAdd = 0, NimModify = 1, NimDelete = 2;
    private const int NifMessage = 1, NifIcon = 2, NifTip = 4;

    private readonly HwndSource _window;
    private readonly int _taskbarCreated;
    private readonly IntPtr _icon;
    private readonly string _tip;
    private ContextMenu? _menu;
    private bool _added;

    /// <summary>Clicked, or "Open Veltoret".</summary>
    public event Action? OpenRequested;
    public event Action? ScanRequested;
    public event Action? QuitRequested;
    /// <summary>The PC woke up or the clock changed (reminders get re-checked).</summary>
    public event Action? Resumed;

    public TrayIcon(string tip = "Veltoret")
    {
        _tip = tip;
        _window = new HwndSource(new HwndSourceParameters("VeltoretTray")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0, // hidden top-level window: broadcasts (TaskbarCreated, power) reach it, unlike HWND_MESSAGE
            ExtendedWindowStyle = 0x80, // WS_EX_TOOLWINDOW
        });
        _window.AddHook(WndProc);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        _icon = CreateIcon();
        Add();
    }

    private void Add()
    {
        var data = Data(NifMessage | NifIcon | NifTip);
        _added = Shell_NotifyIcon(NimAdd, ref data) || Shell_NotifyIcon(NimModify, ref data);
    }

    private NotifyIconData Data(int flags) => new()
    {
        cbSize = Marshal.SizeOf<NotifyIconData>(),
        hWnd = _window.Handle,
        uID = 1,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = _tip,
        szInfo = "",
        szInfoTitle = "",
    };

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            switch ((int)(lParam.ToInt64() & 0xFFFF))
            {
                case WmLButtonUp:
                case WmLButtonDblClk:
                    OpenRequested?.Invoke();
                    break;
                case WmRButtonUp:
                case WmContextMenu:
                    ShowMenu();
                    break;
            }
            handled = true;
        }
        else if (msg == _taskbarCreated && _taskbarCreated != 0)
        {
            Add();
        }
        else if (msg == WmPowerBroadcast && (wParam.ToInt64() == PbtApmResumeAutomatic || wParam.ToInt64() == PbtApmResumeSuspend))
        {
            Resumed?.Invoke();
        }
        else if (msg == WmTimeChange)
        {
            Resumed?.Invoke();
        }
        return IntPtr.Zero;
    }

    private void ShowMenu()
    {
        if (_menu == null)
        {
            _menu = new ContextMenu { Placement = PlacementMode.MousePoint };
            if (Application.Current.TryFindResource("ContextMenu") is Style ms) _menu.Style = ms;
            _menu.Items.Add(Item("Open Veltoret", () => OpenRequested?.Invoke()));
            _menu.Items.Add(Item("Scan library", () => ScanRequested?.Invoke()));
            _menu.Items.Add(new Separator());
            _menu.Items.Add(Item("Quit", () => QuitRequested?.Invoke()));
            // A menu that isn't in the foreground wouldn't close when the user clicks elsewhere.
            _menu.Opened += (_, _) =>
            {
                if (PresentationSource.FromVisual(_menu) is HwndSource src) SetForegroundWindow(src.Handle);
            };
        }
        _menu.IsOpen = false;
        _menu.IsOpen = true;
    }

    private static MenuItem Item(string text, Action onClick)
    {
        var item = new MenuItem { Header = text };
        if (Application.Current.TryFindResource("MenuItem") is Style s) item.Style = s;
        item.Click += (_, _) => onClick();
        return item;
    }

    /// <summary>Veltoret.ico at the small-icon size for this DPI; a drawn mark if it can't be loaded.</summary>
    private static IntPtr CreateIcon()
    {
        var size = Math.Max(16, GetSystemMetrics(49 /* SM_CXSMICON */));
        try
        {
            var info = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Veltoret.ico"));
            if (info != null)
            {
                var file = Path.Combine(Veltoret.Core.AppPaths.Root, "tray.ico");
                Directory.CreateDirectory(Veltoret.Core.AppPaths.Root);
                using (var s = info.Stream)
                using (var o = File.Create(file))
                    s.CopyTo(o);
                var h = LoadImage(IntPtr.Zero, file, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */);
                if (h != IntPtr.Zero) return h;
            }
        }
        catch (Exception) { }
        return DrawIcon(size);
    }

    /// <summary>The app mark: an amber rounded square with a dark "V".</summary>
    private static IntPtr DrawIcon(int size)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var s = size / 32.0;
            dc.PushTransform(new ScaleTransform(s, s));
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(0xE8, 0xA3, 0x3D)), null, new Rect(1, 1, 30, 30), 8, 8);
            var v = Geometry.Parse("M 8.5,8.5 L 16,24 L 23.5,8.5");
            dc.DrawGeometry(null, new Pen(new SolidColorBrush(Color.FromRgb(0x1B, 0x12, 0x06)), 4.2)
            {
                StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round,
            }, v);
            dc.Pop();
        }
        var rtb = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);
        var bgra = new FormatConvertedBitmap(rtb, PixelFormats.Bgra32, null, 0);
        var pixels = new byte[size * size * 4];
        bgra.CopyPixels(pixels, size * 4, 0);

        var maskStride = ((size + 15) / 16) * 2;
        var color = CreateBitmap(size, size, 1, 32, pixels);
        var mask = CreateBitmap(size, size, 1, 1, new byte[maskStride * size]);
        var info = new IconInfo { fIcon = true, hbmColor = color, hbmMask = mask };
        var icon = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return icon;
    }

    public void Dispose()
    {
        if (_added)
        {
            var data = Data(0);
            Shell_NotifyIcon(NimDelete, ref data);
            _added = false;
        }
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        _window.Dispose();
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int cbSize;
        public IntPtr hWnd;
        public int uID;
        public int uFlags;
        public int uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState;
        public int dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo
    {
        [MarshalAs(UnmanagedType.Bool)] public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIcon(int message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterWindowMessageW")]
    private static extern int RegisterWindowMessage(string name);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern IntPtr CreateIconIndirect(ref IconInfo info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadImageW")]
    private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint load);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, byte[] bits);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr obj);
}
