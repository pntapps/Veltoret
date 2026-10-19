using LibVLCSharp.Shared;
using Veltoret.App.Services;
using Veltoret.Core.Library;
using Veltoret.Core.Player;
using Veltoret.Core.Storage;

namespace Veltoret.App.Player;

public partial class PlayerWindow
{
    /// <summary>An audio or embedded subtitle track as the panels show it. Ordinal = position among tracks of its type.</summary>
    private sealed record TrackItem(int Id, int Ordinal, string? Language, string? Label, string? FourCC, int Channels, int Rate, string Name)
    {
        public bool Forced => (Label ?? Name).Contains("forced", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>A subtitle file Veltoret loaded (sidecar, from the folder, or from This PC); libVLC renders it as a slave.</summary>
    private sealed class ExternalSub(string id, string label, string? language, string path)
    {
        public string Id { get; } = id;
        public string Label { get; } = label;
        public string? Language { get; } = language;
        /// <summary>UTF-8 copy in %TEMP% handed to libVLC.</summary>
        public string Path { get; } = path;
        /// <summary>libVLC's SPU id once the slave is added.</summary>
        public int? SpuId { get; set; }
    }

    private readonly List<ExternalSub> _externals = new();
    private readonly HashSet<int> _slaveSpuIds = new();
    private readonly List<string> _tempFiles = new();
    private string? _selectedExternal;
    private ExternalSub? _pendingSlave;
    private ExternalSub? _queuedSlave;
    private HashSet<int> _spuBeforeSlave = new();
    private DateTime _pendingSlaveSince;
    private long _subtitleOffsetMs;
    private bool _subtitleBusy;
    private string? _subtitleError;

    // ---------------------------------------------------------------------------------------------
    // Track lists
    // ---------------------------------------------------------------------------------------------

    private MediaTrack[] MediaTracks()
    {
        try { return _media?.Tracks ?? Array.Empty<MediaTrack>(); }
        catch (Exception) { return Array.Empty<MediaTrack>(); }
    }

    private List<TrackItem> BuildTracks(IEnumerable<LibVLCSharp.Shared.Structures.TrackDescription> descriptions, TrackType type, Func<int, bool>? include = null)
    {
        var meta = MediaTracks().Where(t => t.TrackType == type).ToList();
        var list = new List<TrackItem>();
        foreach (var d in descriptions)
        {
            if (d.Id == -1 || (include != null && !include(d.Id))) continue;
            var found = meta.FindIndex(t => t.Id == d.Id);
            if (found >= 0)
            {
                var m = meta[found];
                list.Add(new TrackItem(d.Id, list.Count, MediaFormats.NormalizeLanguage(m.Language), m.Description, MediaFormats.FourCC(m.Codec),
                    type == TrackType.Audio ? (int)m.Data.Audio.Channels : 0, type == TrackType.Audio ? (int)m.Data.Audio.Rate : 0, d.Name ?? ""));
            }
            else
            {
                list.Add(new TrackItem(d.Id, list.Count, null, d.Name, null, 0, 0, d.Name ?? ""));
            }
        }
        return list;
    }

    private List<TrackItem> AudioTracks()
    {
        try { return BuildTracks(_mp.AudioTrackDescription, TrackType.Audio); }
        catch (Exception) { return new(); }
    }

    /// <summary>Text tracks in the video (subtitle files Veltoret added are listed separately).</summary>
    private List<TrackItem> EmbeddedSubtitleTracks()
    {
        try { return BuildTracks(_mp.SpuDescription, TrackType.Text, id => !_slaveSpuIds.Contains(id)); }
        catch (Exception) { return new(); }
    }

    private static TrackItem? Pick(List<TrackItem> tracks, int? ordinal, string? language)
    {
        var lang = MediaFormats.NormalizeLanguage(language);
        if (ordinal is { } o && o >= 0 && o < tracks.Count && (lang == null || tracks[o].Language == lang)) return tracks[o];
        return lang == null ? null : tracks.FirstOrDefault(t => t.Language == lang);
    }

    private bool EmbeddedSubtitleSelected => _selectedExternal == null && _mp.Spu != -1 && !_slaveSpuIds.Contains(_mp.Spu);

    // ---------------------------------------------------------------------------------------------
    // Restoring choices once the tracks are known (once per video)
    // ---------------------------------------------------------------------------------------------

    private void ApplyTracksOnce()
    {
        _tracksApplied = true;
        var memory = _restore;
        _restore = null;

        var audio = AudioTracks();
        var a = memory != null ? Pick(audio, memory.AudioIndex, memory.AudioLanguage) : null;
        a ??= _wantedAudio != null ? audio.FirstOrDefault(t => t.Language == _wantedAudio) : null;
        if (a != null && _mp.AudioTrack != a.Id) _mp.SetAudioTrack(a.Id);

        var subs = EmbeddedSubtitleTracks();
        switch (memory?.SubtitleMode)
        {
            case TrackMemory.SubOff:
                SubtitlesOffKeepForced(subs);
                break;
            case TrackMemory.SubEmbedded:
                if (Pick(subs, memory.SubtitleIndex, memory.SubtitleLanguage) is { } chosen) SetSpu(chosen.Id);
                else SubtitlesOffKeepForced(subs);
                break;
            case TrackMemory.SubExternal:
                SubtitlesOffKeepForced(subs);
                if (memory.ExternalSource is { } source) _ = RestoreExternal(source, memory.ExternalName ?? "Subtitles");
                break;
            default:
                var wanted = _wantedSubtitle;
                var match = wanted == null || wanted == PlayerPrefsStore.Off ? null
                    : subs.FirstOrDefault(t => t.Language == wanted && !t.Forced) ?? subs.FirstOrDefault(t => t.Language == wanted);
                if (match != null) SetSpu(match.Id);
                else SubtitlesOffKeepForced(subs);
                break;
        }
        ApplyPendingSubtitleChoice();
        UpdateUi();
    }

    private void SetSpu(int id)
    {
        _mp.SetSpu(id);
        _mp.SetSpuDelay(0);
    }

    /// <summary>
    /// "Off" means off: the file's default subtitle track is ignored, but forced subtitles (signs, foreign-language
    /// lines) in the audio's language still show. libVLC 3 has no forced flag, so a track titled "Forced" counts.
    /// </summary>
    private void SubtitlesOffKeepForced(List<TrackItem> subs)
    {
        var audioLanguage = AudioTracks().FirstOrDefault(t => t.Id == _mp.AudioTrack)?.Language;
        var forced = subs.FirstOrDefault(t => t.Forced && (t.Language == null || audioLanguage == null || t.Language == audioLanguage));
        _mp.SetSpu(forced?.Id ?? -1);
    }

    /// <summary>The preferred subtitle language isn't in the video but a sidecar file has it: use the file.</summary>
    private void ApplyPendingSubtitleChoice()
    {
        var wanted = _autoSubtitlePending;
        if (wanted == null || !_tracksApplied) return;
        if (EmbeddedSubtitleSelected)
        {
            _autoSubtitlePending = null;
            return;
        }
        if (_externals.FirstOrDefault(x => x.Language == wanted) is { } ext)
        {
            _autoSubtitlePending = null;
            SelectExternal(ext.Id, remember: false);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // User choices (remembered)
    // ---------------------------------------------------------------------------------------------

    private void SelectAudio(TrackItem track)
    {
        _mp.SetAudioTrack(track.Id);
        PlayerPrefs.Shared.SetAudioLanguage(ShowId, track.Language);
        PlayerPrefs.Shared.UpdateTrackMemory(_fileId, m => m with { AudioIndex = track.Ordinal, AudioLanguage = track.Language });
    }

    private void SelectEmbeddedSubtitle(TrackItem track)
    {
        _selectedExternal = null;
        _autoSubtitlePending = null;
        SetSpu(track.Id);
        if (track.Language != null) PlayerPrefs.Shared.SetSubtitleLanguage(ShowId, track.Language);
        PlayerPrefs.Shared.UpdateTrackMemory(_fileId, m => m with
        {
            SubtitleMode = TrackMemory.SubEmbedded, SubtitleIndex = track.Ordinal, SubtitleLanguage = track.Language,
            ExternalSource = null, ExternalName = null,
        });
    }

    private void DisableSubtitles()
    {
        _autoSubtitlePending = null;
        _selectedExternal = null;
        _mp.SetSpu(-1);
        PlayerPrefs.Shared.SetSubtitleLanguage(ShowId, null);
        PlayerPrefs.Shared.UpdateTrackMemory(_fileId, m => m with { SubtitleMode = TrackMemory.SubOff, ExternalSource = null, ExternalName = null });
    }

    private void SelectExternal(string id, bool remember = true)
    {
        var sub = _externals.FirstOrDefault(x => x.Id == id);
        if (sub == null) return;
        _selectedExternal = id;
        if (sub.SpuId is { } spu)
        {
            _mp.SetSpu(spu);
            _mp.SetSpuDelay(_subtitleOffsetMs * 1000);
        }
        else if (_pendingSlave == null) AddSlave(sub);
        else _queuedSlave = sub;
        if (remember)
        {
            if (sub.Language != null) PlayerPrefs.Shared.SetSubtitleLanguage(ShowId, sub.Language);
            PlayerPrefs.Shared.UpdateTrackMemory(_fileId, m => m with
            {
                SubtitleMode = TrackMemory.SubExternal, ExternalSource = id, ExternalName = sub.Label, SubtitleIndex = null,
            });
        }
        UpdateUi();
    }

    private void AddSlave(ExternalSub sub)
    {
        try
        {
            _spuBeforeSlave = _mp.SpuDescription.Select(d => d.Id).ToHashSet();
        }
        catch (Exception) { _spuBeforeSlave = new(); }
        _pendingSlave = sub;
        _pendingSlaveSince = DateTime.UtcNow;
        _mp.AddSlave(MediaSlaveType.Subtitle, new Uri(sub.Path).AbsoluteUri, true);
    }

    /// <summary>Finds the SPU id libVLC gave a subtitle file just added.</summary>
    private void PollSlaves()
    {
        var pending = _pendingSlave;
        if (pending == null) return;
        int[] ids;
        try { ids = _mp.SpuDescription.Select(d => d.Id).ToArray(); }
        catch (Exception) { return; }
        var fresh = ids.FirstOrDefault(i => i != -1 && !_spuBeforeSlave.Contains(i) && !_slaveSpuIds.Contains(i), -2);
        if (fresh != -2)
        {
            pending.SpuId = fresh;
            _slaveSpuIds.Add(fresh);
            _pendingSlave = null;
            if (_selectedExternal == pending.Id)
            {
                _mp.SetSpu(fresh);
                _mp.SetSpuDelay(_subtitleOffsetMs * 1000);
            }
            else if (_selectedExternal == null && !EmbeddedSubtitleSelected) _mp.SetSpu(-1);
            if (_queuedSlave is { } q)
            {
                _queuedSlave = null;
                if (q.SpuId == null && _selectedExternal == q.Id) AddSlave(q);
            }
            RefreshPanelIfOpen();
        }
        else if ((DateTime.UtcNow - _pendingSlaveSince).TotalSeconds > 8)
        {
            _pendingSlave = null;
        }
    }

    private void SetSubtitleOffset(long ms)
    {
        _subtitleOffsetMs = ms;
        if (_selectedExternal != null) _mp.SetSpuDelay(ms * 1000);
        PlayerPrefs.Shared.UpdateTrackMemory(_fileId, m => m with { SubtitleOffsetMs = ms });
    }

    // ---------------------------------------------------------------------------------------------
    // Loading files
    // ---------------------------------------------------------------------------------------------

    private void ResetExternals()
    {
        _externals.Clear();
        _slaveSpuIds.Clear();
        _selectedExternal = null;
        _pendingSlave = null;
        _queuedSlave = null;
        _subtitleError = null;
        _subtitleBusy = false;
    }

    private string WriteTemp(byte[] bytes, string name)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Veltoret", "subtitles");
        Directory.CreateDirectory(dir);
        var ext = Path.GetExtension(name);
        if (string.IsNullOrEmpty(ext) || !FilenameParser.IsSubtitle(name)) ext = ".srt";
        var path = Path.Combine(dir, Guid.NewGuid().ToString("N") + ext.ToLowerInvariant());
        File.WriteAllBytes(path, SubtitleEngine.ToUtf8WithBom(bytes));
        _tempFiles.Add(path);
        return path;
    }

    private void CleanupTempSubtitles()
    {
        foreach (var f in _tempFiles)
        {
            try { File.Delete(f); }
            catch (Exception) { }
        }
        _tempFiles.Clear();
    }

    private static async Task<byte[]> ReadSubtitleBytes(string account, string id, CancellationToken ct = default)
    {
        if (Accounts.IsLocal(account))
        {
            await using var local = File.OpenRead(id);
            return await SubtitleEngine.ReadLimited(local, ct);
        }
        await using var s = await AppServices.Storage.OpenRead(account, id, ct);
        return await SubtitleEngine.ReadLimited(s, ct);
    }

    /// <summary>Parses in the background and writes the UTF-8 copy; null when the file has no cues.</summary>
    private async Task<string?> PrepareSubtitle(byte[] bytes, string name)
    {
        var cues = await Task.Run(() => SubtitleEngine.Parse(bytes, name));
        return cues.Count == 0 ? null : WriteTemp(bytes, name);
    }

    private void AddExternal(ExternalSub sub, bool select, bool remember)
    {
        _externals.RemoveAll(x => x.Id == sub.Id);
        _externals.Add(sub);
        if (select) SelectExternal(sub.Id, remember);
        RefreshPanelIfOpen();
    }

    /// <summary>Subtitle files beside the video with the same base name (library index, plus the folder on disk for This PC).</summary>
    private async Task LoadSidecars(CancellationToken ct)
    {
        var file = _file;
        var account = _account;
        if (account == null) return;
        var local = Accounts.IsLocal(account);
        var videoName = file?.Name ?? (local ? Path.GetFileName(_fileId) : null);
        if (videoName == null) return;

        var candidates = new List<(string Account, string Id, string Name)>();
        if (file != null && !string.IsNullOrEmpty(file.ParentId))
        {
            try
            {
                candidates.AddRange((await AppServices.MediaFileDao.SubtitlesIn(file.ParentId)).Select(s => (s.AccountEmail, s.DriveId, s.Name)));
            }
            catch (Exception e) { App.Log(e); }
        }
        if (local)
        {
            try
            {
                var dir = Path.GetDirectoryName(_fileId);
                if (dir != null && Directory.Exists(dir))
                    candidates.AddRange(Directory.EnumerateFiles(dir).Select(p => (Accounts.Device, p, Path.GetFileName(p))));
            }
            catch (Exception) { }
        }
        var unique = candidates.GroupBy(c => c.Id, StringComparer.OrdinalIgnoreCase).Select(g => g.First()).ToList();
        foreach (var match in Sidecars.Match(videoName, unique, c => c.Name))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var bytes = await ReadSubtitleBytes(match.File.Account, match.File.Id, ct);
                var path = await PrepareSubtitle(bytes, match.Name);
                ct.ThrowIfCancellationRequested();
                if (path == null) continue;
                var language = MediaFormats.NormalizeLanguage(match.Language);
                var label = match.Language != null ? MediaFormats.LanguageName(match.Language) ?? match.Name : match.Name;
                AddExternal(new ExternalSub("side:" + match.File.Id, label, language, path), select: false, remember: false);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { /* files that fail to read or parse are skipped */ }
        }
        ApplyPendingSubtitleChoice();
    }

    /// <summary>Reloads a previously chosen file ("drive:…", "file:…" or a sidecar "side:…").</summary>
    private async Task RestoreExternal(string source, string name)
    {
        if (_externals.Any(x => x.Id == source))
        {
            SelectExternal(source, remember: false);
            return;
        }
        var account = _account;
        var fileId = _fileId;
        if (account == null) return;
        try
        {
            byte[]? bytes = null;
            if (source.StartsWith("drive:", StringComparison.Ordinal) || source.StartsWith("side:", StringComparison.Ordinal))
            {
                var id = source[(source.IndexOf(':') + 1)..];
                bytes = await ReadSubtitleBytes(Accounts.IsLocal(account) || File.Exists(id) ? Accounts.Device : account, id);
            }
            else if (source.StartsWith("file:", StringComparison.Ordinal))
            {
                bytes = await ReadSubtitleBytes(Accounts.Device, source[5..]);
            }
            if (bytes == null || fileId != _fileId) return;
            var path = await PrepareSubtitle(bytes, name);
            if (path == null || fileId != _fileId) return;
            AddExternal(new ExternalSub(source, name, null, path), select: true, remember: false);
        }
        catch (Exception) { }
    }

    /// <summary>Adds a subtitle file the user picked. Returns an error message, or null on success.</summary>
    private async Task<string?> AddUserSubtitle(string source, string name, Func<Task<byte[]>> read)
    {
        try
        {
            var bytes = await read();
            var path = await PrepareSubtitle(bytes, name);
            if (path == null) return $"No subtitles found in {name}";
            AddExternal(new ExternalSub(source, name, null, path), select: true, remember: true);
            return null;
        }
        catch (SubtitleException e)
        {
            return e.Message;
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException or UnauthorizedAccessException)
        {
            return "Couldn't open the file";
        }
        catch (Exception e)
        {
            return string.IsNullOrWhiteSpace(e.Message) ? $"Couldn't read {name}" : e.Message;
        }
    }

    /// <summary>Subtitle files in the video's folder, for "From the video's folder".</summary>
    private async Task<List<StorageItem>> FolderSubtitleCandidates()
    {
        var account = _account;
        if (account == null) return new();
        string? parent = _file?.ParentId;
        if (string.IsNullOrEmpty(parent))
        {
            if (Accounts.IsLocal(account)) parent = Path.GetDirectoryName(_fileId);
            else if (Accounts.IsSmb(account))
            {
                var slash = _fileId.LastIndexOf('/');
                parent = slash > "smb://".Length ? _fileId[..slash] : null;
            }
        }
        if (string.IsNullOrEmpty(parent)) return new();
        var items = await AppServices.Storage.List(account, parent);
        return items.Where(i => !i.IsFolder && FilenameParser.IsSubtitle(i.Name)).OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }
}
