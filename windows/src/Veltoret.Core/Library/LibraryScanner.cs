using Veltoret.Core.Data;
using Veltoret.Core.Net;
using Veltoret.Core.Settings;
using Veltoret.Core.Storage;
using Veltoret.Core.Tmdb;
using StorageFacade = Veltoret.Core.Storage.Storage;

namespace Veltoret.Core.Library;

/// <summary>
/// Walks the library folders (Drive, this PC, network shares), mirrors their videos and subtitles into the database,
/// and matches new files against TMDB. Files already matched are never looked up again, so rescans are cheap.
/// Port of Android LibraryScanner.
/// </summary>
public sealed class LibraryScanner
{
    /// <summary>TMDB lookups per unmatched title at most (each is one or two searches).</summary>
    private const int MaxCandidates = 6;

    private readonly AccountDao _accounts;
    private readonly MediaFileDao _files;
    private readonly CatalogDao _catalog;
    private readonly StorageFacade _storage;
    private readonly TmdbRepository _tmdb;
    private readonly SettingsStore _settings;
    private readonly Connectivity _connectivity;

    private readonly SemaphoreSlim _mutex = new(1, 1);
    private readonly object _stateLock = new();
    private ScanState _state = new();
    private volatile bool _cancelRequested;

    public LibraryScanner(AccountDao accounts, MediaFileDao files, CatalogDao catalog, StorageFacade storage,
        TmdbRepository tmdb, SettingsStore settings, Connectivity connectivity)
    {
        _accounts = accounts;
        _files = files;
        _catalog = catalog;
        _storage = storage;
        _tmdb = tmdb;
        _settings = settings;
        _connectivity = connectivity;
    }

    public ScanState State
    {
        get { lock (_stateLock) return _state; }
    }

    /// <summary>Raised after every state change, on the scanning thread. UI code must marshal to its dispatcher.</summary>
    public event Action<ScanState>? StateChanged;

    /// <summary>True while a scan holds the scanner.</summary>
    public bool IsBusy => _mutex.CurrentCount == 0;

    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private void Update(Func<ScanState, ScanState> edit)
    {
        ScanState next;
        lock (_stateLock)
        {
            next = edit(_state);
            _state = next;
        }
        try { StateChanged?.Invoke(next); }
        catch { /* a listener's failure must not stop the scan */ }
    }

    private void SetState(ScanState state) => Update(_ => state);

    /// <summary>Thrown at the next checkpoint after <see cref="Cancel"/>; folders already read keep their results.</summary>
    private sealed class ScanCancelled : Exception;

    public Task ScanAll() => Scan(null);

    /// <summary>Stops the running scan at the next folder or TMDB lookup.</summary>
    public void Cancel()
    {
        if (State.Running) _cancelRequested = true;
    }

    private void CheckCancelled()
    {
        if (_cancelRequested) throw new ScanCancelled();
    }

