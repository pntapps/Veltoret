using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using LibVLCSharp.Shared;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Library;
using Veltoret.Core.Player;
using Veltoret.Core.Storage;
using Veltoret.Core.Tmdb;
using Path = System.Windows.Shapes.Path;

namespace Veltoret.App.Player;

public partial class PlayerWindow
{
    private enum PanelKind { None, More, Sleep, Speed, Audio, Subtitles, FolderSubtitles, Episodes, Info }

    private PanelKind _panel;
    private List<StorageItem>? _folderSubtitles;
    private bool _folderLoading;
    private int _panelVersion;

    private Brush B(string key) => (Brush)Overlay.FindResource(key);

    private void OpenPanel(PanelKind kind)
    {
        if (_mini) return;
        _panel = kind;
        PanelLayer.Visibility = Visibility.Visible;
        PanelBackButton.Visibility = kind is PanelKind.FolderSubtitles or PanelKind.Sleep or PanelKind.Info ? Visibility.Visible : Visibility.Collapsed;
        PanelScroll.ScrollToTop();
        _panelVersion++;
        if (kind == PanelKind.FolderSubtitles) _ = LoadFolderSubtitles();
        RefreshPanel();
        if (kind == PanelKind.Episodes) _ = LoadEpisodes(_panelVersion);
        BumpInteraction();
    }

    private void ClosePanel()
    {
        if (!PanelOpen) return;
        PanelLayer.Visibility = Visibility.Collapsed;
        PanelContent.Children.Clear();
        _panel = PanelKind.None;
        _subtitleError = null;
        BumpInteraction();
    }

    private void RefreshPanelIfOpen()
    {
        if (PanelOpen && _panel != PanelKind.Episodes) RefreshPanel();
    }

    private void OnPanelScrimDown(object sender, MouseButtonEventArgs e)
    {
        ClosePanel();
        e.Handled = true;
    }

    private void OnPanelCloseClick(object sender, RoutedEventArgs e) => ClosePanel();

    private void OnPanelBackClick(object sender, RoutedEventArgs e) =>
        OpenPanel(_panel == PanelKind.FolderSubtitles ? PanelKind.Subtitles : PanelKind.More);

    private void RefreshPanel()
    {
        var items = PanelContent.Children;
        items.Clear();
        switch (_panel)
        {
            case PanelKind.More: BuildMore(items); break;
            case PanelKind.Sleep: BuildSleep(items); break;
            case PanelKind.Speed: BuildSpeed(items); break;
            case PanelKind.Audio: BuildAudio(items); break;
            case PanelKind.Subtitles: BuildSubtitles(items); break;
            case PanelKind.FolderSubtitles: BuildFolderSubtitles(items); break;
            case PanelKind.Info: BuildInfo(items); break;
            case PanelKind.Episodes:
                PanelTitle.Text = "Episodes";
                items.Add(Busy());
                break;
        }
    }

    // ---- Building blocks ------------------------------------------------------------------------

    private TextBlock Text(string text, double size = 14, string brush = "P.Text", FontWeight? weight = null, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = B(brush),
        FontWeight = weight ?? FontWeights.Normal,
        FontFamily = (FontFamily)Overlay.FindResource("P.Font"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    private Path Glyph(string key, double size, string brush = "P.Text") => new()
    {
        Data = (Geometry)Overlay.FindResource(key),
        Width = size,
        Height = size,
        Stretch = Stretch.Uniform,
        Fill = B(brush),
        IsHitTestVisible = false,
    };

    private Button Row(string title, string? detail, Action? onClick, bool check = false, bool enabled = true, string? icon = null, string titleBrush = "P.Text")
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon != null)
        {
            var g = Glyph(icon, 20, "P.Muted");
            g.Margin = new Thickness(0, 0, 16, 0);
            grid.Children.Add(g);
        }
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(Text(title, 15, titleBrush, FontWeights.SemiBold));
        if (!string.IsNullOrWhiteSpace(detail))
        {
            var d = Text(detail, 12.5, "P.Muted");
            d.Margin = new Thickness(0, 3, 0, 0);
            stack.Children.Add(d);
        }
        Grid.SetColumn(stack, 1);
        grid.Children.Add(stack);
        if (check)
        {
            var c = Glyph("P.Icon.Check", 20, "P.Amber");
            c.Margin = new Thickness(12, 0, 0, 0);
            Grid.SetColumn(c, 2);
            grid.Children.Add(c);
        }
        var b = new Button { Style = (Style)Overlay.FindResource("P.Row"), Content = grid, IsEnabled = enabled };
        System.Windows.Automation.AutomationProperties.SetName(b, title);
        if (onClick != null) b.Click += (_, _) => onClick();
        return b;
    }

