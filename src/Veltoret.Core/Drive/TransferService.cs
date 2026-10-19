using System.Text.Json;
using System.Text.Json.Serialization;
using Veltoret.Core.Library;

namespace Veltoret.Core.Drive;

public enum TransferKind { Upload, Extract }

public enum TransferState { Enqueued, Waiting, Running, Succeeded, Failed }

/// <summary>One upload or ZIP extraction (Android: a WorkManager job). Snapshots are handed out; don't mutate them.</summary>
public sealed record TransferJob
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    [JsonConverter(typeof(JsonStringEnumConverter))] public TransferKind Kind { get; init; }
    public string Account { get; init; } = "";
    /// <summary>Upload: the Drive folder to upload into. Extract: the folder holding the ZIP.</summary>
    public string ParentId { get; init; } = "";
    /// <summary>Upload: the file on this PC.</summary>
    public string? LocalPath { get; init; }
    public string? ZipId { get; init; }
    /// <summary>File name (upload) or ZIP name (extract).</summary>
    public string Name { get; init; } = "";
    public long Size { get; init; }
    [JsonConverter(typeof(JsonStringEnumConverter))] public ZipAfterExtract After { get; init; }
    public bool WifiOnly { get; init; }
    [JsonConverter(typeof(JsonStringEnumConverter))] public TransferState State { get; init; }
    /// <summary>0..1; for extraction, compressed bytes consumed / ZIP size.</summary>
    public float Progress { get; init; }
    /// <summary>Extraction: the file being unpacked ("Preparing…" at first).</summary>
    public string? Current { get; init; }
    /// <summary>Extraction: files done so far; after success, files extracted or already there.</summary>
    public int Count { get; init; }
    public string? Error { get; init; }
    public string? ZipNote { get; init; }
    /// <summary>Extraction: the folder the files went into.</summary>
    public string? FolderId { get; init; }
    public int Attempt { get; init; }
    public long CreatedAt { get; init; }
    public long FinishedAt { get; init; }

    [JsonIgnore] public bool IsActive => State is TransferState.Enqueued or TransferState.Waiting or TransferState.Running;
    [JsonIgnore] public bool IsFinished => State is TransferState.Succeeded or TransferState.Failed;
}

/// <summary>What the Extract dialog shows before starting: free space and whether an earlier attempt's folder exists.</summary>
public sealed record ExtractCheck(long? Free, bool Resuming, long Size)
{
    public bool TooBig => Free != null && Free < Size && !Resuming;
}

/// <summary>
/// Background uploads and ZIP extractions (Android: UploadWorker / ExtractWorker on WorkManager). Jobs run on the
/// thread pool, at most two uploads and two extractions at a time, and are saved to a JSON file so they continue
/// after a restart (an interrupted job restarts: uploads from byte 0, extractions skipping files already in Drive).
///
/// Uploads: 3 attempts, extractions: 4 (backoff 30 s, 60 s, 120 s). A full Drive or an unreadable ZIP fails at
/// once. Failed jobs stay listed until dismissed.
/// </summary>
public sealed class TransferService
{
    private const int UploadAttempts = 3;
    private const int ExtractAttempts = 4;

