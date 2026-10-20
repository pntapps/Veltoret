using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LibVLCSharp.Shared;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Player;
using Veltoret.Core.Settings;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace Veltoret.App.Player;

/// <summary>What to open: a library file id (or a source file id), its account, a title hint, and "start over".</summary>
public sealed record PlayerArgs(string FileId, string? Account, string? Title, bool FromStart);

/// <summary>
/// The full-window player (Android PlayerActivity + PlayerScreen + PlayerViewModel): one window that keeps playing
/// episode after episode, with full screen, the mini player (always-on-top, instead of picture-in-picture), and
/// LibVLC underneath. Partial files: Playback (media, tracks, progress), Subtitles, Panels, Input.
/// </summary>
public partial class PlayerWindow : Window
{
    /// <summary>The open player, if any (Cast hooks, the launcher reuses it).</summary>
    public static PlayerWindow? Current { get; private set; }

    /// <summary>Raised on the UI thread whenever a new video starts loading in this window.</summary>
    public event Action? VideoChanged;

    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromMilliseconds(4000) };
    private readonly DispatcherTimer _hudTimer = new() { Interval = TimeSpan.FromMilliseconds(1000) };
    private readonly DispatcherTimer _rippleTimer = new() { Interval = TimeSpan.FromMilliseconds(900) };
    private readonly DispatcherTimer _clickTimer = new() { Interval = TimeSpan.FromMilliseconds(260) };
    private readonly DispatcherTimer _holdTimer = new() { Interval = TimeSpan.FromMilliseconds(450) };
    private readonly DispatcherTimer _sleepTimer = new();

    private AppSettings _settings;
    private bool _controlsVisible = true;
    private bool _locked;
    private bool _scrubbing;
    private double _scrubFraction;
    private bool _closing;

    // Window modes
    private bool _fullscreen;
    private bool _mini;
    private (WindowState State, WindowStyle Style, ResizeMode Resize, Rect Bounds, bool Topmost)? _savedWindow;

    // Sleep timer (per window session; survives episode changes)
    private DateTimeOffset? _sleepEndsAt;
    private bool _sleepEndOfVideo;

    public PlayerWindow(PlayerArgs args)
    {
        InitializeComponent();
        _settings = AppServices.Settings.Current;
        AppServices.Settings.Changed += OnSettingsChanged;
        Current = this;

        _vlc = CreateLibVlc(_settings);
        _mp = new MediaPlayer(_vlc) { EnableHardwareDecoding = true, EnableKeyInput = false, EnableMouseInput = false };
        HookPlayer();
        Video.MediaPlayer = _mp;

        _resize = PlayerPrefs.Shared.ResizeMode;
        _clock.Tick += (_, _) => Tick();
        _hideTimer.Tick += (_, _) => AutoHide();
        _hudTimer.Tick += (_, _) => { _hudTimer.Stop(); Fade(Hud, 0, 220); };
        _rippleTimer.Tick += (_, _) => { _rippleTimer.Stop(); Fade(RippleLeft, 0, 220); Fade(RippleRight, 0, 220); _ripple = null; };
        _clickTimer.Tick += (_, _) => { _clickTimer.Stop(); ToggleControls(); };
        _holdTimer.Tick += (_, _) => { _holdTimer.Stop(); StartHold(); };
        _sleepTimer.Tick += (_, _) => OnSleepTimerFired();

        SourceInitialized += (_, _) => NativeMethods.UseDarkTitleBar(this);
        Loaded += (_, _) => OnLoaded();
        StateChanged += (_, _) => OnWindowStateChanged();
        SizeChanged += (_, _) => OnSizeChanged();
        Closing += OnClosingWindow;
        Closed += (_, _) => OnClosedWindow();
        PreviewKeyDown += OnAnyKeyDown;
        PreviewKeyUp += OnAnyKeyUp;

        SkipChipText.Text = $"+{_settings.SkipSeconds}s";
        UpdateAspectChip();
        _clock.Start();
        Open(args);
    }

    private void OnLoaded()
    {
        // LibVLCSharp hosts Overlay in its own window over the video; keys pressed there come here too.
        HookOverlayWindow();
        Overlay.Loaded += (_, _) => HookOverlayWindow();
        Overlay.MouseMove += OnOverlayMouseMove;
        Overlay.PreviewMouseLeftButtonDown += OnOverlayMouseDown;
        Overlay.PreviewMouseLeftButtonUp += OnOverlayMouseUp;
        Overlay.MouseRightButtonUp += (_, _) => BumpInteraction();
        Overlay.PreviewMouseWheel += OnOverlayWheel;
        Overlay.MouseLeave += (_, _) => { if (_mini && !TouchInput.RecentTouch) Fade(MiniControls, 0, 220); };
        HookTouch();
        OnSizeChanged();
        ShowControls();
    }

    private Window? _overlayWindow;

    private void HookOverlayWindow()
    {
        if (GetWindow(Overlay) is not { } w || w == this || w == _overlayWindow) return;
        if (_overlayWindow != null)
        {
            _overlayWindow.PreviewKeyDown -= OnAnyKeyDown;
            _overlayWindow.PreviewKeyUp -= OnAnyKeyUp;
        }
        _overlayWindow = w;
        w.PreviewKeyDown += OnAnyKeyDown;
        w.PreviewKeyUp += OnAnyKeyUp;
    }

    private void OnSettingsChanged(AppSettings s) => Dispatcher.BeginInvoke(() =>
    {
        _settings = s;
        SkipChipText.Text = $"+{s.SkipSeconds}s";
        UpdateTransportLabels();
    });

    // ---------------------------------------------------------------------------------------------
    // Cast hooks (network module)
    // ---------------------------------------------------------------------------------------------

    private bool _castActive;

    /// <summary>Current position in seconds.</summary>
    public double PositionSeconds => Math.Max(0, _mp.Time) / 1000.0;

    /// <summary>The library file playing (null for files outside the library).</summary>
    public MediaFileEntity? CurrentFile => _file;

    /// <summary>The id of what's playing (library id / local path / smb:// id / Drive id) and its account.</summary>
    public string FileId => _fileId;

    public string? Account => _account;

    public string VideoTitle => _title;

    public string? VideoSubtitle => _subtitle;

    /// <summary>The video moves to a TV: save progress here, pause, and stop saving until it comes back.</summary>
    public void PauseForCast()
    {
        SaveProgress();
        Pause();
        _castActive = true;
        _resumedFrom = null;
        UpdateUi();
    }

    /// <summary>Casting stopped: continue here, paused at the TV's position.</summary>
    public void ResumeAfterCast(long positionMs)
    {
        _castActive = false;
        if (positionMs > 0) SeekTo(positionMs);
        Pause();
    }

    // ---------------------------------------------------------------------------------------------
    // Window lifecycle
    // ---------------------------------------------------------------------------------------------

    /// <summary>Shows the window again (restored if minimised) when a new video is sent to it.</summary>
    public void BringToFront()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    private void OnWindowStateChanged()
    {
        // Minimising keeps playing (desktop convention; audio-only listening), but progress is saved.
        if (WindowState == WindowState.Minimized) SaveProgress();
    }

    private void OnClosingWindow(object? sender, CancelEventArgs e)
    {
        if (_closing) return;
        _closing = true;
        SaveProgress();
        RestoreDisplayHdr();
    }

    private void OnClosedWindow()
    {
        _clock.Stop();
        _hideTimer.Stop();
        _sleepTimer.Stop();
        AppServices.Settings.Changed -= OnSettingsChanged;
        _loadCts?.Cancel();
        NativeMethods.KeepAwake(false);
        if (Current == this) Current = null;
        ReleasePlayer();
        CleanupTempSubtitles();
    }

    // ---------------------------------------------------------------------------------------------
    // Controls visibility
    // ---------------------------------------------------------------------------------------------

    private bool PanelOpen => PanelLayer.Visibility == Visibility.Visible;

    private void BumpInteraction()
    {
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void ShowControls()
    {
        if (_mini) return;
        Overlay.Cursor = null;
        if (!_controlsVisible)
        {
            _controlsVisible = true;
            ApplyChromeVisibility();
        }
        BumpInteraction();
        UpdateUi();
    }

    private void HideControls()
    {
        if (!_controlsVisible) return;
        _controlsVisible = false;
        ApplyChromeVisibility();
        UpdateUi();
    }

    private void ToggleControls()
    {
        if (_controlsVisible) HideControls();
        else ShowControls();
    }

    private void AutoHide()
    {
        _hideTimer.Stop();
        if (_mini)
        {
            Fade(MiniControls, 0, 220);
            return;
        }
        var playing = _playWhenReady && !_ended;
        if (_controlsVisible && playing && !PanelOpen && !_scrubbing) HideControls();
        if (!_controlsVisible && playing && !PanelOpen) Overlay.Cursor = Cursors.None;
    }

    private void ApplyChromeVisibility()
    {
        if (_mini)
        {
            Chrome.Visibility = Visibility.Collapsed;
            UnlockButton.Visibility = Visibility.Collapsed;
            return;
        }
        var showChrome = _controlsVisible && !_locked;
        if (showChrome)
        {
            Chrome.Visibility = Visibility.Visible;
            Fade(Chrome, 1, 180);
        }
        else
        {
            Fade(Chrome, 0, 220, () => { if (!(_controlsVisible && !_locked)) Chrome.Visibility = Visibility.Collapsed; });
        }
        UnlockButton.Visibility = _locked && _controlsVisible ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void Fade(UIElement element, double to, int ms, Action? done = null)
    {
        var anim = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms));
        if (done != null) anim.Completed += (_, _) => done();
        element.BeginAnimation(OpacityProperty, anim);
    }

    // ---------------------------------------------------------------------------------------------
    // HUD and notices
    // ---------------------------------------------------------------------------------------------

    private void ShowHud(string text, string iconKey)
    {
        HudText.Text = text;
        HudIcon.Data = (Geometry)Overlay.FindResource(iconKey);
        Hud.BeginAnimation(OpacityProperty, null);
        Hud.Opacity = 1;
        _hudTimer.Stop();
        _hudTimer.Start();
    }

    /// <summary>One-off notice ("Switched to software decoding", "Sleep timer: paused").</summary>
    private void Notice(string text) => ShowHud(text, "P.Icon.Info");

    // ---------------------------------------------------------------------------------------------
    // Periodic refresh (100 ms)
    // ---------------------------------------------------------------------------------------------

    private int _saveTicks;

    private void Tick()
    {
        if (_closing) return;
        DropSilentTouches();
        PollPlayer();
        if (_playWhenReady && !_ended && IsActuallyPlaying && !_castActive && ++_saveTicks >= 100)
        {
            _saveTicks = 0;
            SaveProgress();
        }
        UpdateUi();
    }

    private long Duration => _stopping > 0 ? _cachedLength : _cachedLength = Math.Max(0, _mp.Length);

    private long Position => _stopping > 0 ? _cachedTime : _cachedTime = Math.Max(0, _mp.Time);

    private void CacheTimes()
    {
        _cachedLength = Math.Max(0, _mp.Length);
        _cachedTime = Math.Max(0, _mp.Time);
    }

    /// <summary>Refreshes everything that depends on time and state.</summary>
    private void UpdateUi()
    {
        if (_closing) return;
        var duration = Duration;
        var position = Position;
        var shown = _scrubbing && duration > 0 ? (long)(_scrubFraction * duration) : position;

        // Timeline
        PositionText.Text = PlayerFormat.Clock(shown);
        RemainingText.Text = duration > 0 ? "−" + PlayerFormat.Clock(duration - shown) : "--:--";
        if (duration > 0)
        {
            var endsAt = DateTime.Now.AddMilliseconds((duration - shown) / Math.Max(0.01, _speed));
            EndsAtText.Text = "Ends at " + endsAt.ToString("t", CultureInfo.CurrentCulture);
            EndsAtText.Visibility = Visibility.Visible;
        }
        else EndsAtText.Visibility = Visibility.Hidden;
        var fraction = duration > 0 ? Math.Clamp((double)shown / duration, 0, 1) : 0;
        var trackWidth = Math.Max(0, SeekArea.ActualWidth);
        SeekPlayed.Width = trackWidth * fraction;
        var thumb = _scrubbing ? 22 : 16;
        SeekThumb.Width = SeekThumb.Height = thumb;
        SeekTrack.Height = SeekPlayed.Height = _scrubbing ? 6 : 4;
        SeekThumb.Margin = new Thickness(Math.Clamp(trackWidth * fraction - thumb / 2.0, 0, Math.Max(0, trackWidth - thumb)), 0, 0, 0);
        MiniProgress.Width = Overlay.ActualWidth * fraction;

        // Play / pause (follows playWhenReady; spinner while buffering)
        var loading = IsLoading;
        var icon = _ended ? "P.Icon.Replay" : _playWhenReady ? "P.Icon.Pause" : "P.Icon.Play";
        PlayIcon.Data = (Geometry)Overlay.FindResource(icon);
        MiniPlayIcon.Data = PlayIcon.Data;
        PlayIcon.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        PlaySpinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        var playName = loading ? (_playWhenReady ? "Loading, tap to pause" : "Loading") : _playWhenReady ? "Pause" : "Play";
        PlayButton.ToolTip = playName;
        AutomationNameSet(PlayButton, playName);
        MiniPlayButton.ToolTip = _playWhenReady ? "Pause" : "Play";
        var chromeShown = _controlsVisible && !_locked && !_mini;
        CenterSpinner.Visibility = loading && !chromeShown ? Visibility.Visible : Visibility.Collapsed;
        var hint = loading ? PlayerFormat.LoadingHint(LoadingStage, _loadingFrom) : null;
        LoadingHint.Visibility = hint != null && !_mini ? Visibility.Visible : Visibility.Collapsed;
        LoadingHintText.Text = hint ?? "";

        // Prompts
        var bottom = chromeShown ? 132 : 28;
        var resumeVisible = _resumedFrom != null && !_mini && !_castActive && (DateTime.UtcNow - _resumeShownAt).TotalMilliseconds < 7000;
        if (_resumedFrom != null && !resumeVisible && (DateTime.UtcNow - _resumeShownAt).TotalMilliseconds >= 7000) _resumedFrom = null;
        ResumeCard.Visibility = resumeVisible ? Visibility.Visible : Visibility.Collapsed;
        ResumeCard.Margin = new Thickness(24, 0, 0, bottom);
        ResumeText.Text = _resumedFrom is { } r ? "Resumed at " + PlayerFormat.Clock(r) : "";

        var skipIntro = !_mini && PlayerMath.SkipIntroVisible(_isEpisode, _introSkipped, _controlsVisible, _locked, position) && _error == null;
        var upNext = !_mini && _error == null && PlayerMath.UpNextVisible(_next != null, duration, position, _autoPlayCancelled, _locked, _sleepEndOfVideo);
        SkipIntroButton.Visibility = skipIntro && !upNext ? Visibility.Visible : Visibility.Collapsed;
        UpNextCard.Visibility = upNext ? Visibility.Visible : Visibility.Collapsed;
        UpNextCard.Margin = new Thickness(0, 0, 24, chromeShown ? 132 : 24);
        if (upNext)
        {
            UpNextLabel.Text = _nextLabel ?? "";
            if (_settings.AutoPlayNext)
            {
                UpNextPlayText.Text = $"Play in {(duration - position) / 1000}s";
                UpNextCancel.Visibility = Visibility.Visible;
            }
            else
            {
                UpNextPlayText.Text = "Play now";
                UpNextCancel.Visibility = Visibility.Collapsed;
            }
        }

        // Error
        ErrorCard.Visibility = _error != null && !_mini ? Visibility.Visible : Visibility.Collapsed;
        if (_error != null)
        {
            ErrorText.Text = _error;
            TrySoftwareButton.Visibility = _software ? Visibility.Collapsed : Visibility.Visible;
        }

        if (PanelOpen && _panel == PanelKind.Info && _stopping == 0 && ++_infoTicks % 10 == 0) RefreshPanel();
    }

    private int _infoTicks;

    private static void AutomationNameSet(DependencyObject element, string name) =>
        System.Windows.Automation.AutomationProperties.SetName(element, name);

    /// <summary>Static parts of the chrome (title, episode buttons, labels) after a new video or a settings change.</summary>
    private void UpdateTransportLabels()
    {
        TitleText.Text = _title;
        SubtitleText.Text = _subtitle ?? "";
        SubtitleText.Visibility = string.IsNullOrWhiteSpace(_subtitle) ? Visibility.Collapsed : Visibility.Visible;
        Title = string.IsNullOrEmpty(_title) ? "Veltoret" : _title + " – Veltoret";
        var narrow = ActualWidth > 0 && ActualWidth < 600;

        EpisodesButton.Visibility = _isEpisode ? Visibility.Visible : Visibility.Collapsed;
        PipButton.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        PrevButton.Visibility = _previous != null ? Visibility.Visible : Visibility.Collapsed;
        PrevSpacer.Visibility = _previous == null && _next != null ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Visibility = _next != null ? Visibility.Visible : Visibility.Collapsed;
        NextSpacer.Visibility = _next == null && _previous != null ? Visibility.Visible : Visibility.Collapsed;
        NextChip.Visibility = _next != null ? Visibility.Visible : Visibility.Collapsed;
        SkipChip.Visibility = _isEpisode ? Visibility.Visible : Visibility.Collapsed;

        var seek = _settings.SeekSeconds;
        SeekBackButton.ToolTip = $"Back {seek}s";
        SeekForwardButton.ToolTip = $"Forward {seek}s";
        AutomationNameSet(SeekBackButton, $"Back {seek}s");
        AutomationNameSet(SeekForwardButton, $"Forward {seek}s");

        // Narrow windows use the smaller transport sizes and spacing.
        var spacing = narrow ? 18 : 32;
        SizeRound(PrevButton, narrow ? 44 : 50);
        SizeRound(NextButton, narrow ? 44 : 50);
        PrevSpacer.Width = PrevSpacer.Height = NextSpacer.Width = NextSpacer.Height = narrow ? 44 : 50;
        SizeRound(SeekBackButton, narrow ? 50 : 58);
        SizeRound(SeekForwardButton, narrow ? 50 : 58);
        SizeRound(PlayButton, narrow ? 68 : 78);
        foreach (var el in new FrameworkElement[] { SeekBackButton, PlayButton, SeekForwardButton, NextButton, NextSpacer })
            el.Margin = new Thickness(spacing, 0, 0, 0);
        SpeedChipText.Text = PlayerFormat.SpeedChip(_speed);
        UpdateAspectChip();
        FullscreenChipText.Text = _fullscreen ? "Exit full screen" : "Full screen";
        FullscreenChipIcon.Data = (Geometry)Overlay.FindResource(_fullscreen ? "P.Icon.FullscreenExit" : "P.Icon.Fullscreen");
    }

    private static void SizeRound(Button b, double size)
    {
        b.Width = b.Height = size;
        b.Padding = new Thickness(size * 0.26);
    }

    private void OnSizeChanged()
    {
        if (!IsLoaded) return;
        RippleLeft.Width = RippleRight.Width = Overlay.ActualWidth * 0.3;
        RippleLeft.Height = RippleRight.Height = Overlay.ActualHeight * 0.8;
        PanelBox.Width = Math.Min(400, Math.Max(280, Overlay.ActualWidth * 0.9));
        UpdateTransportLabels();
        if (_mini) KeepMiniAspect();
        ApplyAspect();
    }

    // ---------------------------------------------------------------------------------------------
    // Full screen and the mini player
    // ---------------------------------------------------------------------------------------------

    private void ToggleFullscreen()
    {
        if (_mini) return;
        if (_fullscreen) ExitFullscreen();
        else
        {
            _savedWindow = (WindowState, WindowStyle, ResizeMode, new Rect(Left, Top, Width, Height), Topmost);
            _fullscreen = true;
            WindowState = WindowState.Normal;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            WindowState = WindowState.Maximized;
        }
        UpdateTransportLabels();
        ShowControls();
    }

    private void ExitFullscreen()
    {
        if (!_fullscreen) return;
        _fullscreen = false;
        RestoreWindow();
        UpdateTransportLabels();
    }

    private void RestoreWindow()
    {
        if (_savedWindow is not { } s) return;
        WindowState = WindowState.Normal;
        WindowStyle = s.Style;
        ResizeMode = s.Resize;
        Topmost = s.Topmost;
        Left = s.Bounds.Left;
        Top = s.Bounds.Top;
        Width = s.Bounds.Width;
        Height = s.Bounds.Height;
        WindowState = s.State;
        _savedWindow = null;
    }

    /// <summary>Picture-in-picture on Windows: a small always-on-top window that keeps playing.</summary>
    private void EnterMini()
    {
        if (_mini) return;
        ClosePanel();
        if (_fullscreen)
        {
            _fullscreen = false;
            RestoreWindow();
        }
        _savedWindow = (WindowState, WindowStyle, ResizeMode, new Rect(Left, Top, Width, Height), Topmost);
        _mini = true;
        _controlsVisible = false;
        WindowState = WindowState.Normal;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResize;
        Topmost = true;
        var aspect = MiniAspect();
        var work = SystemParameters.WorkArea;
        Width = 400;
        Height = Math.Round(400 / aspect);
        Left = work.Right - Width - 16;
        Top = work.Bottom - Height - 16;
        ApplyChromeVisibility();
        MiniControls.Visibility = Visibility.Visible;
        MiniControls.Opacity = 0;
        Overlay.Cursor = null;
        UpdateUi();
    }

    private void ExitMini()
    {
        if (!_mini) return;
        _mini = false;
        MiniControls.Visibility = Visibility.Collapsed;
        RestoreWindow();
        Activate();
        ShowControls();
        ApplyChromeVisibility();
    }

    /// <summary>The video's shape, clamped to 1:2.39–2.39:1 (Android PiP limits).</summary>
    private double MiniAspect()
    {
        var (w, h) = VideoSize();
        var aspect = w > 0 && h > 0 ? (double)w / h : 16.0 / 9;
        return Math.Clamp(aspect, 1 / 2.39, 2.39);
    }

    private bool _sizingMini;

    private void KeepMiniAspect()
    {
        if (_sizingMini) return;
        _sizingMini = true;
        var target = Math.Round(Width / MiniAspect());
        if (Math.Abs(Height - target) > 1) Height = target;
        _sizingMini = false;
    }

    // ---------------------------------------------------------------------------------------------
    // Button handlers
    // ---------------------------------------------------------------------------------------------

    private void OnBackClick(object sender, RoutedEventArgs e) => Close();
    private void OnPlayClick(object sender, RoutedEventArgs e) { TogglePlay(); BumpInteraction(); }
    private void OnSeekBackClick(object sender, RoutedEventArgs e) { SeekBy(-_settings.SeekSeconds * 1000L); BumpInteraction(); }
    private void OnSeekForwardClick(object sender, RoutedEventArgs e) { SeekBy(_settings.SeekSeconds * 1000L); BumpInteraction(); }
    private void OnPreviousClick(object sender, RoutedEventArgs e) => PlayPrevious();
    private void OnNextClick(object sender, RoutedEventArgs e) => PlayNext();
    private void OnEpisodesClick(object sender, RoutedEventArgs e) => OpenPanel(PanelKind.Episodes);
    private void OnPipClick(object sender, RoutedEventArgs e) => EnterMini();
    private void OnFullscreenClick(object sender, RoutedEventArgs e) => ToggleFullscreen();
    private void OnMoreClick(object sender, RoutedEventArgs e) => OpenPanel(PanelKind.More);
    private void OnAudioClick(object sender, RoutedEventArgs e) => OpenPanel(PanelKind.Audio);
    private void OnSubtitlesClick(object sender, RoutedEventArgs e) => OpenPanel(PanelKind.Subtitles);
    private void OnSpeedClick(object sender, RoutedEventArgs e) => OpenPanel(PanelKind.Speed);
    private void OnAspectClick(object sender, RoutedEventArgs e) { CycleAspect(); BumpInteraction(); }
    private void OnSkipChipClick(object sender, RoutedEventArgs e) { SkipIntro(); BumpInteraction(); }
    private void OnSkipIntroClick(object sender, RoutedEventArgs e) => SkipIntro();
    private void OnStartOverClick(object sender, RoutedEventArgs e) => StartOver();
    private void OnUpNextCancelClick(object sender, RoutedEventArgs e) { _autoPlayCancelled = true; UpdateUi(); }
    private void OnRetryClick(object sender, RoutedEventArgs e) => Retry();
    private void OnTrySoftwareClick(object sender, RoutedEventArgs e) => SetSoftwareDecoding(true);
    private void OnMiniExpandClick(object sender, RoutedEventArgs e) => ExitMini();
    private void OnMiniBackClick(object sender, RoutedEventArgs e) => SeekBy(-10_000);
    private void OnMiniForwardClick(object sender, RoutedEventArgs e) => SeekBy(10_000);

    private void OnLockClick(object sender, RoutedEventArgs e)
    {
        _locked = true;
        _controlsVisible = true;
        ApplyChromeVisibility();
        BumpInteraction();
        UpdateUi();
    }

    private void OnUnlockClick(object sender, RoutedEventArgs e) => Unlock();

    private void Unlock()
    {
        _locked = false;
        _controlsVisible = true;
        ApplyChromeVisibility();
        BumpInteraction();
        UpdateUi();
    }

    private void StartOver()
    {
        SeekTo(0);
        _resumedFrom = null;
        UpdateUi();
    }

    private void SkipIntro()
    {
        SeekTo(PlayerMath.SkipForward(Position, Duration, _settings.SkipSeconds));
        _introSkipped = true;
        UpdateUi();
    }

    // ---------------------------------------------------------------------------------------------
    // Sleep timer
    // ---------------------------------------------------------------------------------------------

    private void SetSleepTimer(int? minutes)
    {
        _sleepTimer.Stop();
        _sleepEndOfVideo = false;
        _sleepEndsAt = null;
        if (minutes is not { } m) return;
        _sleepEndsAt = DateTimeOffset.Now.AddMinutes(m);
        _sleepTimer.Interval = TimeSpan.FromMinutes(m);
        _sleepTimer.Start();
    }

    private void SetSleepAtEndOfVideo()
    {
        _sleepTimer.Stop();
        _sleepEndsAt = null;
        _sleepEndOfVideo = true;
    }

    private void OnSleepTimerFired()
    {
        _sleepTimer.Stop();
        _sleepEndsAt = null;
        Pause();
        Notice("Sleep timer: paused");
    }
}
