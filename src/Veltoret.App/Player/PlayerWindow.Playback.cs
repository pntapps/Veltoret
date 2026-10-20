using System.Globalization;
using System.Windows;
using LibVLCSharp.Shared;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Player;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;

namespace Veltoret.App.Player;

public partial class PlayerWindow
{
    private readonly LibVLC _vlc;
    private readonly MediaPlayer _mp;
    private Media? _media;
    private SourceMediaInput? _input;
    private CancellationTokenSource? _loadCts;

    // ---- The current video -------------------------------------------------------------------
    private string _fileId = "";
    private string? _account;
    private MediaFileEntity? _file;
    private string? _titleHint;
    private string _title = "";
    private string? _subtitle;
    private MediaFileEntity? _next;
    private MediaFileEntity? _previous;
    private string? _nextLabel;
    private string? _loadingFrom;
    private bool _isEpisode => _file?.ShowId != null;
    private int? ShowId => _file?.ShowId;

    /// <summary>Choices saved for this video, applied once its tracks are known.</summary>
    private TrackMemory? _restore;
    private bool _tracksApplied;
    private DateTime _playingSince;
    /// <summary>The subtitle language wanted when no per-video memory exists (a sidecar may provide it).</summary>
    private string? _autoSubtitlePending;
    private long? _resumedFrom;
    private DateTime _resumeShownAt;
    private string? _error;
    private bool _ended;
    private bool _autoPlayCancelled;
    private bool _introSkipped;
    private bool _triedSoftwareFallback;
    private bool _software;

    // ---- Playback state ------------------------------------------------------------------------
    /// <summary>"Will play when it can": what the play/pause button shows (never derived from IsPlaying).</summary>
    private bool _playWhenReady;
    private bool _buffering;
    private DateTime _loadingStarted = DateTime.UtcNow;
    private float _speed = 1f;
    private int _volume = 100;
    private string _resize = "Fit";
    private double _zoom = 1;
    private double _panX;
    private double _panY;
    private long _lastPolledTime = -1;
    private long _streamLength;

    private readonly List<string> _vlcErrors = new();
    private readonly object _logLock = new();

    private bool IsActuallyPlaying => _mp.IsPlaying;

    private bool IsLoading => _error == null && !_ended && _media != null && _buffering;

