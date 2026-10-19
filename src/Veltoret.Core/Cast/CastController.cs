using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Veltoret.Core.Library;
using Veltoret.Core.TvLink;

namespace Veltoret.Core.Cast;

/// <summary>
/// Chromecast (Default Media Receiver, videos streamed from <see cref="CastServer"/> on this PC) and "Play on TV"
/// (Veltoret on a TV plays the title itself, its own copy or this PC's vlink:// stream) behind one state, as on
/// Android. Watch progress is saved like local playback, so casting and the PC resume each other.
/// </summary>
public sealed class CastController
{
    private readonly CastServer _server;
    private readonly CastServer.Opener _open;
    private readonly TvLinkClient _tvLink;
    private readonly WatchRepository _watch;
    private readonly CastMediaFactory _factory;
    private readonly Func<bool> _autoPlayNext;
    private readonly KeepAwake _awake = new();
    private readonly object _lock = new();

    private CastState _state = new();
    private ChromecastClient? _client;
    private CastDevice? _device;
    private long? _mediaSessionId;
    private long? _loadedSessionId;
    private CancellationTokenSource? _sessionCts;
    private CancellationTokenSource? _linkCts;
    private long _lastSavedAt;
    private string? _finishHandledFor;
    private int _loadGeneration;
    private volatile bool _served;

    private readonly Dictionary<string, CastDevice> _chromecasts = new();
    private readonly Dictionary<string, CastDevice> _tvs = new();
    private int _discoveryRefs;
    private CancellationTokenSource? _discoveryCts;

    public CastController(CastServer.Opener open, TvLinkClient tvLink, WatchRepository watch, CastMediaFactory factory, Func<bool> autoPlayNext)
    {
        _open = open;
        _server = new CastServer(open);
        _server.RequestReceived += () => _served = true;
        _tvLink = tvLink;
        _watch = watch;
        _factory = factory;
        _autoPlayNext = autoPlayNext;
        tvLink.Store.Changed += RefreshPairing;
    }

    public TvLinkClient TvLink => _tvLink;
    public CastMediaFactory Media => _factory;
    public CastServer Server => _server;

    public CastState State { get { lock (_lock) return _state; } }

    /// <summary>Raised on any thread; UI code marshals to its dispatcher.</summary>
    public event Action<CastState>? StateChanged;
    public event Action? DevicesChanged;

    /// <summary>
    /// The receiver never fetched the video after LOAD: most likely Windows Firewall blocks inbound connections to
    /// this PC. The app offers to add a rule.
    /// </summary>
    public event Action? ReceiverUnreachable;

    private void Update(Func<CastState, CastState> edit)
    {
        CastState next;
        lock (_lock)
        {
            next = edit(_state);
            _state = next;
        }
        StateChanged?.Invoke(next);
    }

    private static CastState Idle(CastState it) => new() { Available = it.Available, PositionMs = it.PositionMs, DurationMs = it.DurationMs, Media = it.Media };

    // =============================================================================================
    // Discovery
    // =============================================================================================

