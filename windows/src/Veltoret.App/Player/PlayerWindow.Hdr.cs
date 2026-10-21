using System.Windows;
using System.Windows.Interop;
using Veltoret.App.Services;
using Veltoret.Core.Player;
using Veltoret.Core.Storage;

namespace Veltoret.App.Player;

/// <summary>
/// HDR: on a display that can show HDR, an HDR video (HDR10, HLG, Dolby Vision's HDR10 base) turns on Windows HDR
/// before it starts, so libVLC's Direct3D 11 output sends it as HDR10 instead of tone-mapping it to SDR. The "HDR"
/// chip turns it on or off by hand for any video. When the player closes, the display goes back to how it was.
/// </summary>
public partial class PlayerWindow
{
    private HdrFormat _hdrFormat = HdrFormat.Unknown;
    /// <summary>The display's HDR state before the player changed it (null = untouched).</summary>
    private (HdrDisplay.Target Target, bool Enabled)? _hdrBefore;
    private bool _hdrBusy;

    private HdrDisplay.State? DisplayHdr()
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        return HdrDisplay.ForWindow(hwnd);
    }

    /// <summary>
    /// Before a video starts: if the display could switch to HDR for it, read its HDR format first and switch.
    /// Otherwise nothing waits: a local file's header is read alongside (for Video info), a stream's name is used.
    /// </summary>
    private async Task PrepareHdr(CancellationToken ct)
    {
        _hdrFormat = HdrProbe.FromFileName(VideoFileName());
        var display = DisplayHdr();
        UpdateHdrChip(display);
        if (display is not { Supported: true } d) return;
        if (_settings.AutoHdr && !d.Enabled)
        {
            _hdrFormat = await ProbeHdr(ct);
            ct.ThrowIfCancellationRequested();
            if (HdrProbe.IsHdr(_hdrFormat) && await SetDisplayHdr(d.Target, true))
            {
                Notice($"HDR turned on · {HdrProbe.Label(_hdrFormat)}");
                UpdateHdrChip(d with { Enabled = true });
            }
        }
        else if (_account != null && Accounts.IsLocal(_account))
        {
            var id = _fileId;
            _ = ProbeHdr(ct).ContinueWith(t =>
            {
                if (t.IsCompletedSuccessfully && _fileId == id) _hdrFormat = t.Result;
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }
    }

    private string? VideoFileName() =>
        _file?.Name ?? (_account != null && Accounts.IsLocal(_account) ? Path.GetFileName(_fileId) : _title);

    /// <summary>The container header (a few KB; local files, or the start of the stream) and the file name.</summary>
    private async Task<HdrFormat> ProbeHdr(CancellationToken ct)
    {
        var account = _account;
        var id = _fileId;
        var name = VideoFileName();
        if (account == null) return HdrProbe.FromFileName(name);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            // A slow server shouldn't hold up the start for long: the name is the fallback.
            timeout.CancelAfter(TimeSpan.FromSeconds(Accounts.IsLocal(account) ? 2 : 2.5));
            return await Task.Run(async () =>
            {
                await using var stream = Accounts.IsLocal(account)
                    ? new FileStream(id, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024)
                    : await AppServices.Storage.OpenRead(account, id, timeout.Token);
                return stream.CanSeek ? HdrProbe.Detect(stream, name) : HdrProbe.FromFileName(name);
            }, timeout.Token);
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            // Can't read it ahead (offline, slow server): the name is the only hint.
            return HdrProbe.FromFileName(name);
        }
    }

    /// <summary>Switches the display, remembering how it was; waits for the mode change to settle.</summary>
    private async Task<bool> SetDisplayHdr(HdrDisplay.Target target, bool on)
    {
        var before = DisplayHdr();
        if (!await Task.Run(() => HdrDisplay.Set(target, on))) return false;
        if (_hdrBefore == null && before is { } b) _hdrBefore = (b.Target, b.Enabled);
        // The display blanks for a moment while it changes mode.
        await Task.Delay(1200);
        return true;
    }

    /// <summary>The HDR chip: on or off by hand, then reload the picture so libVLC picks the new output format.</summary>
    private async void OnHdrClick(object sender, RoutedEventArgs e)
    {
        BumpInteraction();
        if (_hdrBusy || DisplayHdr() is not { Supported: true } d) return;
        _hdrBusy = true;
        try
        {
            var on = !d.Enabled;
            if (!await SetDisplayHdr(d.Target, on))
            {
                Notice("Windows didn't allow HDR on this display");
                return;
            }
            // A slow PC can take a few seconds to report the new mode: wait for Windows to confirm it, so the chip
            // shows what the display really does.
            var now = DisplayHdr();
            for (var i = 0; i < 6 && now is { } n && n.Enabled != on; i++)
            {
                await Task.Delay(500);
                now = DisplayHdr();
            }
            UpdateHdrChip(now);
            if (now is { } actual && actual.Enabled != on)
            {
                Notice(on ? "Windows kept HDR off" : "Windows kept HDR on");
                return;
            }
            // SDR videos look dimmer and flatter with HDR on (Windows shows them at its "SDR content brightness"):
            // HDR mode is for HDR videos.
            Notice(!on ? "HDR turned off"
                : HdrProbe.IsHdr(_hdrFormat) ? $"HDR turned on · {HdrProbe.Label(_hdrFormat)}"
                : "HDR turned on · this video isn't HDR, so it may look dimmer");
            if (_media != null) RebuildMedia(play: _playWhenReady);
        }
        finally { _hdrBusy = false; }
    }

    /// <summary>Controls shown: HDR may have been switched in Windows Settings meanwhile.</summary>
    private void RefreshHdrChip()
    {
        if (!_hdrBusy && HdrChip.Visibility == Visibility.Visible) UpdateHdrChip(DisplayHdr());
    }

    /// <summary>The chip is a toggle: amber with a green dot while HDR is on, plain while it's off; it reads "HDR".</summary>
    private void UpdateHdrChip(HdrDisplay.State? state)
    {
        HdrChip.Visibility = state is { Supported: true } ? Visibility.Visible : Visibility.Collapsed;
        var on = state is { Enabled: true };
        HdrChip.Style = (Style)Overlay.FindResource(on ? "P.ChipAccent" : "P.Chip");
        HdrOnDot.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        var name = on ? "HDR is on. Tap to turn it off" : "HDR is off. Tap to turn it on";
        HdrChip.ToolTip = name;
        AutomationNameSet(HdrChip, name);
    }

    /// <summary>Player closing: give the display back the HDR state it had.</summary>
    private void RestoreDisplayHdr()
    {
        if (_hdrBefore is not { } b) return;
        _hdrBefore = null;
        if (HdrDisplay.ForWindow(new WindowInteropHelper(this).Handle) is { } now && now.Enabled == b.Enabled) return;
        // The mode change takes a moment: don't hold up closing the window for it.
        Task.Run(() => HdrDisplay.Set(b.Target, b.Enabled));
    }
}