    /// <summary>0 = just started (or not loading), 1 after 5 s, 2 after 15 s; only while it should play.</summary>
    private int LoadingStage
    {
        get
        {
            if (!IsLoading || !_playWhenReady) return 0;
            var ms = (DateTime.UtcNow - _loadingStarted).TotalMilliseconds;
            return ms >= 15_000 ? 2 : ms >= 5_000 ? 1 : 0;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // LibVLC setup
    // ---------------------------------------------------------------------------------------------

    private static LibVLC CreateLibVlc(AppSettings settings)
    {
        // Subtitle look: white text, black outline, optional 70 % black box, size x subtitleScale.
        var relSize = (int)Math.Clamp(Math.Round(16 / Math.Max(0.3, settings.SubtitleScale)), 4, 60);
        var options = new List<string>
        {
            "--no-sub-autodetect-file", // sidecars are loaded by Veltoret, once
            "--no-video-title-show",
            "--no-snapshot-preview",
            "--no-mouse-events",
            "--no-keyboard-events",
            "--freetype-color=16777215",
            "--freetype-outline-thickness=4",
            "--freetype-outline-color=0",
            $"--freetype-rel-fontsize={relSize}",
            "--sub-margin=20",
        };
        if (settings.SubtitleBackground)
        {
            options.Add("--freetype-background-opacity=179");
            options.Add("--freetype-background-color=0");
        }
        else options.Add("--freetype-background-opacity=0");
        return new LibVLC(enableDebugLogs: false, options.ToArray());
    }

    private void HookPlayer()
    {
        _vlc.Log += (_, e) =>
        {
            if (e.Level != LogLevel.Error) return;
            lock (_logLock)
            {
                _vlcErrors.Add($"{e.Module}: {e.Message}");
                if (_vlcErrors.Count > 12) _vlcErrors.RemoveAt(0);
            }
        };
        _mp.Opening += (_, _) => Ui(() => { StartLoading(); });
        _mp.Buffering += (_, e) =>
        {
            var cache = e.Cache;
            Ui(() =>
            {
                if (cache < 100f) StartLoading();
                else _buffering = false;
            });
        };
        _mp.Playing += (_, _) => Ui(OnVlcPlaying);
        _mp.Paused += (_, _) => Ui(() =>
        {
            _buffering = false;
            SaveProgress();
            NativeMethods.KeepAwake(false);
        });
        _mp.EndReached += (_, _) => Ui(OnEnded);
        _mp.EncounteredError += (_, _) => Ui(OnVlcError);
        _mp.Vout += (_, _) => Ui(ApplyAspect);
    }

    private void Ui(Action action) => Dispatcher.BeginInvoke(() =>
    {
        if (!_closing) action();
    });

    private void StartLoading()
    {
        if (!_buffering) _loadingStarted = DateTime.UtcNow;
        _buffering = true;
    }

    private void OnVlcPlaying()
    {
        _ended = false;
        if (_playingSince == default) _playingSince = DateTime.UtcNow;
        if (!_playWhenReady)
        {
            // Pause pressed while loading: don't start when ready.
            _mp.SetPause(true);
        }
        else NativeMethods.KeepAwake(true);
        _mp.Volume = _volume;
        if (Math.Abs(_mp.Rate - _speed) > 0.001f) _mp.SetRate(_speed);
        ApplyAspect();
    }

    /// <summary>Called every 100 ms: buffering fallback, tracks once known, slave subtitle ids.</summary>
    private void PollPlayer()
    {
        if (_media == null) return;
        var time = _mp.Time;
        // Some inputs don't report buffering at 100 %; time moving means it plays.
        if (_buffering && _mp.State == VLCState.Playing && time > 0 && _lastPolledTime >= 0 && time != _lastPolledTime) _buffering = false;
        _lastPolledTime = time;
        if (!_tracksApplied && _playingSince != default && (DateTime.UtcNow - _playingSince).TotalMilliseconds > 400 &&
            _mp.State is VLCState.Playing or VLCState.Paused)
        {
            ApplyTracksOnce();
        }
        PollSlaves();
    }

    // ---------------------------------------------------------------------------------------------
    // Opening a video
    // ---------------------------------------------------------------------------------------------

    /// <summary>Opens a video in this window (next/previous/episode list/new request): saves the current one first.</summary>
    public void Open(PlayerArgs args)
    {
        if (!string.IsNullOrEmpty(_title)) SaveProgress();
        _titleHint = args.Title;
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        // Run inside a dispatcher operation so every await resumes on the UI thread, whoever called Open.
        _ = Dispatcher.InvokeAsync(() => LoadAsync(args.FileId, args.Account, args.FromStart, cts.Token));
    }

    private async Task LoadAsync(string requestedId, string? accountHint, bool fromStart, CancellationToken ct)
    {
        try
        {
            var online = AppServices.Connectivity.IsOnline;
            var found = await AppServices.MediaFileDao.File(requestedId);
            // Offline, a Drive or network file can't stream, but the same title may be stored on this PC.
            if (found != null && !online && !Accounts.IsLocal(found.AccountEmail))
            {
                var copy = found.MovieId is { } m ? await AppServices.MediaFileDao.DeviceCopyOfMovie(m)
                    : found is { ShowId: { } s, Season: { } se, Episode: { } ep } ? await AppServices.MediaFileDao.DeviceCopyOfEpisode(s, se, ep)
                    : null;
                if (copy != null) found = copy;
            }
            ct.ThrowIfCancellationRequested();

            _file = found;
            _fileId = found?.DriveId ?? requestedId;
            _account = found?.AccountEmail ?? accountHint;
            ResetVideoState();
            _restore = PlayerPrefs.Shared.TrackMemory(_fileId);
            _subtitleOffsetMs = _restore?.SubtitleOffsetMs ?? 0;
            await StopCurrentMedia();
            ct.ThrowIfCancellationRequested();

            if (_account == null)
            {
                _title = _titleHint ?? found?.Name ?? "Video";
                UpdateTransportLabels();
                ShowError(PlayerErrors.NoAccount);
                return;
            }

            // Title and subtitle for the top bar
            var title = _titleHint ?? found?.Name ?? "Video";
            string? subtitle = null;
            if (found?.MovieId is { } movieId)
            {
                if (await AppServices.CatalogDao.Movie(movieId) is { } movie)
                {
                    title = movie.Title;
                    subtitle = string.Join(" · ", new[] { movie.Year?.ToString(CultureInfo.InvariantCulture), PlayerFormat.Runtime(movie.RuntimeMin) }
                        .Where(x => !string.IsNullOrEmpty(x)));
                }
            }
            else if (found?.ShowId is { } showId)
            {
                if (await AppServices.CatalogDao.Show(showId) is { } show) title = show.Name;
                subtitle = await EpisodeLabel(found);
                var showFiles = await AppServices.MediaFileDao.ForShow(showId);
                _next = EpisodeNav.Next(found, showFiles, online);
                _previous = EpisodeNav.Previous(found, showFiles, online);
                _nextLabel = _next != null ? await EpisodeLabel(_next) : null;
            }
            _titleHint = null;
            _title = title;
            _subtitle = subtitle;

            // Resume
            long resumeAt = 0;
            if (!fromStart)
            {
                var key = found != null ? WatchKeys.ForFile(found) : WatchKeys.File(_fileId);
                var state = await AppServices.Watch.Get(key);
                resumeAt = PlayerMath.ResumeAt(false, state?.PositionMs, state?.Watched == true);
            }
            if (resumeAt > 0)
            {
                _resumedFrom = resumeAt;
                _resumeShownAt = DateTime.UtcNow;
            }
            _loadingFrom = Accounts.IsLocal(_account) ? null
                : Accounts.IsSmb(_account) ? SafeRootName(_account)
                : "Google Drive";
            ct.ThrowIfCancellationRequested();
            UpdateTransportLabels();
            VideoChanged?.Invoke();

            ApplyLanguagePreferences(out var audioLanguage, out var subtitleLanguage);
            // An HDR video on an HDR display: switch the display to HDR first (libVLC picks its output at start).
            await PrepareHdr(ct);
            ct.ThrowIfCancellationRequested();
            await StartMedia(resumeAt, audioLanguage, subtitleLanguage, ct);
            ShowControls();

            // Subtitle files next to the video with the same base name (Movie.srt, Movie.en.srt ...).
            await LoadSidecars(ct);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            App.Log(e);
            if (!ct.IsCancellationRequested) ShowError(Describe(e));
        }
    }

    private static string? SafeRootName(string account)
    {
        try { return AppServices.Storage.RootName(account); }
        catch (Exception) { return account.Replace("smb://", "", StringComparison.OrdinalIgnoreCase); }
    }

    private static async Task<string> EpisodeLabel(MediaFileEntity f)
    {
        var code = PlayerFormat.EpisodeCode(f.Season, f.Episode);
        string? name = null;
        if (f is { ShowId: { } s, Season: { } se, Episode: { } e })
            name = (await AppServices.CatalogDao.Episode(s, se, e))?.Name;
        return string.Join("  ·  ", new[] { code, name }.Where(x => !string.IsNullOrWhiteSpace(x)));
    }

    private void ResetVideoState()
    {
        _error = null;
        _ended = false;
        _next = null;
        _previous = null;
        _nextLabel = null;
        _resumedFrom = null;
        _autoPlayCancelled = false;
        _introSkipped = false;
        _triedSoftwareFallback = false;
        _tracksApplied = false;
        _playingSince = default;
        _autoSubtitlePending = null;
        _speed = 1f;
        _zoom = 1;
        _panX = _panY = 0;
        _lastPolledTime = -1;
        _streamLength = 0;
        lock (_logLock) _vlcErrors.Clear();
        ResetExternals();
    }

    /// <summary>Starts each video with remembered languages (Android applyLanguagePreferences).</summary>
    private void ApplyLanguagePreferences(out string audio, out string subtitle)
    {
        var memory = _restore;
        audio = MediaFormats.NormalizeLanguage(memory?.AudioLanguage ?? PlayerPrefs.Shared.AudioLanguage(ShowId) ?? _settings.PreferredAudioLanguage) ?? "en";
        subtitle = memory?.SubtitleMode switch
        {
            TrackMemory.SubOff or TrackMemory.SubExternal => PlayerPrefsStore.Off,
            TrackMemory.SubEmbedded => memory.SubtitleLanguage ?? PlayerPrefsStore.Off,
            _ => PlayerPrefs.Shared.SubtitleLanguage(ShowId)
                 ?? (string.IsNullOrWhiteSpace(_settings.PreferredSubtitleLanguage) ? PlayerPrefsStore.Off : _settings.PreferredSubtitleLanguage),
        };
        if (subtitle != PlayerPrefsStore.Off) subtitle = MediaFormats.NormalizeLanguage(subtitle) ?? PlayerPrefsStore.Off;
        _autoSubtitlePending = subtitle != PlayerPrefsStore.Off && memory?.SubtitleMode == null ? subtitle : null;
        _wantedAudio = audio;
        _wantedSubtitle = subtitle;
    }

    private string? _wantedAudio;
    private string? _wantedSubtitle;

    private async Task StartMedia(long startMs, string? audioLanguage, string? subtitleLanguage, CancellationToken ct)
    {
        var options = new List<string> { _software ? ":avcodec-hw=none" : ":avcodec-hw=any" };
        if (startMs > 0) options.Add(":start-time=" + (startMs / 1000.0).ToString("0.###", CultureInfo.InvariantCulture));
        if (!string.IsNullOrEmpty(audioLanguage)) options.Add(":audio-language=" + audioLanguage);
        options.Add(":sub-language=" + (string.IsNullOrEmpty(subtitleLanguage) || subtitleLanguage == PlayerPrefsStore.Off ? "none" : subtitleLanguage));

        Media media;
        SourceMediaInput? input = null;
        var account = _account!;
        var id = _fileId;
        if (Accounts.IsLocal(account))
        {
            options.Add(":file-caching=1000");
            if (!File.Exists(id)) throw new FileNotFoundException("Missing", id);
            media = new Media(_vlc, id, FromType.FromPath, options.ToArray());
        }
        else
        {
            options.Add(":network-caching=3000");
            options.Add(":file-caching=3000");
            var stream = await AppServices.Storage.OpenRead(account, id, ct);
            try { _streamLength = stream.CanSeek ? stream.Length : 0; }
            catch (Exception) { _streamLength = 0; }
            input = new SourceMediaInput(stream);
            media = new Media(_vlc, input, options.ToArray());
        }
        if (ct.IsCancellationRequested)
        {
            media.Dispose();
            input?.Dispose();
            ct.ThrowIfCancellationRequested();
        }

        _media = media;
        _input = input;
        _playWhenReady = !_castActive;
        _buffering = true;
        _loadingStarted = DateTime.UtcNow;
        _playingSince = default;
        _tracksApplied = false;
        _ended = false;
        var mp = _mp;
        await Task.Run(() =>
        {
            mp.Play(media);
            mp.SetRate(1f);
        }, CancellationToken.None);
        if (_playWhenReady) NativeMethods.KeepAwake(true);
        UpdateTransportLabels();
    }

    /// <summary>Stops and frees the current media off the UI thread (a network read may take a moment to give up).</summary>
    private async Task StopCurrentMedia()
    {
        var media = _media;
        var input = _input;
        _media = null;
        _input = null;
        if (media == null) return;
        var mp = _mp;
        await Task.Run(() =>
        {
            try { mp.Stop(); }
            catch (Exception) { }
            media.Dispose();
            input?.Dispose();
        });
    }

    private void ReleasePlayer()
    {
        var mp = _mp;
        var media = _media;
        var input = _input;
        var vlc = _vlc;
        _media = null;
        _input = null;
        try { Video.MediaPlayer = null; }
        catch (Exception) { }
        Task.Run(() =>
        {
            try
            {
                mp.Stop();
                media?.Dispose();
                input?.Dispose();
                mp.Dispose();
                vlc.Dispose();
            }
            catch (Exception e) { App.Log(e); }
        });
        try { Video.Dispose(); }
        catch (Exception) { }
    }

    // ---------------------------------------------------------------------------------------------
    // Transport
    // ---------------------------------------------------------------------------------------------

    private void Play()
    {
        if (_media == null) return;
        _playWhenReady = true;
        if (_mp.State is VLCState.Ended or VLCState.Stopped or VLCState.NothingSpecial) _mp.Play();
        else _mp.SetPause(false);
        NativeMethods.KeepAwake(true);
        UpdateUi();
    }

    private void Pause()
    {
        _playWhenReady = false;
        if (_media != null && _mp.CanPause) _mp.SetPause(true);
        SaveProgress();
        NativeMethods.KeepAwake(false);
        UpdateUi();
    }

    /// <summary>The play/pause button: replay after the end, else follow playWhenReady.</summary>
    private void TogglePlay()
    {
        if (_ended)
        {
            Open(new PlayerArgs(_fileId, _account, null, FromStart: true));
            return;
        }
        if (_playWhenReady) Pause();
        else Play();
    }

    private void SeekTo(long ms)
    {
        if (_media == null) return;
        if (_ended && _mp.State == VLCState.Ended)
        {
            Open(new PlayerArgs(_fileId, _account, null, FromStart: ms <= 0));
            return;
        }
        _mp.Time = Math.Max(0, ms);
        _lastPolledTime = -1;
        UpdateUi();
    }

    private void SeekBy(long deltaMs) => SeekTo(PlayerMath.SeekBy(Position, Duration, deltaMs));

    private void SetSpeed(float speed)
    {
        _speed = speed;
        _mp.SetRate(speed);
        UpdateTransportLabels();
    }

    private void ChangeVolume(int delta)
    {
        _volume = Math.Clamp(_volume + delta, 0, 200);
        _mp.Volume = _volume;
        if (_mp.Mute && delta > 0) _mp.Mute = false;
        ShowHud(PlayerFormat.Volume(_volume), "P.Icon.Volume");
    }

    private void ToggleMute()
    {
        _mp.Mute = !_mp.Mute;
        ShowHud(_mp.Mute ? "Muted" : PlayerFormat.Volume(_volume), "P.Icon.Volume");
    }

    // ---------------------------------------------------------------------------------------------
    // Aspect: Fit / Fill / Stretch, zoom and pan
    // ---------------------------------------------------------------------------------------------

    private (int Width, int Height) VideoSize()
    {
        try
        {
            var track = _media?.Tracks.FirstOrDefault(t => t.TrackType == TrackType.Video);
            if (track is { } t && t.Data.Video.Width > 0) return ((int)t.Data.Video.Width, (int)t.Data.Video.Height);
        }
        catch (Exception) { }
        return (0, 0);
    }

    private void CycleAspect()
    {
        _resize = _resize switch { "Fit" => "Fill", "Fill" => "Stretch", _ => "Fit" };
        PlayerPrefs.Shared.ResizeMode = _resize;
        _zoom = 1;
        _panX = _panY = 0;
        ApplyAspect();
        UpdateAspectChip();
    }

    private void UpdateAspectChip() => AspectChipText.Text = _zoom > 1.001 ? "Zoom" : _resize;

    private void ApplyAspect()
    {
        if (_media == null) return;
        var w = Math.Max(1, Math.Round(Video.ActualWidth));
        var h = Math.Max(1, Math.Round(Video.ActualHeight));
        var (vw, vh) = VideoSize();
        try
        {
            _mp.Scale = 0;
            _mp.AspectRatio = _resize == "Stretch" ? $"{w}:{h}" : null;
            _mp.CropGeometry = PlayerMath.CropGeometry(vw, vh, w, h, _resize == "Fill", _zoom, _panX, _panY);
        }
        catch (Exception e) { App.Log(e); }
    }

    private void SetZoom(double zoom)
    {
        _zoom = Math.Clamp(zoom, 1, 5);
        if (_zoom < 1.05)
        {
            _zoom = 1;
            _panX = _panY = 0;
        }
        ApplyAspect();
        UpdateAspectChip();
        ShowHud(PlayerFormat.Zoom(_zoom), "P.Icon.Zoom");
    }

    // ---------------------------------------------------------------------------------------------
    // Episodes
    // ---------------------------------------------------------------------------------------------

    private void PlayNext()
    {
        if (_next is not { } n) return;
        Open(new PlayerArgs(n.DriveId, n.AccountEmail, null, FromStart: false));
    }

    private void PlayPrevious()
    {
        if (_previous is not { } p) return;
        Open(new PlayerArgs(p.DriveId, p.AccountEmail, null, FromStart: false));
    }

    // ---------------------------------------------------------------------------------------------
    // Progress and the end
    // ---------------------------------------------------------------------------------------------

    /// <summary>Saves progress (fire-and-forget, so closing the window doesn't cancel it).</summary>
    internal Task SaveProgress()
    {
        if (_castActive || _media == null || string.IsNullOrEmpty(_fileId)) return Task.CompletedTask;
        var duration = _mp.Length > 0 ? _mp.Length : _file?.DurationMs ?? 0;
        if (duration <= 0) return Task.CompletedTask;
        var position = _mp.Time;
        if (position < 0) return Task.CompletedTask;
        return SaveAsync(_file, _fileId, position, duration);
    }

    private static Task SaveAsync(MediaFileEntity? file, string id, long position, long duration) =>
        Task.Run(async () =>
        {
            try { await AppServices.Watch.SavePosition(file, id, position, duration); }
            catch (Exception e) { App.Log(e); }
        });

    private void OnEnded()
    {
        _ended = true;
        _buffering = false;
        _playWhenReady = false;
        NativeMethods.KeepAwake(false);
        var duration = _mp.Length > 0 ? _mp.Length : _file?.DurationMs ?? 0;
        if (duration > 0 && !_castActive) SaveAsync(_file, _fileId, duration, duration);
        if (_sleepEndOfVideo)
        {
            _sleepEndOfVideo = false;
            Notice("Sleep timer: stopped");
            ShowControls();
            return;
        }
        if (_next != null && _settings.AutoPlayNext && !_autoPlayCancelled) PlayNext();
        else Close();
    }

    // ---------------------------------------------------------------------------------------------
    // Errors and decoding
    // ---------------------------------------------------------------------------------------------

    private List<string> RecentErrors()
    {
        lock (_logLock) return _vlcErrors.ToList();
    }

    private void OnVlcError()
    {
        var log = RecentErrors();
        if (_input?.LastError == null && PlayerErrors.LooksLikeDecoderError(log) && !_software && !_triedSoftwareFallback)
        {
            // The hardware decoder can't handle this file: retry in software, once.
            _triedSoftwareFallback = true;
            SetSoftwareDecoding(true, "Switched to software decoding");
            return;
        }
        ShowError(Describe(_input?.LastError));
    }

    private string Describe(Exception? e)
    {
        (string, int, int, int)? video = null;
        string? audio = null;
        try
        {
            if (_media?.Tracks is { } tracks)
            {
                var v = tracks.FirstOrDefault(t => t.TrackType == TrackType.Video);
                if (v.Codec != 0) video = (MediaFormats.FourCC(v.Codec), v.Profile, (int)v.Data.Video.Width, (int)v.Data.Video.Height);
                var a = tracks.FirstOrDefault(t => t.TrackType == TrackType.Audio && t.Id == _mp.AudioTrack);
                if (a.Codec != 0) audio = MediaFormats.FourCC(a.Codec);
            }
        }
        catch (Exception) { }
        return PlayerErrors.Describe(e, RecentErrors(), _account, _fileId, AppServices.Connectivity.IsOnline, video, audio);
    }

    private void ShowError(string message)
    {
        _error = message;
        _buffering = false;
        _playWhenReady = false;
        NativeMethods.KeepAwake(false);
        ShowControls();
        UpdateUi();
    }

    private void Retry()
    {
        _error = null;
        if (_media == null) Open(new PlayerArgs(_fileId, _account, null, FromStart: false));
        else RebuildMedia(play: true);
    }

    /// <summary>Software decoding on/off: reloads the media keeping position, play/pause, tracks and speed.</summary>
    private void SetSoftwareDecoding(bool enabled, string? notice = null)
    {
        var hadError = _error != null;
        _software = enabled;
        _error = null;
        RebuildMedia(play: _playWhenReady || notice != null || hadError);
        if (notice != null) Notice(notice);
        RefreshPanelIfOpen();
    }

    private async void RebuildMedia(bool play)
    {
        if (_account == null) return;
        var position = Position;
        var speed = _speed;
        // Keep the current track choices as this video's restore point.
        var audio = AudioTracks();
        var current = audio.FirstOrDefault(t => t.Id == _mp.AudioTrack);
        var subs = EmbeddedSubtitleTracks();
        var spu = subs.FirstOrDefault(t => t.Id == _mp.Spu);
        _restore = new TrackMemory
        {
            AudioIndex = current?.Ordinal, AudioLanguage = current?.Language,
            SubtitleMode = _selectedExternal != null ? TrackMemory.SubExternal : spu != null ? TrackMemory.SubEmbedded : TrackMemory.SubOff,
            SubtitleIndex = spu?.Ordinal, SubtitleLanguage = spu?.Language,
            ExternalSource = _selectedExternal, ExternalName = _externals.FirstOrDefault(x => x.Id == _selectedExternal)?.Label,
        };
        foreach (var x in _externals) x.SpuId = null;
        _pendingSlave = null;
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        try
        {
            await StopCurrentMedia();
            await StartMedia(position, _wantedAudio, PlayerPrefsStore.Off, cts.Token);
            _speed = speed;
            if (!play) _playWhenReady = false;
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            App.Log(e);
            ShowError(Describe(e));
        }
    }
}
