using System.Runtime.InteropServices;

namespace Veltoret.App.Player;

/// <summary>
/// HDR on the display a window is on (Windows display configuration API, the same switch as Settings → Display →
/// "Use HDR"). Windows 11 24H2+ has a separate HDR switch (GET_ADVANCED_COLOR_INFO_2 / SET_HDR_STATE); earlier builds
/// use "advanced color". libVLC's Direct3D 11 output sends HDR10 to the display by itself once Windows is in HDR mode.
/// </summary>
internal static class HdrDisplay
{
    public readonly record struct Target(LUID Adapter, uint Id);

    public readonly record struct State(Target Target, bool Supported, bool Enabled);

    /// <summary>The HDR state of the display <paramref name="hwnd"/> is mostly on, or null if it can't be told.</summary>
    public static State? ForWindow(IntPtr hwnd)
    {
        try
        {
            var monitor = MonitorFromWindow(hwnd, 2 /* MONITOR_DEFAULTTONEAREST */);
            var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (!GetMonitorInfo(monitor, ref info)) return null;
            foreach (var (source, target) in ActivePaths())
            {
                var name = new DISPLAYCONFIG_SOURCE_DEVICE_NAME
                {
                    header = Header(1 /* GET_SOURCE_NAME */, Marshal.SizeOf<DISPLAYCONFIG_SOURCE_DEVICE_NAME>(), source.Adapter, source.Id),
                };
                if (DisplayConfigGetDeviceInfo(ref name) != 0) continue;
                if (!string.Equals(name.viewGdiDeviceName, info.szDevice, StringComparison.OrdinalIgnoreCase)) continue;
                return Query(target);
            }
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
        return null;
    }

    /// <summary>True if any connected display can show HDR (Settings shows the HDR option only then).</summary>
    public static bool AnySupported()
    {
        try { return ActivePaths().Any(p => Query(p.Target) is { Supported: true }); }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return false; }
    }

    private static State? Query(Target t)
    {
        var info2 = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2
        {
            header = Header(15 /* GET_ADVANCED_COLOR_INFO_2 */, Marshal.SizeOf<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2>(), t.Adapter, t.Id),
        };
        if (DisplayConfigGetDeviceInfo(ref info2) == 0)
        {
            // bit 4 highDynamicRangeSupported, bit 5 highDynamicRangeUserEnabled; activeColorMode 2 = HDR.
            var supported = (info2.value & (1 << 4)) != 0;
            return new State(t, supported, supported && (info2.activeColorMode == 2 || (info2.value & (1 << 5)) != 0));
        }
        var info = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO
        {
            header = Header(9 /* GET_ADVANCED_COLOR_INFO */, Marshal.SizeOf<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO>(), t.Adapter, t.Id),
        };
        if (DisplayConfigGetDeviceInfo(ref info) != 0) return null;
        // bit 0 advancedColorSupported, bit 1 advancedColorEnabled, bit 3 advancedColorForceDisabled.
        var ok = (info.value & 1) != 0 && (info.value & (1 << 3)) == 0;
        return new State(t, ok, ok && (info.value & 2) != 0);
    }

    /// <summary>Turns HDR on or off for the display; true if Windows accepted it.</summary>
    public static bool Set(Target t, bool on)
    {
        try
        {
            var hdr = new DISPLAYCONFIG_SET_STATE
            {
                header = Header(16 /* SET_HDR_STATE */, Marshal.SizeOf<DISPLAYCONFIG_SET_STATE>(), t.Adapter, t.Id),
                value = on ? 1u : 0u,
            };
            if (DisplayConfigSetDeviceInfo(ref hdr) == 0) return true;
            var advanced = new DISPLAYCONFIG_SET_STATE
            {
                header = Header(10 /* SET_ADVANCED_COLOR_STATE */, Marshal.SizeOf<DISPLAYCONFIG_SET_STATE>(), t.Adapter, t.Id),
                value = on ? 1u : 0u,
            };
            return DisplayConfigSetDeviceInfo(ref advanced) == 0;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return false; }
    }

    private static IEnumerable<(Target Source, Target Target)> ActivePaths()
    {
        const uint QdcOnlyActivePaths = 2;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (GetDisplayConfigBufferSizes(QdcOnlyActivePaths, out var pathCount, out var modeCount) != 0) yield break;
            var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            var r = QueryDisplayConfig(QdcOnlyActivePaths, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            if (r == 122 /* ERROR_INSUFFICIENT_BUFFER: displays changed meanwhile */) continue;
            if (r != 0) yield break;
            for (var i = 0; i < pathCount; i++)
                yield return (new Target(paths[i].sourceAdapter, paths[i].sourceId), new Target(paths[i].targetAdapter, paths[i].targetId));
            yield break;
        }
    }

    private static DISPLAYCONFIG_DEVICE_INFO_HEADER Header(int type, int size, LUID adapter, uint id) =>
        new() { type = type, size = (uint)size, adapterId = adapter, id = id };

    // ---------------------------------------------------------------------------------------------
    // Interop (wingdi.h)

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_DEVICE_INFO_HEADER { public int type; public uint size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint value;
        public int colorEncoding;
        public uint bitsPerColorChannel;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint value;
        public int colorEncoding;
        public uint bitsPerColorChannel;
        public int activeColorMode;
    }

    /// <summary>DISPLAYCONFIG_SET_HDR_STATE and DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE share this layout.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_SET_STATE { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public uint value; }

    /// <summary>DISPLAYCONFIG_PATH_INFO flattened (72 bytes).</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_INFO
    {
        public LUID sourceAdapter;
        public uint sourceId;
        public uint sourceModeInfoIdx;
        public uint sourceStatusFlags;
        public LUID targetAdapter;
        public uint targetId;
        public uint targetModeInfoIdx;
        public int outputTechnology;
        public int rotation;
        public int scaling;
        public uint refreshNumerator;
        public uint refreshDenominator;
        public int scanLineOrdering;
        public int targetAvailable;
        public uint targetStatusFlags;
        public uint flags;
    }

    /// <summary>DISPLAYCONFIG_MODE_INFO (64 bytes); only its size matters here.</summary>
    [StructLayout(LayoutKind.Sequential, Size = 64)]
    private struct DISPLAYCONFIG_MODE_INFO { public int infoType; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public int rcMonitorLeft, rcMonitorTop, rcMonitorRight, rcMonitorBottom;
        public int rcWorkLeft, rcWorkTop, rcWorkRight, rcWorkBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SET_STATE setPacket);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
}