    private readonly IDriveClient _drive;
    private readonly string _path;
    private readonly object _lock = new();
    private readonly List<TransferJob> _jobs = new();
    private readonly Dictionary<string, CancellationTokenSource> _running = new();
    private readonly SemaphoreSlim _uploadSlots = new(2, 2);
    private readonly SemaphoreSlim _extractSlots = new(2, 2);
    private bool _resumed;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    /// <summary>Whether there is an internet connection (jobs wait while offline).</summary>
    public Func<bool> IsOnline { get; set; } = () => true;
    /// <summary>"Only on Wi-Fi" extractions wait until this is true (Windows: an unmetered network).</summary>
    public Func<bool> IsUnmetered { get; set; } = () => true;
    /// <summary>After a successful extraction: an automatic library rescan.</summary>
    public Func<Task>? AfterExtraction { get; set; }
    /// <summary>After the ZIP was trashed/deleted: drop its archive row.</summary>
    public Func<string, Task>? ForgetArchive { get; set; }
    public TimeSpan[] Backoff { get; set; } = { TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(120) };
    public TimeSpan ConstraintPoll { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>Raised (on a background thread) whenever a job changes: progress, state, added or removed.</summary>
    public event Action<TransferJob>? JobChanged;
    /// <summary>Raised once when a job succeeds or finally fails.</summary>
    public event Action<TransferJob>? JobFinished;
    /// <summary>Raised when a job was dismissed or cancelled (its id).</summary>
    public event Action<string>? JobRemoved;

    public TransferService(IDriveClient drive, string jobsPath)
    {
        _drive = drive;
        _path = jobsPath;
        Load();
    }

    public IReadOnlyList<TransferJob> Jobs
    {
        get { lock (_lock) return _jobs.ToList(); }
    }

    public bool HasPending
    {
        get { lock (_lock) return _jobs.Any(j => j.IsActive); }
    }

    /// <summary>The latest job for a ZIP, an active one preferred (Archives screen).</summary>
    public TransferJob? LatestForZip(string zipId)
    {
        lock (_lock)
        {
            var mine = _jobs.Where(j => j.Kind == TransferKind.Extract && j.ZipId == zipId).OrderByDescending(j => j.CreatedAt).ToList();
            return mine.FirstOrDefault(j => j.IsActive) ?? mine.FirstOrDefault();
        }
    }

    /// <summary>Starts the jobs that were waiting or running when Veltoret last closed.</summary>
    public void Resume()
    {
        List<TransferJob> pending;
        lock (_lock)
        {
            if (_resumed) return;
            _resumed = true;
            pending = _jobs.Where(j => j.IsActive).ToList();
        }
        foreach (var j in pending) Start(j.Id);
    }

    // ---- enqueue -------------------------------------------------------------------------------------------

    public IReadOnlyList<TransferJob> Upload(string account, string parentId, IEnumerable<string> paths) =>
        paths.Select(p => Upload(account, parentId, p)).ToList();

    public TransferJob Upload(string account, string parentId, string path)
    {
        long size = -1;
        try { size = new FileInfo(path).Length; }
        catch (Exception) { }
        var job = new TransferJob
        {
            Kind = TransferKind.Upload,
            Account = account,
            ParentId = parentId,
            LocalPath = path,
            Name = Path.GetFileName(path) is { Length: > 0 } n ? n : "Upload",
            Size = size,
            State = TransferState.Enqueued,
            CreatedAt = Now(),
        };
        Add(job);
        Start(job.Id);
        return job;
    }

    /// <summary>One job per ZIP: extracting a ZIP that is already being extracted returns that job.</summary>
    public TransferJob Extract(string account, string zipId, string? zipName, long zipSize, string parentId, ZipAfterExtract after, bool wifiOnly)
    {
        TransferJob job;
        lock (_lock)
        {
            var active = _jobs.FirstOrDefault(j => j.Kind == TransferKind.Extract && j.ZipId == zipId && j.IsActive);
            if (active != null) return active;
            job = new TransferJob
            {
                Kind = TransferKind.Extract,
                Account = account,
                ZipId = zipId,
                Name = string.IsNullOrEmpty(zipName) ? "Archive.zip" : zipName,
                Size = zipSize,
                ParentId = parentId,
                After = after,
                WifiOnly = wifiOnly,
                State = TransferState.Enqueued,
                CreatedAt = Now(),
            };
            _jobs.Add(job);
            SaveLocked();
        }
        JobChanged?.Invoke(job);
        Start(job.Id);
        return job;
    }

    /// <summary>Free space in Drive and whether a folder named like the ZIP already sits next to it.</summary>
    public async Task<ExtractCheck> CheckExtract(string account, string zipName, long zipSize, string parentId, CancellationToken ct = default)
    {
        var freeTask = _drive.FreeBytes(account, ct);
        var childrenTask = _drive.ListChildren(account, parentId, "folder,name_natural", ct);
        long? free = null;
        try { free = await freeTask.ConfigureAwait(false); }
        catch (Exception) when (!ct.IsCancellationRequested) { }
        var baseName = FilenameParser.BaseName(zipName);
        var resuming = false;
        try { resuming = (await childrenTask.ConfigureAwait(false)).Any(f => f.IsFolder && f.Name == baseName); }
        catch (Exception) when (!ct.IsCancellationRequested) { }
        return new ExtractCheck(free, resuming, zipSize);
    }

    /// <summary>Runs a failed job again (extraction continues where it stopped).</summary>
    public void Retry(string id)
    {
        TransferJob? job;
        lock (_lock)
        {
            job = Find(id);
            if (job == null || job.IsActive) return;
            job = Replace(job with { State = TransferState.Enqueued, Attempt = 0, Error = null, Progress = 0, Current = null, Count = 0, ZipNote = null });
        }
        JobChanged?.Invoke(job);
        Start(id);
    }

    /// <summary>Removes a finished or failed job from the list.</summary>
    public void Dismiss(string id)
    {
        lock (_lock)
        {
            var job = Find(id);
            if (job == null || job.IsActive) return;
            _jobs.Remove(job);
            SaveLocked();
        }
        JobRemoved?.Invoke(id);
    }

    /// <summary>Stops a job and removes it. A half-done upload session simply expires on Drive's side.</summary>
    public void Cancel(string id)
    {
        lock (_lock)
        {
            if (_running.TryGetValue(id, out var cts)) cts.Cancel();
            var job = Find(id);
            if (job != null) _jobs.Remove(job);
            SaveLocked();
        }
        JobRemoved?.Invoke(id);
    }

    // ---- running -------------------------------------------------------------------------------------------

    private void Start(string id)
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_running.ContainsKey(id) || Find(id) == null) return;
            cts = new CancellationTokenSource();
            _running[id] = cts;
        }
        _ = Task.Run(async () =>
        {
            try { await Run(id, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            finally
            {
                lock (_lock) _running.Remove(id);
                cts.Dispose();
            }
        });
    }

    private async Task Run(string id, CancellationToken ct)
    {
        while (true)
        {
            var job = Get(id);
            if (job == null) return;
            var slots = job.Kind == TransferKind.Upload ? _uploadSlots : _extractSlots;
            var maxAttempts = job.Kind == TransferKind.Upload ? UploadAttempts : ExtractAttempts;

            // Constraints: a connection; "Only on Wi-Fi" extractions an unmetered one.
            while (!(IsOnline() && (!job.WifiOnly || IsUnmetered())))
            {
                if (job.State != TransferState.Waiting) job = Update(id, j => j with { State = TransferState.Waiting }, save: true) ?? job;
                await Task.Delay(ConstraintPoll, ct).ConfigureAwait(false);
            }

            await slots.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                job = Update(id, j => j with { State = TransferState.Running, Attempt = j.Attempt + 1, Error = null }, save: true);
                if (job == null) return;
                if (job.Kind == TransferKind.Upload) await RunUpload(job, ct).ConfigureAwait(false);
                else await RunExtract(job, ct).ConfigureAwait(false);
                return;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception e) when (IsFinal(e) || (Get(id)?.Attempt ?? maxAttempts) >= maxAttempts)
            {
                var failed = Update(id, j => j with
                {
                    State = TransferState.Failed,
                    Error = FailureMessage(j, e),
                    FinishedAt = Now(),
                }, save: true);
                if (failed != null) JobFinished?.Invoke(failed);
                return;
            }
            catch (Exception)
            {
                // Retry from the start (a new upload session; extraction skips files already in Drive).
                job = Update(id, j => j with { State = TransferState.Enqueued }, save: true);
                if (job == null) return;
            }
            finally
            {
                slots.Release();
            }
            var attempt = Math.Clamp(job.Attempt - 1, 0, Backoff.Length - 1);
            await Task.Delay(Backoff.Length == 0 ? TimeSpan.Zero : Backoff[attempt], ct).ConfigureAwait(false);
        }
    }

    /// <summary>Errors a retry can't fix: a full Drive, an unreadable ZIP, a missing local file, a sign-in to redo.</summary>
    private static bool IsFinal(Exception e) =>
        e is ExtractFailedException or DriveStorageFullException or FileNotFoundException or DirectoryNotFoundException
            or Auth.AuthRequiredException or Auth.GoogleSetupException or UnauthorizedAccessException
        || e is not IOException && e is not HttpRequestException;

    private static string FailureMessage(TransferJob job, Exception e)
    {
        if (e is FileNotFoundException or DirectoryNotFoundException) return "The file is no longer on this PC";
        var message = string.IsNullOrWhiteSpace(e.Message) ? null : e.Message;
        if (e is IOException or HttpRequestException) return message ?? "Network problem";
        return message ?? (job.Kind == TransferKind.Extract ? "Extraction failed" : "Upload failed");
    }

    private async Task RunUpload(TransferJob job, CancellationToken ct)
    {
        var path = job.LocalPath ?? throw new FileNotFoundException();
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("The file is no longer on this PC", path);
        var size = info.Length;
        Update(job.Id, j => j with { Progress = 0, Size = size });
        var lastPercent = -1;
        await _drive.Upload(job.Account, job.ParentId, job.Name, DriveFormat.MimeFor(job.Name), size,
            () => new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan),
            (sent, total) =>
            {
                var percent = total > 0 ? (int)(sent * 100 / total) : 0;
                if (percent == lastPercent) return;
                lastPercent = percent;
                Update(job.Id, j => j with { Progress = percent / 100f });
            }, ct).ConfigureAwait(false);
        var done = Update(job.Id, j => j with { State = TransferState.Succeeded, Progress = 1, FinishedAt = Now() }, save: true);
        if (done != null) JobFinished?.Invoke(done);
    }

    private async Task RunExtract(TransferJob job, CancellationToken ct)
    {
        var extractor = new ZipExtractor(_drive, ForgetArchive);
        var result = await extractor.Run(job.Account, job.ZipId!, job.Name, job.ParentId, job.After,
            p => Update(job.Id, j => j with { Progress = p.Fraction, Current = p.Current, Count = p.Done }), ct).ConfigureAwait(false);
        var done = Update(job.Id, j => j with
        {
            State = TransferState.Succeeded,
            Progress = 1,
            Count = result.Count,
            FolderId = result.FolderId,
            ZipNote = result.ZipNote,
            Current = null,
            FinishedAt = Now(),
        }, save: true);
        if (AfterExtraction != null)
        {
            try { await AfterExtraction().ConfigureAwait(false); }
            catch (Exception) { }
        }
        if (done != null) JobFinished?.Invoke(done);
    }

    // ---- state ---------------------------------------------------------------------------------------------

    private TransferJob? Find(string id) => _jobs.FirstOrDefault(j => j.Id == id);

    private TransferJob? Get(string id)
    {
        lock (_lock) return Find(id);
    }

    private TransferJob Replace(TransferJob job)
    {
        var i = _jobs.FindIndex(j => j.Id == job.Id);
        if (i >= 0) _jobs[i] = job;
        SaveLocked();
        return job;
    }

    private void Add(TransferJob job)
    {
        lock (_lock)
        {
            _jobs.Add(job);
            SaveLocked();
        }
        JobChanged?.Invoke(job);
    }

    private TransferJob? Update(string id, Func<TransferJob, TransferJob> edit, bool save = false)
    {
        TransferJob next;
        lock (_lock)
        {
            var i = _jobs.FindIndex(j => j.Id == id);
            if (i < 0) return null;
            next = edit(_jobs[i]);
            _jobs[i] = next;
            if (save) SaveLocked();
        }
        JobChanged?.Invoke(next);
        return next;
    }

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var jobs = JsonSerializer.Deserialize<List<TransferJob>>(File.ReadAllText(_path), Json) ?? new();
            var dayAgo = Now() - TimeSpan.FromDays(1).Ticks / TimeSpan.TicksPerMillisecond;
            foreach (var j in jobs)
            {
                // Finished uploads and day-old successes needn't come back; failures stay until dismissed.
                if (j.State == TransferState.Succeeded && (j.Kind == TransferKind.Upload || j.FinishedAt < dayAgo)) continue;
                // A job that was running when Veltoret closed starts over.
                _jobs.Add(j.IsActive ? j with { State = TransferState.Enqueued, Attempt = 0, Progress = 0 } : j);
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }

    private void SaveLocked()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_jobs, Json));
            File.Move(tmp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
