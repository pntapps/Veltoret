using System.Runtime.InteropServices;

namespace Veltoret.Core.Cast;

/// <summary>
/// Keeps the PC from sleeping while it serves a video to the TV (Android: Wi-Fi lock + partial wake lock).
/// SetThreadExecutionState is per thread, so a dedicated thread holds the request until <see cref="Release"/>.
/// </summary>
public sealed class KeepAwake
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);

    private readonly object _lock = new();
    private ManualResetEventSlim? _release;

    public bool Held { get { lock (_lock) return _release != null; } }

    public void Acquire()
    {
        lock (_lock)
        {
            if (_release != null || !OperatingSystem.IsWindows()) return;
            var release = new ManualResetEventSlim(false);
            _release = release;
            var thread = new Thread(() =>
            {
                try
                {
                    SetThreadExecutionState(EsContinuous | EsSystemRequired);
                    // Android caps its wake lock at 6 hours.
                    release.Wait(TimeSpan.FromHours(6));
                }
                finally
                {
                    SetThreadExecutionState(EsContinuous);
                    release.Dispose();
                }
            }) { IsBackground = true, Name = "Veltoret keep awake" };
            thread.Start();
        }
    }

    public void Release()
    {
        lock (_lock)
        {
            try { _release?.Set(); } catch (ObjectDisposedException) { }
            _release = null;
        }
    }
}
