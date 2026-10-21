using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace Veltoret.Core.Images;

/// <summary>
/// Disk cache for TMDB artwork (and account photos), keyed by URL, so the library looks right offline. A file's
/// name is the SHA-1 of its URL. Downloads of the same URL are shared; the cache is trimmed to
/// <see cref="MaxBytes"/> by least-recent use (last access time, refreshed on every hit).
/// </summary>
public sealed class ImageCache
{
    public const long MaxBytes = 512L * 1024 * 1024;
    /// <summary>Trim down to this, so a full cache doesn't trim on every download.</summary>
    private const long TrimTarget = MaxBytes * 9 / 10;

    private readonly string _dir;
    private readonly HttpClient _http;
    private readonly ConcurrentDictionary<string, Task<string?>> _inflight = new();
    private readonly SemaphoreSlim _downloads = new(6);
    private readonly object _sizeLock = new();
    private long _size = -1;
    private int _trimming;

    public ImageCache(string directory, HttpClient? http = null)
    {
        _dir = directory;
        Directory.CreateDirectory(_dir);
        _http = http ?? new HttpClient(new SocketsHttpHandler { ConnectTimeout = TimeSpan.FromSeconds(20) })
        {
            Timeout = TimeSpan.FromSeconds(45),
        };
    }

    /// <summary>Where <paramref name="url"/> is (or would be) cached.</summary>
    public string PathFor(string url)
    {
        var hash = SHA1.HashData(Encoding.UTF8.GetBytes(url));
        return Path.Combine(_dir, Convert.ToHexString(hash).ToLowerInvariant());
    }

    public bool IsCached(string url) => File.Exists(PathFor(url));

    /// <summary>
    /// The local file for <paramref name="url"/>: from disk when cached (works offline), else downloaded once.
    /// Null for a null/empty URL or when it can't be fetched.
    /// </summary>
    public async Task<string?> GetFile(string? url, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        var path = PathFor(url);
        if (File.Exists(path))
        {
            Touch(path);
            return path;
        }
        var task = _inflight.GetOrAdd(url, u => Download(u, path));
        try
        {
            return await task.WaitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Downloads every URL not cached yet, four at a time; failures are skipped.</summary>
    public async Task Prefetch(IEnumerable<string> urls)
    {
        using var gate = new SemaphoreSlim(4);
        var tasks = new List<Task>();
        foreach (var url in urls.Where(u => !string.IsNullOrWhiteSpace(u)).Distinct())
        {
            if (IsCached(url)) continue;
            await gate.WaitAsync().ConfigureAwait(false);
            tasks.Add(Task.Run(async () =>
            {
                try { await GetFile(url).ConfigureAwait(false); }
                finally { gate.Release(); }
            }));
        }
        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    private async Task<string?> Download(string url, string path)
    {
        await Task.Yield(); // never complete before GetOrAdd has stored the task
        await _downloads.WaitAsync().ConfigureAwait(false);
        var tmp = path + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp";
        try
        {
            if (File.Exists(path)) return path;
            using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            long written;
            await using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            await using (var output = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous))
            {
                await input.CopyToAsync(output).ConfigureAwait(false);
                written = output.Length;
            }
            if (written == 0)
            {
                File.Delete(tmp);
                return null;
            }
            File.Move(tmp, path, overwrite: true);
            AddSize(written);
            return path;
        }
        catch
        {
            TryDelete(tmp);
            return null;
        }
        finally
        {
            _downloads.Release();
            _inflight.TryRemove(url, out _);
        }
    }

    private static void Touch(string path)
    {
        try { File.SetLastAccessTimeUtc(path, DateTime.UtcNow); }
        catch { /* in use or read-only: not important */ }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private void AddSize(long bytes)
    {
        bool trim;
        lock (_sizeLock)
        {
            if (_size < 0) _size = MeasureSize();
            else _size += bytes;
            trim = _size > MaxBytes;
        }
        if (trim && Interlocked.Exchange(ref _trimming, 1) == 0)
        {
            _ = Task.Run(() =>
            {
                try { Trim(); }
                finally { Interlocked.Exchange(ref _trimming, 0); }
            });
        }
    }

    private long MeasureSize()
    {
        try { return new DirectoryInfo(_dir).EnumerateFiles().Sum(f => f.Length); }
        catch { return 0; }
    }

    /// <summary>Deletes least recently used files until the cache is under 90% of <see cref="MaxBytes"/>.</summary>
    public void Trim()
    {
        List<FileInfo> files;
        try
        {
            files = new DirectoryInfo(_dir).EnumerateFiles()
                .Where(f => !f.Name.EndsWith(".tmp", StringComparison.Ordinal))
                .OrderBy(f => f.LastAccessTimeUtc > f.LastWriteTimeUtc ? f.LastAccessTimeUtc : f.LastWriteTimeUtc)
                .ToList();
        }
        catch
        {
            return;
        }
        var total = files.Sum(f => f.Length);
        foreach (var f in files)
        {
            if (total <= TrimTarget) break;
            try
            {
                var len = f.Length;
                f.Delete();
                total -= len;
            }
            catch { }
        }
        lock (_sizeLock) _size = total;
    }
}