    private UIElement Note(string text, string brush = "P.Muted")
    {
        var t = Text(text, 13, brush, wrap: true);
        t.Margin = new Thickness(20, 4, 20, 10);
        t.LineHeight = 19;
        return t;
    }

    private UIElement Header(string text)
    {
        var t = Text(text, 11, "P.Amber", FontWeights.Bold);
        t.Margin = new Thickness(20, 16, 20, 6);
        return t;
    }

    private UIElement Busy() => new Spinner
    {
        Width = 28, Height = 28, Thickness = 3, Stroke = B("P.Amber"), Margin = new Thickness(0, 16, 0, 16),
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    // ---- More, Sleep, Speed -------------------------------------------------------------------

    private void BuildMore(UIElementCollection items)
    {
        PanelTitle.Text = "More";
        items.Add(Row("Sleep timer", PlayerFormat.SleepDetail(_sleepEndsAt, _sleepEndOfVideo), () => OpenPanel(PanelKind.Sleep), icon: "P.Icon.Sleep"));
        items.Add(Row("Video info & decoder", _software ? "Software decoding" : "Hardware decoding", () => OpenPanel(PanelKind.Info), icon: "P.Icon.Decoder"));
        items.Add(Row("Picture in picture", null, () => { ClosePanel(); EnterMini(); }, icon: "P.Icon.Pip"));
    }

    private void BuildSleep(UIElementCollection items)
    {
        PanelTitle.Text = "Sleep timer";
        var none = _sleepEndsAt == null && !_sleepEndOfVideo;
        items.Add(Row("Off", null, () => { SetSleepTimer(null); ClosePanel(); }, check: none));
        foreach (var m in new[] { 15, 30, 45, 60, 90 })
            items.Add(Row($"{m} minutes", null, () => { SetSleepTimer(m); ClosePanel(); }));
        items.Add(Row("End of this video", null, () => { SetSleepAtEndOfVideo(); ClosePanel(); }, check: _sleepEndOfVideo));
    }

    private void BuildSpeed(UIElementCollection items)
    {
        PanelTitle.Text = "Playback speed";
        items.Add(Note("Tip: press and hold the video for 2× speed."));
        foreach (var s in PlayerMath.Speeds)
            items.Add(Row(PlayerFormat.SpeedOption(s), null, () => { SetSpeed(s); ClosePanel(); }, check: Math.Abs(s - _speed) < 0.001f));
    }

    // ---- Audio ----------------------------------------------------------------------------------

    private void BuildAudio(UIElementCollection items)
    {
        PanelTitle.Text = "Audio";
        var tracks = AudioTracks();
        if (tracks.Count == 0)
        {
            items.Add(Note("No audio tracks"));
            return;
        }
        var titles = MediaFormats.TrackTitles(tracks.Select(t => (t.Language, t.Label)).ToList(), "Track");
        var selected = _mp.AudioTrack;
        for (var i = 0; i < tracks.Count; i++)
        {
            var t = tracks[i];
            var label = MediaFormats.CleanLabel(t.Label);
            var detail = string.Join(" · ", new[]
            {
                label != null && label != MediaFormats.LanguageName(t.Language) ? label : null,
                MediaFormats.AudioCodec(t.FourCC),
                MediaFormats.Channels(t.Channels),
            }.Where(x => !string.IsNullOrEmpty(x)));
            items.Add(Row(titles[i], detail, () => { SelectAudio(t); ClosePanel(); }, check: t.Id == selected));
        }
    }

    // ---- Subtitles ------------------------------------------------------------------------------

    private void BuildSubtitles(UIElementCollection items)
    {
        PanelTitle.Text = "Subtitles";
        var embedded = EmbeddedSubtitleTracks();
        var spu = _mp.Spu;
        var noneSelected = _selectedExternal == null && !embedded.Any(t => t.Id == spu);
        items.Add(Row("Off", null, () => { DisableSubtitles(); ClosePanel(); }, check: noneSelected));

        var titles = MediaFormats.TrackTitles(embedded.Select(t => (t.Language, t.Label)).ToList(), "Subtitle");
        for (var i = 0; i < embedded.Count; i++)
        {
            var t = embedded[i];
            var label = MediaFormats.CleanLabel(t.Label);
            var detail = string.Join(" · ", new[]
            {
                label != null && label != MediaFormats.LanguageName(t.Language) ? label : null,
                t.Forced ? "Forced" : null,
                MediaFormats.SubtitleFormat(t.FourCC),
                "In video",
            }.Where(x => !string.IsNullOrEmpty(x)).Distinct());
            items.Add(Row(titles[i], detail, () => { SelectEmbeddedSubtitle(t); ClosePanel(); }, check: _selectedExternal == null && t.Id == spu));
        }

        foreach (var x in _externals)
        {
            var languageName = MediaFormats.LanguageName(x.Language);
            var detail = string.Join(" · ", new[] { languageName != null && languageName != x.Label ? languageName : null, "File" }
                .Where(s => s != null));
            var id = x.Id;
            // Choosing a file keeps the panel open so the sync can be adjusted.
            items.Add(Row(x.Label, detail, () => { SelectExternal(id); RefreshPanel(); }, check: _selectedExternal == id));
        }

        if (_selectedExternal != null) items.Add(SyncControl());
        if (_subtitleBusy) items.Add(Busy());
        if (_subtitleError != null) items.Add(Note(_subtitleError, "P.Danger"));

        items.Add(new Border { Height = 1, Background = B("P.Outline"), Margin = new Thickness(20, 8, 20, 8) });
        items.Add(Row("From the video's folder", null, () => OpenPanel(PanelKind.FolderSubtitles), icon: "P.Icon.Folder"));
        items.Add(Row("Choose a file…", null, ChooseSubtitleFile, icon: "P.Icon.Computer"));
    }

    private UIElement SyncControl()
    {
        var box = new StackPanel { Margin = new Thickness(20, 10, 20, 6) };
        var header = new DockPanel();
        var value = Text(PlayerFormat.SyncLabel(_subtitleOffsetMs), 14, "P.Amber", FontWeights.SemiBold);
        DockPanel.SetDock(value, Dock.Right);
        header.Children.Add(value);
        header.Children.Add(Text("Sync", 14, "P.Text", FontWeights.SemiBold));
        box.Children.Add(header);
        var buttons = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var (label, delta) in new[] { ("−1 s", -1000L), ("−0.1 s", -100L), ("Reset", 0L), ("+0.1 s", 100L), ("+1 s", 1000L) })
        {
            var b = new Button
            {
                Style = (Style)Overlay.FindResource("P.ChipOutline"), Content = label, Height = 34, Padding = new Thickness(12, 0, 12, 0),
                Margin = new Thickness(0, 0, 6, 6),
            };
            b.Click += (_, _) =>
            {
                SetSubtitleOffset(delta == 0 ? 0 : _subtitleOffsetMs + delta);
                RefreshPanel();
            };
            buttons.Children.Add(b);
        }
        box.Children.Add(buttons);
        var help = Text("Use + if subtitles appear before the speech, − if they're late.", 12.5, "P.Muted", wrap: true);
        help.Margin = new Thickness(0, 4, 0, 0);
        box.Children.Add(help);
        return box;
    }