    /// <summary>Scans <paramref name="folderIds"/>, or every library folder when null. Returns at once if a scan is running.</summary>
    public async Task Scan(IReadOnlySet<long>? folderIds)
    {
        if (!await _mutex.WaitAsync(0).ConfigureAwait(false)) return; // a scan is already running; its result will cover this request
        _cancelRequested = false;
        try
        {
            await Task.Yield();
            var errors = new List<string>();
            var all = await _accounts.Folders().ConfigureAwait(false);
            var folderErrors = State.FolderErrors.Where(kv => all.Any(f => f.Id == kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
            // Offline: folders on this PC still refresh; Drive and network folders and TMDB wait for the connection to
            // return (ScanScheduler rescans when it does). Skipping them also keeps their titles in the library.
            var online = _connectivity.IsOnline;
            var targets = all.Where(f => (folderIds == null || folderIds.Contains(f.Id)) && (online || _storage.IsLocal(f.AccountEmail))).ToList();
            var previous = State;
            SetState(new ScanState
            {
                Running = true,
                Phase = "Reading your folders",
                FolderIds = folderIds,
                FoldersTotal = targets.Count,
                FolderErrors = new Dictionary<long, string>(folderErrors),
                LastFinishedAt = previous.LastFinishedAt,
            });
            foreach (var folder in targets)
            {
                CheckCancelled();
                Update(s => s with { CurrentFolderId = folder.Id, CurrentFolder = folder.Name, CurrentPath = "" });
                try
                {
                    await ScanFolder(folder).ConfigureAwait(false);
                    folderErrors.Remove(folder.Id);
                }
                catch (ScanCancelled)
                {
                    throw;
                }
                catch (Exception e)
                {
                    var reason = FolderError(e);
                    folderErrors[folder.Id] = reason;
                    errors.Add($"{folder.Name}: {reason}");
                }
                var snapshot = new Dictionary<long, string>(folderErrors);
                Update(s => s with
                {
                    FoldersDone = s.FoldersDone + 1,
                    DoneFolderIds = new HashSet<long>(s.DoneFolderIds) { folder.Id },
                    FolderErrors = snapshot,
                });
            }
            Update(s => s with { CurrentFolderId = null, CurrentFolder = "", CurrentPath = "" });
            if (online)
            {
                try
                {
                    await MatchPending().ConfigureAwait(false);
                    // Refreshing every show is a whole-library job; a single-folder scan skips it.
                    if (folderIds == null)
                    {
                        await RefreshShows().ConfigureAwait(false);
                        await RefreshRecommendations().ConfigureAwait(false);
                    }
                }
                catch (ScanCancelled)
                {
                    throw;
                }
                catch (Exception e)
                {
                    errors.Add(string.IsNullOrEmpty(e.Message) ? "Could not reach TMDB" : e.Message);
                }
            }
            await _catalog.Prune().ConfigureAwait(false);
            var now = Now;
            if (folderIds == null) _settings.Update(s => s with { LastScanAt = now });
            Update(s => s with { Running = false, Phase = "", Error = errors.FirstOrDefault(), LastFinishedAt = now });
        }
        catch (ScanCancelled)
        {
            try { await _catalog.Prune().ConfigureAwait(false); }
            catch { /* best effort */ }
            Update(s => s with
            {
                Running = false, Phase = "", Cancelled = true, CurrentFolderId = null, CurrentFolder = "",
                CurrentPath = "", LastFinishedAt = Now,
            });
        }
        catch (Exception e)
        {
            // Database trouble and the like: end the scan visibly, then let the caller (ScanScheduler) retry.
            Update(s => s with
            {
                Running = false, Phase = "", Error = e.Message, CurrentFolderId = null, CurrentFolder = "",
                CurrentPath = "", LastFinishedAt = Now,
            });
            throw;
        }
        finally
        {
            _cancelRequested = false;
            _mutex.Release();
        }
    }

    private static string FolderError(Exception e) => e switch
    {
        // A folder whose permission is gone (another user's folder, a locked-down drive...).
        UnauthorizedAccessException => "Veltoret lost access to this folder. Remove it and add it again.",
        _ => string.IsNullOrEmpty(e.Message) ? e.GetType().Name : e.Message,
    };

    private async Task ScanFolder(LibraryFolderEntity folder)
    {
        var existing = (await _files.FilesInFolder(folder.Id).ConfigureAwait(false)).ToDictionary(f => f.DriveId);
        var seen = new List<MediaFileEntity>();
        var seenIds = new HashSet<string>();
        var subtitles = new List<SubtitleFileEntity>();
        var archives = new List<ArchiveFileEntity>();
        var queue = new Queue<(string FolderId, List<string> Path)>();
        var visited = new HashSet<string>();
        queue.Enqueue((folder.DriveFolderId, new List<string>()));

        while (queue.Count > 0)
        {
            var (folderId, path) = queue.Dequeue();
            if (!visited.Add(folderId)) continue;
            CheckCancelled();
            var joined = string.Join("/", path);
            Update(s => s with { CurrentPath = joined });
            foreach (var child in await _storage.List(folder.AccountEmail, folderId).ConfigureAwait(false))
            {
                if (child.IsFolder)
                {
                    queue.Enqueue((child.Id, new List<string>(path) { child.Name }));
                }
                else if (FilenameParser.IsSubtitle(child.Name))
                {
                    subtitles.Add(new SubtitleFileEntity
                    {
                        DriveId = child.Id, AccountEmail = folder.AccountEmail, LibraryFolderId = folder.Id, ParentId = folderId, Name = child.Name,
                    });
                }
                // ZIP extraction uploads to Drive, so archives are only listed for Drive folders.
                else if (FilenameParser.IsArchive(child.Name) && !_storage.IsLocal(folder.AccountEmail) && !_storage.IsSmb(folder.AccountEmail))
                {
                    archives.Add(new ArchiveFileEntity
                    {
                        DriveId = child.Id, AccountEmail = folder.AccountEmail, LibraryFolderId = folder.Id, ParentId = folderId,
                        Name = child.Name, SizeBytes = child.SizeBytes, RelativePath = joined,
                    });
                }
                else if (FilenameParser.IsVideo(child.Name, child.MimeType) && !IsSample(child))
                {
                    existing.TryGetValue(child.Id, out var previous);
                    if (!seenIds.Add(child.Id)) continue;
                    seen.Add(ToEntity(child, folder, folderId, path, previous));
                    var isNew = previous == null;
                    Update(s => s with { FilesFound = s.FilesFound + 1, NewFiles = s.NewFiles + (isNew ? 1 : 0) });
                }
            }
        }

        await _files.Upsert(seen).ConfigureAwait(false);
        var gone = existing.Keys.Where(k => !seenIds.Contains(k)).ToList();
        if (gone.Count > 0) await _files.Delete(gone).ConfigureAwait(false);
        await _files.ReplaceSubtitles(folder.Id, subtitles).ConfigureAwait(false);
        await _files.ReplaceArchives(folder.Id, archives).ConfigureAwait(false);
        await _accounts.MarkFolderScanned(folder.Id, Now).ConfigureAwait(false);
    }

    private static bool IsSample(StorageItem file) =>
        file.Name.Contains("sample", StringComparison.OrdinalIgnoreCase) && file.SizeBytes >= 1 && file.SizeBytes < 150L * 1024 * 1024;

    private static MediaFileEntity ToEntity(StorageItem file, LibraryFolderEntity folder, string parentId, List<string> path, MediaFileEntity? previous)
    {
        var relativePath = string.Join("/", path);
        var duration = file.DurationMs ?? previous?.DurationMs ?? 0L;
        // Unmatched files fall through and are parsed again (back to PENDING) when the parser now reads
        // their name differently, e.g. after a parser fix; otherwise they'd stay unmatched forever.
        if (previous != null && previous.Name == file.Name && previous.RelativePath == relativePath &&
            !(previous.MatchState == MatchState.UNMATCHED && ParsesDifferently(file.Name, path, folder.Type, previous)))
        {
            return previous with
            {
                ParentId = parentId,
                SizeBytes = file.SizeBytes,
                ModifiedTime = file.ModifiedTime,
                DurationMs = duration,
                Width = file.Width ?? previous.Width,
                Height = file.Height ?? previous.Height,
            };
        }

        var manual = previous?.MatchState == MatchState.MANUAL;
        var ignored = previous?.MatchState == MatchState.IGNORED;
        var baseEntity = new MediaFileEntity
        {
            DriveId = file.Id,
            AccountEmail = folder.AccountEmail,
            LibraryFolderId = folder.Id,
            Name = file.Name,
            ParentId = parentId,
            RelativePath = relativePath,
            SizeBytes = file.SizeBytes,
            ModifiedTime = file.ModifiedTime,
            MimeType = file.MimeType,
            DurationMs = duration,
            Width = file.Width ?? 0,
            Height = file.Height ?? 0,
            Kind = folder.Type == LibraryType.MOVIES ? MediaKind.MOVIE : MediaKind.EPISODE,
            ParsedTitle = "",
            ParsedYear = null,
            Season = null,
            Episode = null,
            EpisodeEnd = null,
            MovieId = manual ? previous!.MovieId : null,
            ShowId = manual ? previous!.ShowId : null,
            MatchState = manual ? MatchState.MANUAL : ignored ? MatchState.IGNORED : MatchState.PENDING,
            AddedAt = previous?.AddedAt ?? Now,
        };
        if (folder.Type == LibraryType.MOVIES)
        {
            var guess = FilenameParser.ParseMovie(file.Name, path);
            return baseEntity with { ParsedTitle = guess.Title, ParsedYear = guess.Year };
        }
        var ep = FilenameParser.ParseEpisode(file.Name, path);
        if (ep == null)
        {
            return baseEntity with
            {
                ParsedTitle = FilenameParser.Clean(file.Name),
                MatchState = manual ? MatchState.MANUAL : ignored ? MatchState.IGNORED : MatchState.UNMATCHED,
            };
        }
        return baseEntity with
        {
            ParsedTitle = ep.ShowTitle,
            ParsedYear = ep.ShowYear,
            Season = ep.Season,
            Episode = ep.Episode,
            EpisodeEnd = ep.EpisodeEnd,
        };
    }

    private static bool ParsesDifferently(string name, List<string> path, LibraryType type, MediaFileEntity previous)
    {
        if (type == LibraryType.MOVIES)
        {
            var guess = FilenameParser.ParseMovie(name, path);
            return guess.Title != previous.ParsedTitle || guess.Year != previous.ParsedYear;
        }
        var ep = FilenameParser.ParseEpisode(name, path);
        return ep != null && (ep.ShowTitle != previous.ParsedTitle || ep.ShowYear != previous.ParsedYear ||
                              ep.Season != previous.Season || ep.Episode != previous.Episode);
    }

    private static List<string> PathOf(MediaFileEntity f) => f.RelativePath.Split('/').Where(s => s.Length > 0).ToList();

    private async Task MatchPending()
    {
        var pending = await _files.Pending().ConfigureAwait(false);
        if (pending.Count == 0) return;
        Update(s => s with { Phase = "Matching with TMDB", ToMatch = pending.Count, Matched = 0 });

        var groups = pending.GroupBy(f => (f.Kind, FilenameParser.NormalizeForCompare(f.ParsedTitle), f.ParsedYear));
        foreach (var group in groups)
        {
            CheckCancelled();
            var list = group.ToList();
            var sample = list[0];
            List<MediaFileEntity>? updated;
            try
            {
                var path = PathOf(sample);
                // The parser's guess first, then its fallbacks (the file's own title, trimmed leftovers...).
                var candidates = new List<FilenameParser.TitleCandidate> { new(sample.ParsedTitle, sample.ParsedYear) };
                candidates.AddRange(group.Key.Kind == MediaKind.MOVIE
                    ? FilenameParser.MovieCandidates(sample.Name, path)
                    : FilenameParser.ShowCandidates(sample.Name, path));
                var keys = new HashSet<(string, int?)>();
                var lookups = candidates.Where(c => keys.Add((FilenameParser.NormalizeForCompare(c.Title), c.Year))).Take(MaxCandidates).ToList();
                updated = null;
                if (group.Key.Kind == MediaKind.MOVIE)
                {
                    TmdbMovieSummary? match = null;
                    foreach (var c in lookups)
                    {
                        match = await _tmdb.FindMovie(c.Title, c.Year, c.ExactOnly).ConfigureAwait(false);
                        if (match != null) break;
                    }
                    if (match != null)
                    {
                        await _tmdb.EnsureMovie(match.Id).ConfigureAwait(false);
                        updated = list.Select(f => f with { MovieId = match.Id, ShowId = null, MatchState = MatchState.MATCHED }).ToList();
                    }
                }
                else
                {
                    TmdbTvSummary? match = null;
                    foreach (var c in lookups)
                    {
                        match = await _tmdb.FindShow(c.Title, c.Year, c.ExactOnly).ConfigureAwait(false);
                        if (match != null) break;
                    }
                    if (match != null)
                    {
                        await _tmdb.EnsureShow(match.Id, list.Where(f => f.Season != null).Select(f => f.Season!.Value).ToHashSet()).ConfigureAwait(false);
                        updated = list.Select(f => f with { ShowId = match.Id, MovieId = null, MatchState = MatchState.MATCHED }).ToList();
                    }
                }
            }
            catch (TmdbKeyMissingException)
            {
                throw;
            }
            catch (Exception)
            {
                // Network hiccup: leave as PENDING so the next scan retries.
                Update(s => s with { Matched = s.Matched + list.Count });
                continue;
            }
            await _files.Upsert(updated ?? list.Select(f => f with { MatchState = MatchState.UNMATCHED }).ToList()).ConfigureAwait(false);
            var identified = updated?.Count ?? 0;
            Update(s => s with { Matched = s.Matched + list.Count, Identified = s.Identified + identified });
        }
    }

    /// <summary>Keeps ongoing shows fresh and fetches episode lists for newly added seasons.</summary>
    private async Task RefreshShows()
    {
        var seasons = await _files.ShowSeasons().ConfigureAwait(false);
        foreach (var show in seasons.GroupBy(s => s.ShowId))
        {
            try
            {
                await _tmdb.EnsureShow(show.Key, show.Select(s => s.Season).ToHashSet()).ConfigureAwait(false);
            }
            catch (TmdbKeyMissingException)
            {
                throw;
            }
            catch (Exception)
            {
                // runCatching in Android: one show's failure doesn't stop the others.
            }
        }
    }

    /// <summary>Fetches "More like this" for titles that have none yet or a month-old list. Detail pages also fetch on open.</summary>
    private async Task RefreshRecommendations()
    {
        var ids = (await _catalog.Movies().ConfigureAwait(false)).Select(m => ("movie", m.Movie.TmdbId))
            .Concat((await _catalog.Shows().ConfigureAwait(false)).Select(s => ("tv", s.Show.TmdbId)))
            .ToList();
        foreach (var (type, id) in ids)
        {
            CheckCancelled();
            try
            {
                await _tmdb.EnsureRecommendations(type, id).ConfigureAwait(false);
            }
            catch (TmdbKeyMissingException)
            {
                throw;
            }
            catch (Exception)
            {
            }
        }
    }

    /// <summary>"Fix match": pins files to a TMDB title chosen by the user.</summary>
    public async Task ApplyManualMatch(IReadOnlyList<string> fileIds, MediaKind kind, int tmdbId)
    {
        var targets = await _files.Files(fileIds).ConfigureAwait(false);
        if (kind == MediaKind.MOVIE)
        {
            await _tmdb.EnsureMovie(tmdbId).ConfigureAwait(false);
            await _files.Upsert(targets.Select(f => f with
            {
                Kind = MediaKind.MOVIE, MovieId = tmdbId, ShowId = null, Season = null, Episode = null,
                EpisodeEnd = null, MatchState = MatchState.MANUAL,
            }).ToList()).ConfigureAwait(false);
        }
        else
        {
            var updated = targets.Select(file =>
            {
                var guess = FilenameParser.ParseEpisode(file.Name, PathOf(file));
                return file with
                {
                    Kind = MediaKind.EPISODE,
                    ShowId = tmdbId,
                    MovieId = null,
                    Season = file.Season ?? guess?.Season ?? 1,
                    Episode = file.Episode ?? guess?.Episode ?? 1,
                    MatchState = MatchState.MANUAL,
                };
            }).ToList();
            await _tmdb.EnsureShow(tmdbId, updated.Where(f => f.Season != null).Select(f => f.Season!.Value).ToHashSet()).ConfigureAwait(false);
            await _files.Upsert(updated).ConfigureAwait(false);
        }
        await _catalog.Prune().ConfigureAwait(false);
    }

    /// <summary>Keeps files out of the library until restored; survives rescans.</summary>
    public async Task Ignore(IReadOnlyList<string> ids)
    {
        await _files.SetMatchState(ids, MatchState.IGNORED).ConfigureAwait(false);
        await _catalog.Prune().ConfigureAwait(false);
    }

    /// <summary>Puts ignored files back up for automatic matching on the next scan.</summary>
    public Task Restore(IReadOnlyList<string> ids) => _files.SetMatchState(ids, MatchState.PENDING);

    /// <summary>
    /// A file was renamed in Files. Same id (Drive): the name is updated and the next scan re-parses it. New id
    /// (this PC, network shares: the path changed): the row moves to the new id, keeping its match.
    /// </summary>
    public async Task OnFileRenamed(string oldId, string newId, string newName)
    {
        if (oldId == newId)
        {
            await _files.Rename(oldId, newName).ConfigureAwait(false);
            return;
        }
        var file = await _files.File(oldId).ConfigureAwait(false);
        await _files.Delete(new[] { oldId }).ConfigureAwait(false);
        if (file != null) await _files.Upsert(new[] { file with { DriveId = newId, Name = newName } }).ConfigureAwait(false);
        await _catalog.Prune().ConfigureAwait(false);
    }

    public async Task OnFilesRemoved(IReadOnlyList<string> ids)
    {
        await _files.Delete(ids).ConfigureAwait(false);
        await _catalog.Prune().ConfigureAwait(false);
    }
}