    /// <summary>Veltoret TVs first, then Chromecasts.</summary>
    public IReadOnlyList<CastDevice> Devices
    {
        get
        {
            lock (_lock)
                return _tvs.Values.OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase)
                    .Concat(_chromecasts.Values.OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase)).ToList();
        }
    }

    /// <summary>Starts looking for TVs (reference-counted; each picker calls Start and Stop).</summary>
    public void StartDiscovery()
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_discoveryRefs++ > 0) return;
            _chromecasts.Clear();
            _tvs.Clear();
            cts = new CancellationTokenSource();
            _discoveryCts = cts;
        }
        DevicesChanged?.Invoke();
        _ = Task.Run(() => DiscoverChromecasts(cts.Token));
        _ = Task.Run(() => DiscoverTvs(cts.Token));
    }

    public void StopDiscovery()
    {
        lock (_lock)
        {
            if (_discoveryRefs == 0 || --_discoveryRefs > 0) return;
            _discoveryCts?.Cancel();
            _discoveryCts = null;
        }
    }

    private async Task DiscoverChromecasts(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await foreach (var s in Mdns.Browse("_googlecast._tcp", TimeSpan.FromSeconds(10), ct))
                {
                    if (s.Address == null) continue;
                    var id = s.TxtValue("id") is { Length: > 0 } i ? i : s.Instance;
                    var device = new CastDevice(id, s.TxtValue("fn") is { Length: > 0 } fn ? fn : s.Instance, CastDeviceKind.Chromecast,
                        s.Address.ToString(), s.Port, s.TxtValue("md"));
                    lock (_lock) _chromecasts[id] = device;
                    DevicesChanged?.Invoke();
                }
            }
            catch (Exception) { }
            try { await Task.Delay(500, ct); } catch (OperationCanceledException) { }
        }
    }

    private async Task DiscoverTvs(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await foreach (var tv in _tvLink.Find(TimeSpan.FromSeconds(10), ct))
                {
                    lock (_lock) _tvs[tv.Id] = new CastDevice(tv.Id, tv.Name, CastDeviceKind.Veltoret, tv.Host, tv.Port, null, tv.Paired);
                    DevicesChanged?.Invoke();
                }
            }
            catch (Exception) { }
            try { await Task.Delay(500, ct); } catch (OperationCanceledException) { }
        }
    }

    /// <summary>Updates "paired" on the found TVs after pairing or forgetting.</summary>
    public void RefreshPairing()
    {
        lock (_lock)
            foreach (var (id, d) in _tvs.ToList())
                _tvs[id] = d with { Paired = _tvLink.Store.Secret(id) != null };
        DevicesChanged?.Invoke();
    }

    // =============================================================================================
    // Connecting
    // =============================================================================================

    /// <summary>Connects to a Chromecast or a paired Veltoret TV. Errors land in <see cref="CastState.Error"/>.</summary>
    public async Task Connect(CastDevice device)
    {
        if (device.Kind == CastDeviceKind.Veltoret)
        {
            if (_tvLink.Store.Secret(device.Id) == null) throw new LinkException($"Pair this PC with {device.Name} first", "unpaired");
            await ConnectLink(device.AsLinkTv() with { Paired = true });
            return;
        }
        if (State.Link != null) await DisconnectLink(stopTv: true);
        if (_client != null) await DisconnectChromecast(stopApp: true);
        Update(it => Idle(it) with { Connecting = true, DeviceName = device.Name });
        ChromecastClient client;
        try
        {
            client = await ChromecastClient.Connect(device.Host, device.Port, CancellationToken.None);
            try { await client.Launch(CancellationToken.None); }
            catch { await client.DisposeAsync(); throw; }
        }
        catch (Exception)
        {
            Update(it => Idle(it) with { Error = $"Couldn't connect to {device.Name}" });
            return;
        }
        var cts = new CancellationTokenSource();
        lock (_lock)
        {
            _client = client;
            _device = device;
            _mediaSessionId = null;
            _loadedSessionId = null;
            _sessionCts = cts;
        }
        client.MediaStatus += OnMediaStatus;
        client.ReceiverStatus += OnReceiverStatus;
        client.Closed += () => _ = OnChromecastDropped(client);
        Update(it => it with { Connecting = false, Connected = true, DeviceName = device.Name, Error = null });
        _ = Safe(client.ReceiverGetStatus());
        _ = Task.Run(() => PollChromecast(client, cts.Token));
    }

    /// <summary>Stops casting (and the video on the TV). Returns the TV's last position, for the local player.</summary>
    public async Task<long> Disconnect()
    {
        if (State.Link != null) await DisconnectLink(stopTv: true);
        else if (_client != null) await DisconnectChromecast(stopApp: true);
        return State.PositionMs;
    }

    private async Task DisconnectChromecast(bool stopApp)
    {
        ChromecastClient? client;
        lock (_lock)
        {
            client = _client;
            _client = null;
            _device = null;
            _mediaSessionId = null;
            _loadedSessionId = null;
            _sessionCts?.Cancel();
            _sessionCts = null;
        }
        if (client == null) return;
        SaveProgress();
        client.MediaStatus -= OnMediaStatus;
        client.ReceiverStatus -= OnReceiverStatus;
        if (stopApp) await client.StopApp();
        await client.DisposeAsync();
        _server.Stop();
        _awake.Release();
        Update(Idle);
    }

    private async Task OnChromecastDropped(ChromecastClient client)
    {
        bool current;
        lock (_lock) current = _client == client;
        if (!current) return;
        await DisconnectChromecast(stopApp: false);
    }

    // =============================================================================================
    // "Play on TV" (Veltoret on the TV)
    // =============================================================================================

    private async Task ConnectLink(LinkTv tv)
    {
        if (_client != null) await DisconnectChromecast(stopApp: true);
        CancellationTokenSource cts;
        lock (_lock)
        {
            _linkCts?.Cancel();
            cts = new CancellationTokenSource();
            _linkCts = cts;
        }
        Update(it => Idle(it) with { Connected = true, DeviceName = tv.Name, Link = tv });
        _ = Task.Run(() => PollLink(tv, cts.Token));
    }

    private async Task DisconnectLink(bool stopTv)
    {
        LinkTv? tv;
        lock (_lock)
        {
            tv = _state.Link;
            if (tv == null) return;
            _linkCts?.Cancel();
            _linkCts = null;
        }
        SaveProgress();
        if (stopTv)
        {
            try { await _tvLink.Command(tv, new LinkCommand { Type = LinkCommand.Stop }); }
            catch (Exception) { }
        }
        _server.Stop();
        _awake.Release();
        Update(Idle);
    }

    private async Task LoadLink(LinkTv tv, CastMedia media, long startMs)
    {
        _finishHandledFor = null;
        Update(it => it with
        {
            Media = media, Finished = false, Error = null, PositionMs = startMs, Buffering = true, Playing = false, LinkSource = null,
            DurationMs = media.DurationMs > 0 ? media.DurationMs : 0,
        });
        _ = UpdateHasNext(media);
        try
        {
            // The TV plays its own copy when it has one; this PC's stream is the fallback.
            _server.Start(CastServer.AddressFacing(IPAddress.Parse(tv.Host)));
            var stream = TvLinkProtocol.StreamUrl(_server.Media($"v{CastFormats.JavaHash(media.FileId)}", media.Account, media.FileId,
                CastFormats.MimeFor(media.Name), media.SizeBytes));
            var f = media.File;
            var request = new LinkPlay
            {
                Title = media.Title, Subtitle = media.Subtitle,
                FileId = media.FileId, AccountEmail = f?.AccountEmail ?? media.Account, FileName = f?.Name ?? media.FileName,
                MovieId = f?.MovieId, ShowId = f?.ShowId, Season = f?.Season, Episode = f?.Episode,
                StreamUrl = stream, StartMs = startMs,
                AudioLanguage = media.AudioLanguage, SubtitleLanguage = media.SubtitleLanguage,
            };
            var source = await _tvLink.Play(tv, request);
            if (source == LinkStatus.SourcePhone) _awake.Acquire();
            Update(it => it with { LinkSource = source });
        }
        catch (Exception e)
        {
            Update(it => it with { Error = string.IsNullOrEmpty(e.Message) ? $"Couldn't play on {tv.Name}" : e.Message, Buffering = false });
        }
    }

    private async Task LinkCommandAsync(LinkCommand command)
    {
        var tv = State.Link;
        if (tv == null) return;
        try { await _tvLink.Command(tv, command); }
        catch (Exception e) { Update(it => it with { Error = e.Message }); }
    }

    public void SelectLinkAudio(string id)
    {
        Update(it => it with { LinkAudioSelected = id });
        _ = LinkCommandAsync(new LinkCommand { Type = LinkCommand.Audio, Track = id });
    }

    /// <summary>A subtitle id from LinkStatus, or null for off.</summary>
    public void SelectLinkSubtitle(string? id)
    {
        Update(it => it with { LinkSubtitleSelected = id });
        _ = LinkCommandAsync(new LinkCommand { Type = LinkCommand.Subtitle, Track = id });
    }

    /// <summary>Follows the TV once a second: position, play state, its real audio and subtitle tracks.</summary>
    private async Task PollLink(LinkTv tv, CancellationToken ct)
    {
        var wasActive = false;
        var failures = 0;
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(1_000, ct); } catch (OperationCanceledException) { return; }
            LinkStatus status;
            try
            {
                status = await _tvLink.Status(tv, ct);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e)
            {
                if (++failures >= 6) Update(it => it with { Error = e is LinkException { Message.Length: > 0 } ? e.Message : $"Lost touch with {tv.Name}" });
                // Forgotten after a 401: nothing more to do here.
                if (e is LinkException { Code: "unpaired" }) { await DisconnectLink(stopTv: false); return; }
                continue;
            }
            if (ct.IsCancellationRequested) return;
            failures = 0;
            if (!status.Active)
            {
                // The player was closed on the TV (Back): the PC takes over where it stopped.
                if (wasActive && !status.Ended) { await DisconnectLink(stopTv: false); return; }
                if (status.Ended)
                {
                    Update(it => it with { Playing = false, Buffering = false, Finished = true });
                    await OnFinished();
                }
                continue;
            }
            wasActive = true;
            var wasPlaying = State.Playing;
            Update(it => it with
            {
                Playing = status.Playing,
                Buffering = status.Buffering,
                PositionMs = status.PositionMs,
                DurationMs = status.DurationMs > 0 ? status.DurationMs : it.DurationMs,
                Finished = status.Ended,
                Error = status.Error,
                LinkSource = status.Source.Length > 0 ? status.Source : it.LinkSource,
                LinkAudio = status.Audio,
                LinkAudioSelected = status.AudioSelected,
                LinkSubtitles = status.Subtitles,
                LinkSubtitleSelected = status.SubtitleSelected,
            });
            var now = Environment.TickCount64;
            if (status.Ended) await OnFinished();
            else if (wasPlaying && !status.Playing) SaveProgress();
            else if (status.Playing && now - _lastSavedAt > 10_000) SaveProgress();
        }
    }

    // =============================================================================================
    // Media
    // =============================================================================================

    /// <summary>Sends <paramref name="media"/> to the TV, starting at <paramref name="startMs"/>.</summary>
    public async Task Load(CastMedia media, long startMs)
    {
        if (State.Link is { } tv) { await LoadLink(tv, media, startMs); return; }
        ChromecastClient? client;
        CastDevice? device;
        lock (_lock) { client = _client; device = _device; }
        if (client == null || device == null) return;
        var generation = Interlocked.Increment(ref _loadGeneration);
        _finishHandledFor = null;
        try
        {
            _server.Start(CastServer.AddressFacing(IPAddress.Parse(device.Host)));
            IReadOnlyDictionary<long, byte>? patches = null;
            if (media.AudioTrack is { } keep && media.AudioOptions.Count > 1)
            {
                patches = await Task.Run(async () =>
                {
                    await using var stream = await _open(media.Account, media.FileId, CancellationToken.None);
                    return CastAudio.HideAllBut(CastAudio.AudioTracks(CastAudio.StreamReader(stream)), keep);
                });
            }
            var mime = CastFormats.MimeFor(media.Name);
            // Each audio choice gets its own URL so the receiver doesn't reuse a cached stream.
            var video = _server.Media($"v{CastFormats.JavaHash(media.FileId)}a{media.AudioTrack ?? 0}", media.Account, media.FileId, mime, media.SizeBytes, patches);
            var subtitles = media.Subtitles.Select((sub, i) =>
                new CastLoadRequest.SubtitleTrack(sub.Label, _server.Text($"s{i}-{CastFormats.JavaHash(sub.Id)}", sub.Vtt), sub.Language)).ToList();
            var activeIndex = media.Subtitles.Select((s, i) => (s, i)).FirstOrDefault(x => x.s.Id == media.ActiveSubtitle && media.ActiveSubtitle != null);
            int? active = media.ActiveSubtitle != null && activeIndex.s != null ? activeIndex.i : null;

            _awake.Acquire();
            _served = false;
            Update(it => it with
            {
                Media = media, Finished = false, Error = null, PositionMs = startMs, Buffering = true,
                ActiveSubtitle = active != null ? media.ActiveSubtitle : null,
                DurationMs = media.DurationMs > 0 ? media.DurationMs : 0,
            });
            _ = UpdateHasNext(media);
            _ = WatchReachability(generation);
            var reply = await client.Load((id, session) => CastLoadRequest.Build(id, session, video, mime, media, startMs, subtitles, active), CancellationToken.None);
            // Statuses of the media this LOAD replaced are ignored from now on.
            if (generation == _loadGeneration && SessionIdOf(reply) is { } loaded) lock (_lock) _loadedSessionId = loaded;
        }
        catch (CastLoadException e)
        {
            if (generation == _loadGeneration) Update(it => it with { Error = e.Message, Buffering = false });
            if (!_served) ReceiverUnreachable?.Invoke();
        }
        catch (Exception e)
        {
            if (generation == _loadGeneration) Update(it => it with { Error = $"Couldn't start casting: {e.Message}", Buffering = false });
        }
    }


    /// <summary>If the receiver hasn't fetched anything 20 s after LOAD, the PC is probably unreachable (firewall).</summary>
    private async Task WatchReachability(int generation)
    {
        await Task.Delay(20_000);
        if (generation != _loadGeneration || _served) return;
        var st = State;
        if (st.Connected && st.Link == null && !st.Playing) ReceiverUnreachable?.Invoke();
    }

    private async Task UpdateHasNext(CastMedia media)
    {
        try
        {
            var next = await _factory.NextEpisode(media.File);
            Update(it => it.Media?.FileId == media.FileId ? it with { HasNext = next != null } : it);
        }
        catch (Exception) { }
    }

    public void Play()
    {
        if (State.Link != null) { _ = LinkCommandAsync(new LinkCommand { Type = LinkCommand.Play }); return; }
        _ = MediaCommand("PLAY");
    }

    public void Pause()
    {
        if (State.Link != null) { _ = LinkCommandAsync(new LinkCommand { Type = LinkCommand.Pause }); return; }
        _ = MediaCommand("PAUSE");
    }

    public void TogglePlay()
    {
        if (State.Playing) Pause(); else Play();
    }

    public void SeekTo(long ms)
    {
        ms = Math.Max(0, ms);
        if (State.Link != null) _ = LinkCommandAsync(new LinkCommand { Type = LinkCommand.Seek, PositionMs = ms });
        else _ = MediaCommand("SEEK", new JsonObject { ["currentTime"] = ms / 1000.0 });
        Update(it => it with { PositionMs = ms });
    }

    public void SeekBy(long deltaMs) => SeekTo(State.PositionMs + deltaMs);

    /// <summary>Shows subtitle <paramref name="id"/> on the Chromecast, or none.</summary>
    public void SelectSubtitle(string? id)
    {
        var media = State.Media;
        if (media == null) return;
        var index = -1;
        for (var i = 0; i < media.Subtitles.Count; i++) if (media.Subtitles[i].Id == id) { index = i; break; }
        _ = MediaCommand("EDIT_TRACKS_INFO", new JsonObject { ["activeTrackIds"] = index >= 0 ? new JsonArray(index + 1) : new JsonArray() });
        Update(it => it with { ActiveSubtitle = index >= 0 ? id : null });
    }

    /// <summary>Switches the audio on the Chromecast: the video reloads at the same spot with only that track audible.</summary>
    public async Task SwitchAudio(long track)
    {
        var st = State;
        var media = st.Media;
        if (media == null || st.Link != null || media.AudioTrack == track) return;
        var codec = media.AudioOptions.FirstOrDefault(o => o.Track == track)?.Codec;
        await Load(media with { AudioTrack = track, AudioWarning = CastFormats.AudioWarning(codec, media.Name), ActiveSubtitle = st.ActiveSubtitle }, st.PositionMs);
    }

    /// <summary>Chromecast volume, 0..1.</summary>
    public void SetVolume(double level)
    {
        var client = _client;
        if (client == null) return;
        Update(it => it with { Volume = Math.Clamp(level, 0, 1), Muted = false });
        _ = Safe(client.SetVolume(level));
    }

    public void SetMuted(bool muted)
    {
        var client = _client;
        if (client == null) return;
        Update(it => it with { Muted = muted });
        _ = Safe(client.SetMuted(muted));
    }

    /// <summary>Plays the next episode on the TV (the remote's "Next episode", and auto-play at the end).</summary>
    public async Task PlayNext()
    {
        var media = State.Media;
        var next = await _factory.NextEpisode(media?.File);
        if (next == null) return;
        var nextMedia = await _factory.ForFile(next);
        long start = 0;
        try
        {
            var saved = await _watch.Get(WatchKeys.ForFile(next));
            if (saved is { Watched: false, PositionMs: > 0 }) start = saved.PositionMs;
        }
        catch (Exception) { }
        await Load(nextMedia, start);
    }

    private async Task OnFinished()
    {
        var media = State.Media;
        if (media == null || _finishHandledFor == media.FileId) return;
        _finishHandledFor = media.FileId;
        SaveProgress(ended: true);
        if (!_autoPlayNext()) return;
        try { await PlayNext(); } catch (Exception) { }
    }

    private async Task MediaCommand(string type, JsonObject? extra = null)
    {
        ChromecastClient? client;
        long? session;
        lock (_lock) { client = _client; session = _mediaSessionId; }
        if (client == null || session == null) return;
        await Safe(client.MediaCommand(type, session.Value, extra));
    }

    private static async Task Safe(Task task)
    {
        try { await task; } catch (Exception) { }
    }

    private async Task PollChromecast(ChromecastClient client, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(1_000, ct); } catch (OperationCanceledException) { return; }
            bool hasSession;
            lock (_lock) hasSession = _mediaSessionId != null && _client == client;
            if (!hasSession) continue;
            await Safe(client.MediaGetStatus());
        }
    }

    private static long? SessionIdOf(JsonElement payload) =>
        payload.TryGetProperty("status", out var list) && list.ValueKind == JsonValueKind.Array && list.GetArrayLength() > 0
        && list[0].TryGetProperty("mediaSessionId", out var id) && id.ValueKind == JsonValueKind.Number ? id.GetInt64() : null;

    private void OnReceiverStatus(JsonElement payload)
    {
        if (!payload.TryGetProperty("status", out var s) || !s.TryGetProperty("volume", out var v)) return;
        double? level = v.TryGetProperty("level", out var l) && l.ValueKind == JsonValueKind.Number ? l.GetDouble() : null;
        bool? muted = v.TryGetProperty("muted", out var m) && m.ValueKind is JsonValueKind.True or JsonValueKind.False ? m.GetBoolean() : null;
        Update(it => it with { Volume = level ?? it.Volume, Muted = muted ?? it.Muted });
    }

    private void OnMediaStatus(JsonElement payload)
    {
        if (!payload.TryGetProperty("status", out var list) || list.ValueKind != JsonValueKind.Array) return;
        if (list.GetArrayLength() == 0) return;
        var s = list[0];
        if (s.TryGetProperty("mediaSessionId", out var msid) && msid.ValueKind == JsonValueKind.Number)
        {
            var id = msid.GetInt64();
            lock (_lock)
            {
                if (_loadedSessionId is { } loaded && id < loaded) return; // the video before the current one
                _mediaSessionId = id;
            }
        }
        var playerState = s.TryGetProperty("playerState", out var ps) ? ps.GetString() ?? "IDLE" : "IDLE";
        var idleReason = s.TryGetProperty("idleReason", out var ir) ? ir.GetString() : null;
        long? position = s.TryGetProperty("currentTime", out var ctm) && ctm.ValueKind == JsonValueKind.Number ? (long)(ctm.GetDouble() * 1000) : null;
        long? duration = s.TryGetProperty("media", out var media) && media.TryGetProperty("duration", out var d) && d.ValueKind == JsonValueKind.Number
            ? (long)(d.GetDouble() * 1000) : null;
        var idle = playerState == "IDLE";
        var finished = idle && idleReason == "FINISHED";
        var failed = idle && idleReason == "ERROR";
        var wasPlaying = State.Playing;
        var playing = playerState == "PLAYING";
        Update(it => it with
        {
            Playing = playing,
            Buffering = playerState is "BUFFERING" or "LOADING",
            PositionMs = !idle && position is { } p ? p : it.PositionMs,
            DurationMs = duration is > 0 ? duration.Value : it.DurationMs,
            Finished = finished || (it.Finished && idle),
            Error = failed ? "The TV couldn't play this video. Its format may not be supported by Chromecast." : it.Error,
        });
        if (finished) _ = OnFinished();
        else if (wasPlaying && !playing) SaveProgress();
        else if (playing && Environment.TickCount64 - _lastSavedAt > 10_000) SaveProgress();
    }

    /// <summary>Watch progress, shared with local playback (resume works both ways).</summary>
    public void SaveProgress(bool ended = false)
    {
        var st = State;
        var media = st.Media;
        if (media == null) return;
        var duration = st.DurationMs > 0 ? st.DurationMs : media.File?.DurationMs ?? 0;
        if (duration <= 0) return;
        var position = ended ? duration : st.PositionMs;
        if (position <= 0) return;
        _lastSavedAt = Environment.TickCount64;
        _ = Task.Run(async () =>
        {
            try { await _watch.SavePosition(media.File, media.FileId, position, duration); }
            catch (Exception) { }
        });
    }

    /// <summary>App exit: stop the TV and the server.</summary>
    public void Shutdown()
    {
        try { Disconnect().Wait(TimeSpan.FromSeconds(3)); } catch (Exception) { }
        _server.Stop();
        _awake.Release();
        StopDiscoveryAll();
    }

    private void StopDiscoveryAll()
    {
        lock (_lock)
        {
            _discoveryRefs = 0;
            _discoveryCts?.Cancel();
            _discoveryCts = null;
        }
    }
}