    private async void ChooseSubtitleFile()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Choose a subtitle file",
            Filter = "Subtitles|*.srt;*.vtt;*.ass;*.ssa;*.ttml;*.dfxp|All files|*.*",
            CheckFileExists = true,
        };
        if (_file != null && Accounts.IsLocal(_account) && System.IO.Path.GetDirectoryName(_fileId) is { } dir && Directory.Exists(dir))
            dialog.InitialDirectory = dir;
        if (dialog.ShowDialog(this) != true) return;
        var path = dialog.FileName;
        var name = System.IO.Path.GetFileName(path);
        if (string.IsNullOrEmpty(name)) name = "subtitle.srt";
        _subtitleBusy = true;
        _subtitleError = null;
        RefreshPanelIfOpen();
        var error = await AddUserSubtitle("file:" + path, name, () => ReadSubtitleBytes(Accounts.Device, path));
        _subtitleBusy = false;
        _subtitleError = error;
        if (error == null) ClosePanel();
        else RefreshPanelIfOpen();
    }

    private async Task LoadFolderSubtitles()
    {
        _folderSubtitles = null;
        _folderLoading = true;
        _subtitleError = null;
        try { _folderSubtitles = await FolderSubtitleCandidates(); }
        catch (Exception e)
        {
            _folderSubtitles = new();
            _subtitleError = string.IsNullOrWhiteSpace(e.Message) ? "Couldn't open the file" : e.Message;
        }
        _folderLoading = false;
        if (_panel == PanelKind.FolderSubtitles) RefreshPanel();
    }

    private void BuildFolderSubtitles(UIElementCollection items)
    {
        PanelTitle.Text = "Subtitles in this folder";
        if (_folderLoading || _subtitleBusy) items.Add(Busy());
        if (!_folderLoading && _folderSubtitles is { Count: 0 })
            items.Add(Note("No .srt, .vtt or .ass files next to this video. Put one next to the video, or use “Choose a file…”."));
        foreach (var item in _folderSubtitles ?? new())
        {
            var it = item;
            items.Add(Row(it.Name, PlayerFormat.Bytes(it.SizeBytes), () => _ = AddFolderSubtitle(it), enabled: !_subtitleBusy));
        }
        if (_subtitleError != null) items.Add(Note(_subtitleError, "P.Danger"));
    }

    private async Task AddFolderSubtitle(StorageItem item)
    {
        var account = _account;
        if (account == null) return;
        _subtitleBusy = true;
        _subtitleError = null;
        RefreshPanelIfOpen();
        var error = await AddUserSubtitle("drive:" + item.Id, item.Name, () => ReadSubtitleBytes(account, item.Id));
        _subtitleBusy = false;
        _subtitleError = error;
        if (error == null) ClosePanel();
        else RefreshPanelIfOpen();
    }

    // ---- Episodes -----------------------------------------------------------------------------

    private async Task LoadEpisodes(int version)
    {
        if (ShowId is not { } showId) return;
        try
        {
            var online = AppServices.Connectivity.IsOnline;
            var files = (await AppServices.MediaFileDao.ForShow(showId)).Where(f => online || Accounts.IsLocal(f.AccountEmail)).ToList();
            var list = EpisodeNav.EpisodeList(files);
            var meta = (await AppServices.CatalogDao.Episodes(showId)).ToDictionary(e => (e.SeasonNumber, e.EpisodeNumber));
            var states = (await AppServices.WatchDao.ForShow(showId)).ToDictionary(s => s.Key);
            if (version != _panelVersion || _panel != PanelKind.Episodes) return;
            var items = PanelContent.Children;
            items.Clear();
            FrameworkElement? current = null;
            foreach (var f in list)
            {
                var season = f.Season!.Value;
                var episode = f.Episode!.Value;
                meta.TryGetValue((season, episode), out var m);
                var watched = states.TryGetValue(WatchKeys.Episode(showId, season, episode), out var st) && st.Watched;
                var isCurrent = f.DriveId == _fileId;
                var row = EpisodeRow(f.DriveId, f.AccountEmail, season, episode,
                    string.IsNullOrWhiteSpace(m?.Name) ? $"Episode {episode}" : m!.Name, TmdbImages.Still(m?.StillPath), watched, isCurrent);
                items.Add(row);
                if (isCurrent) current = row;
            }
            if (current != null)
                _ = Dispatcher.BeginInvoke(() => current.BringIntoView(), System.Windows.Threading.DispatcherPriority.Loaded);
        }
        catch (Exception e)
        {
            App.Log(e);
        }
    }

    private FrameworkElement EpisodeRow(string fileId, string account, int season, int episode, string name, string? stillUrl, bool watched, bool isCurrent)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var thumb = new Border
        {
            Width = 120, Height = 67.5, CornerRadius = new CornerRadius(10), Background = B("P.SurfaceHighest"), ClipToBounds = true,
        };
        var fallback = Text($"E{episode}", 15, "P.Muted", FontWeights.SemiBold);
        fallback.HorizontalAlignment = HorizontalAlignment.Center;
        fallback.VerticalAlignment = VerticalAlignment.Center;
        thumb.Child = fallback;
        if (stillUrl != null) _ = LoadThumb(thumb, stillUrl);
        grid.Children.Add(thumb);

        var text = new StackPanel { Margin = new Thickness(14, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Text(PlayerFormat.EpisodeCode(season, episode), 12, isCurrent ? "P.Amber" : "P.Muted", FontWeights.SemiBold));
        var title = Text(name, 14.5, "P.Text", FontWeights.SemiBold, wrap: true);
        title.MaxHeight = 40;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.Margin = new Thickness(0, 2, 0, 0);
        text.Children.Add(title);
        if (isCurrent)
        {
            var now = Text("Now playing", 12, "P.AmberSoft");
            now.Margin = new Thickness(0, 3, 0, 0);
            text.Children.Add(now);
        }
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (watched)
        {
            var check = Glyph("P.Icon.CheckCircle", 20, "P.Amber");
            System.Windows.Automation.AutomationProperties.SetName(check, "Watched");
            Grid.SetColumn(check, 2);
            grid.Children.Add(check);
        }

        var b = new Button
        {
            Style = (Style)Overlay.FindResource("P.Row"), Content = grid, Padding = new Thickness(10),
            Background = isCurrent ? B("P.AmberDim") : Brushes.Transparent, Margin = new Thickness(0, 0, 0, 4),
            IsHitTestVisible = !isCurrent,
        };
        if (!isCurrent)
            b.Click += (_, _) =>
            {
                ClosePanel();
                Open(new PlayerArgs(fileId, account, null, FromStart: watched));
            };
        return b;
    }

    private async Task LoadThumb(Border host, string url)
    {
        try
        {
            var path = await AppServices.Images.GetFile(url);
            if (path == null || !File.Exists(path)) return;
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = 240;
            bmp.UriSource = new Uri(path);
            bmp.EndInit();
            bmp.Freeze();
            host.Background = new ImageBrush(bmp) { Stretch = Stretch.UniformToFill };
            host.Child = null;
        }
        catch (Exception) { }
    }

    // ---- Video info ---------------------------------------------------------------------------

    private void BuildInfo(UIElementCollection items)
    {
        PanelTitle.Text = "Video info";
        var tracks = MediaTracks();
        var videoId = _mp.VideoTrack;
        var video = tracks.Where(t => t.TrackType == TrackType.Video).OrderByDescending(t => t.Id == videoId).Cast<MediaTrack?>().FirstOrDefault();
        var audio = tracks.Where(t => t.TrackType == TrackType.Audio).OrderByDescending(t => t.Id == _mp.AudioTrack).Cast<MediaTrack?>().FirstOrDefault();
        MediaStats stats = default;
        try { if (_media != null) stats = _media.Statistics; }
        catch (Exception) { }

        var name = _file?.Name ?? (Accounts.IsLocal(_account) ? System.IO.Path.GetFileName(_fileId) : _title);
        var size = _file?.SizeBytes ?? (Accounts.IsLocal(_account) && File.Exists(_fileId) ? new FileInfo(_fileId).Length : _streamLength);
        var ext = System.IO.Path.GetExtension(name ?? "").TrimStart('.').ToUpperInvariant();
        items.Add(Header("FILE"));
        InfoRow(items, "Name", name);
        InfoRow(items, "Size", PlayerFormat.Bytes(size));
        InfoRow(items, "Container", ext);

        var decoder = _software ? "Software" : "Hardware (D3D11VA/DXVA2)";
        if (video is { } v)
        {
            var fourcc = MediaFormats.FourCC(v.Codec);
            var codec = MediaFormats.VideoCodec(fourcc);
            items.Add(Header("VIDEO"));
            InfoRow(items, "Codec", codec);
            InfoRow(items, "Resolution", MediaFormats.Resolution((int)v.Data.Video.Width, (int)v.Data.Video.Height));
            var fps = v.Data.Video.FrameRateDen > 0 ? (double)v.Data.Video.FrameRateNum / v.Data.Video.FrameRateDen : 0;
            InfoRow(items, "Frame rate", MediaFormats.FrameRate(fps));
            InfoRow(items, "HDR", codec == "Dolby Vision" ? "Dolby Vision" : "SDR");
            var bitrate = v.Bitrate > 0 ? v.Bitrate : (long)(stats.InputBitrate * 8_000_000);
            InfoRow(items, "Bitrate", MediaFormats.Bitrate(bitrate));
            InfoRow(items, "Decoder", decoder);
            InfoRow(items, "Dropped frames", stats.LostPictures.ToString(CultureInfo.InvariantCulture));
        }
        if (audio is { } a)
        {
            items.Add(Header("AUDIO"));
            InfoRow(items, "Codec", MediaFormats.AudioCodec(MediaFormats.FourCC(a.Codec)));
            InfoRow(items, "Channels", MediaFormats.Channels((int)a.Data.Audio.Channels));
            InfoRow(items, "Sample rate", MediaFormats.SampleRate((int)a.Data.Audio.Rate));
            InfoRow(items, "Language", MediaFormats.LanguageName(MediaFormats.NormalizeLanguage(a.Language)));
            InfoRow(items, "Decoder", "Software");
        }

        // Software decoding switch
        var toggleRow = new DockPanel { Margin = new Thickness(20, 18, 20, 8) };
        var toggle = new ToggleButton
        {
            IsChecked = _software, Width = 46, Height = 26, Cursor = Cursors.Hand, Focusable = false,
            Template = SwitchTemplate(), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(16, 2, 0, 0),
        };
        System.Windows.Automation.AutomationProperties.SetName(toggle, "Software video decoding");
        toggle.Click += (_, _) => SetSoftwareDecoding(toggle.IsChecked == true);
        DockPanel.SetDock(toggle, Dock.Right);
        toggleRow.Children.Add(toggle);
        var texts = new StackPanel();
        texts.Children.Add(Text("Software video decoding", 15, "P.Text", FontWeights.SemiBold, wrap: true));
        var help = Text("Turns off hardware acceleration. Try it if the picture is green, frozen or glitchy. Uses more power; 4K may stutter.",
            12.5, "P.Muted", wrap: true);
        help.Margin = new Thickness(0, 3, 0, 0);
        texts.Children.Add(help);
        toggleRow.Children.Add(texts);
        items.Add(toggleRow);
    }

    private void InfoRow(UIElementCollection items, string key, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var grid = new Grid { Margin = new Thickness(20, 4, 20, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Text(key, 13, "P.Muted"));
        var v = Text(value, 13, "P.Text", wrap: true);
        Grid.SetColumn(v, 1);
        grid.Children.Add(v);
        items.Add(grid);
    }

    private ControlTemplate SwitchTemplate()
    {
        var template = new ControlTemplate(typeof(ToggleButton));
        var track = new FrameworkElementFactory(typeof(Border), "Track");
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(13));
        track.SetValue(Border.BackgroundProperty, B("P.SurfaceHighest"));
        track.SetValue(Border.BorderBrushProperty, B("P.OutlineStrong"));
        track.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        var knob = new FrameworkElementFactory(typeof(Ellipse), "Knob");
        knob.SetValue(WidthProperty, 18.0);
        knob.SetValue(HeightProperty, 18.0);
        knob.SetValue(Shape.FillProperty, B("P.Muted"));
        knob.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Left);
        knob.SetValue(MarginProperty, new Thickness(3, 0, 3, 0));
        track.AppendChild(knob);
        template.VisualTree = track;
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, B("P.Amber"), "Track"));
        on.Setters.Add(new Setter(Border.BorderBrushProperty, B("P.Amber"), "Track"));
        on.Setters.Add(new Setter(Shape.FillProperty, B("P.OnAmber"), "Knob"));
        on.Setters.Add(new Setter(HorizontalAlignmentProperty, HorizontalAlignment.Right, "Knob"));
        template.Triggers.Add(on);
        return template;
    }
}
