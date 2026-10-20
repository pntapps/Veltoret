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

    /// <summary>Before a video starts: read its HDR format and, if it is HDR, turn on HDR on the display.</summary>
    private async Task PrepareHdr(CancellationToken ct)
    {
        _hdrFormat = HdrFormat.Unknown;
        var display = DisplayHdr();
        if (display is not { Supported: true } d)
        {
            UpdateHdrChip(null);
            return;
        }
        _hdrFormat = await ProbeHdr(ct);
        ct.ThrowIfCancellationRequested();
        if (_settings.AutoHdr && HdrProbe.IsHdr(_hdrFormat) && !d.Enabled && await SetDisplayHdr(d.Target, true))
        {
            Notice($"HDR on · {HdrProbe.Label(_hdrFormat)}");
        }
        UpdateHdrChip(DisplayHdr());
    }

    /// <summary>The container header (a few KB; local files, or the start of the stream) and the file name.</summary>
    private async Task<HdrFormat> ProbeHdr(CancellationToken ct)
    {
        var account = _account;
        var id = _fileId;
        var name = _file?.Name ?? (account != null && Accounts.IsLocal(account) ? Path.GetFileName(id) : _title);
        if (account == null) return HdrProbe.FromFileName(name);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
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
            if (!await SetDisplayHdr(d.Target, !d.Enabled))
            {
                Notice("Windows didn't allow HDR on this display");
                return;
            }
            Notice(d.Enabled ? "HDR off" : "HDR on");
            UpdateHdrChip(DisplayHdr());
            if (_media != null) RebuildMedia(play: _playWhenReady);
        }
        finally { _hdrBusy = false; }
    }

    private void UpdateHdrChip(HdrDisplay.State? state)
    {
        HdrChip.Visibility = state is { Supported: true } ? Visibility.Visible : Visibility.Collapsed;
        var on = state is { Enabled: true };
        HdrChipText.Text = on ? "HDR on" : "HDR off";
        HdrChipIcon.Fill = (System.Windows.Media.Brush)Overlay.FindResource(on ? "P.Amber" : "P.Text");
        var name = on ? "HDR is on. Turn off HDR" : "HDR is off. Turn on HDR";
        HdrChip.ToolTip = name;
        AutomationNameSet(HdrChip, name);
    }

    /// <summary>Player closing: give the display back the HDR state it had.</summary>
    private void RestoreDisplayHdr()
    {
        if (_hdrBefore is not { } b) return;
        _hdrBefore = null;
        if (HdrDisplay.ForWindow(new WindowInteropHelper(this).Handle) is { } now && now.Enabled == b.Enabled) return;
        HdrDisplay.Set(b.Target, b.Enabled);
    }
}
