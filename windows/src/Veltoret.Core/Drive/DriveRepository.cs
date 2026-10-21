using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Veltoret.Core.Auth;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Drive;

/// <summary>
/// Google Drive v3 REST, call for call the Android app's DriveApi/DriveRepository: listing with paging, search,
/// rename/move/trash, delete, create folder, about/space, downloads (whole or by byte range) and resumable uploads.
///
/// Every request is tagged with its account; <see cref="DriveAuthHandler"/> adds the token and retries a 401 once.
/// The HttpClient must not follow redirects (Drive's 308 "Resume Incomplete" is not a redirect) and should have an
/// infinite timeout: calls enforce their own (metadata 60 s, each upload chunk 5 min, downloads 60 s per read).
/// </summary>
public sealed class DriveRepository : IDriveClient
{
    public const string Base = "https://www.googleapis.com/";
    public const string FileFields =
        "id,name,mimeType,size,modifiedTime,parents,fileExtension,videoMediaMetadata(width,height,durationMillis)," +
        "capabilities(canRename,canTrash,canDelete,canAddChildren)";
    public const string ListFields = "nextPageToken,files(" + FileFields + ")";
    public const string AboutFields = "user(displayName,emailAddress,photoLink),storageQuota(limit,usage)";
    public const int ChunkSize = 8 * 1024 * 1024;

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan ChunkTimeout = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(60);

    private static readonly JsonSerializerOptions Json = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _http;

    public DriveRepository(HttpClient http) => _http = http;

    /// <summary>The usual production client: auth handler over a handler that doesn't follow redirects.</summary>
    public static HttpClient CreateHttpClient(ITokenProvider tokens)
    {
        var sockets = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(20),
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
        };
        return new HttpClient(new DriveAuthHandler(tokens, sockets)) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>Escaping inside a q string literal: \ → \\, then ' → \'.</summary>
    public static string Escape(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'");

    private static HttpRequestMessage Request(HttpMethod method, string email, string url, object? body = null)
    {
        var r = new HttpRequestMessage(method, url.StartsWith("http", StringComparison.Ordinal) ? url : Base + url);
        r.Options.Set(DriveAuthHandler.AccountKey, email);
        if (body != null)
            r.Content = new StringContent(JsonSerializer.Serialize(body, Json), Encoding.UTF8, "application/json");
        return r;
    }

    private async Task<T> Call<T>(HttpRequestMessage request, CancellationToken ct, string what)
    {
        using (request)
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(CallTimeout);
            try
            {
                using var response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false);
                var text = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode) throw new IOException(ErrorMessage(what, response.StatusCode, text));
                if (typeof(T) == typeof(bool)) return (T)(object)true;
                return JsonSerializer.Deserialize<T>(text, Json) ?? throw new IOException(what + ": empty answer from Drive");
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new IOException("Google Drive didn't respond in time.");
            }
            catch (HttpRequestException e)
            {
                throw new IOException(e.Message, e);
            }
        }
    }

    /// <summary>Drive's own message when it sends one ("File not found: …"), else "{what} (HTTP {code})".</summary>
    private static string ErrorMessage(string what, HttpStatusCode status, string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object &&
                e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(m.GetString()))
                return m.GetString()!;
        }
        catch (JsonException) { }
        return $"{what} (HTTP {(int)status})";
    }

    // ---- files.list ----------------------------------------------------------------------------------------

    private async Task<List<DriveFile>> ListAll(string email, string q, string? orderBy, int pageSize, bool allPages, CancellationToken ct)
    {
        var all = new List<DriveFile>();
        string? pageToken = null;
        do
        {
            var url = "drive/v3/files?q=" + Uri.EscapeDataString(q) +
                      (pageToken != null ? "&pageToken=" + Uri.EscapeDataString(pageToken) : "") +
                      (orderBy != null ? "&orderBy=" + Uri.EscapeDataString(orderBy) : "") +
                      "&fields=" + Uri.EscapeDataString(ListFields) +
                      $"&pageSize={pageSize}&supportsAllDrives=true&includeItemsFromAllDrives=true";
            var page = await Call<DriveFileList>(Request(HttpMethod.Get, email, url), ct, "Couldn't list the folder").ConfigureAwait(false);
            all.AddRange(page.Files);
            pageToken = page.NextPageToken;
        } while (allPages && pageToken != null);
        return all;
    }

    /// <summary>Every child of a folder (all pages). Library scans pass orderBy "folder".</summary>
    public Task<List<DriveFile>> ListChildren(string email, string folderId, string? orderBy = "folder,name_natural", CancellationToken ct = default) =>
        ListAll(email, $"'{Escape(folderId)}' in parents and trashed = false", orderBy, 1000, true, ct);

    public Task<List<DriveFile>> ListSharedWithMe(string email, CancellationToken ct = default) =>
        ListAll(email, "sharedWithMe = true and trashed = false", "folder,name", 1000, true, ct);

    /// <summary>Whole-account name search; first page only (200).</summary>
    public Task<List<DriveFile>> Search(string email, string text, CancellationToken ct = default) =>
        ListAll(email, $"name contains '{Escape(text)}' and trashed = false", "folder,name", 200, false, ct);

    public Task<DriveFile> Get(string email, string id, CancellationToken ct = default) =>
        Call<DriveFile>(Request(HttpMethod.Get, email, $"drive/v3/files/{Uri.EscapeDataString(id)}?fields={Uri.EscapeDataString(FileFields)}&supportsAllDrives=true"),
            ct, "Couldn't open the file");

    // ---- files.update --------------------------------------------------------------------------------------

    private Task<DriveFile> Update(string email, string id, object body, string? addParents, string? removeParents, CancellationToken ct, string what)
    {
        var url = $"drive/v3/files/{Uri.EscapeDataString(id)}?fields={Uri.EscapeDataString(FileFields)}&supportsAllDrives=true" +
                  (addParents != null ? "&addParents=" + Uri.EscapeDataString(addParents) : "") +
                  (removeParents != null ? "&removeParents=" + Uri.EscapeDataString(removeParents) : "");
        return Call<DriveFile>(Request(HttpMethod.Patch, email, url, body), ct, what);
    }

    public Task<DriveFile> Rename(string email, string id, string newName, CancellationToken ct = default) =>
        Update(email, id, new UpdateBody { Name = newName }, null, null, ct, "Rename failed");

    public Task<DriveFile> Move(string email, string id, string? fromParent, string toParent, CancellationToken ct = default) =>
        Update(email, id, new UpdateBody(), toParent, fromParent, ct, "Move failed");

    /// <summary>To Drive's trash (recoverable for 30 days).</summary>
    public async Task Trash(string email, string id, CancellationToken ct = default) =>
        await Update(email, id, new UpdateBody { Trashed = true }, null, null, ct, "Move to trash failed").ConfigureAwait(false);

    /// <summary>files.delete: skips the trash. Owner only; a folder goes with everything in it.</summary>
    public async Task DeletePermanently(string email, string id, CancellationToken ct = default)
    {
        using var request = Request(HttpMethod.Delete, email, $"drive/v3/files/{Uri.EscapeDataString(id)}?supportsAllDrives=true");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(CallTimeout);
        HttpResponseMessage response;
        try { response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false); }
        catch (HttpRequestException e) { throw new IOException(e.Message, e); }
        using (response)
        {
            if (response.IsSuccessStatusCode) return;
            throw new IOException(response.StatusCode == HttpStatusCode.Forbidden
                ? "Only the owner of this file can delete it permanently"
                : $"Delete failed (HTTP {(int)response.StatusCode})");
        }
    }

    public Task<DriveFile> CreateFolder(string email, string parentId, string name, CancellationToken ct = default) =>
        Call<DriveFile>(Request(HttpMethod.Post, email, $"drive/v3/files?fields={Uri.EscapeDataString(FileFields)}&supportsAllDrives=true",
            new CreateBody { Name = name, MimeType = DriveFile.FolderMime, Parents = new List<string> { parentId } }), ct, "Couldn't create the folder");

    // ---- about ---------------------------------------------------------------------------------------------

    public Task<DriveAbout> About(string email, CancellationToken ct = default) =>
        Call<DriveAbout>(Request(HttpMethod.Get, email, "drive/v3/about?fields=" + Uri.EscapeDataString(AboutFields)), ct, "Couldn't open your Drive");

    /// <summary>limit - usage (≥ 0); null when Drive reports no limit (unlimited) or no quota.</summary>
    public async Task<long?> FreeBytes(string email, CancellationToken ct = default)
    {
        var q = (await About(email, ct).ConfigureAwait(false)).StorageQuota;
        if (q == null || !long.TryParse(q.Limit, out var limit) || !long.TryParse(q.Usage, out var usage)) return null;
        return Math.Max(0, limit - usage);
    }

    public async Task<StorageSpace?> Space(string email, CancellationToken ct = default)
    {
        var q = (await About(email, ct).ConfigureAwait(false)).StorageQuota;
        return SpaceFrom(q);
    }

    public static StorageSpace? SpaceFrom(StorageQuota? q)
    {
        if (q == null || !long.TryParse(q.Usage, out var usage)) return null;
        long? total = long.TryParse(q.Limit, out var limit) ? limit : null;
        return new StorageSpace("Google storage", usage, total, total != null ? Math.Max(0, total.Value - usage) : null);
    }

    // ---- downloads -----------------------------------------------------------------------------------------

    public static string MediaUrl(string id) => $"{Base}drive/v3/files/{Uri.EscapeDataString(id)}?alt=media&supportsAllDrives=true";

    private static IOException DownloadError(HttpStatusCode status) => new(status switch
    {
        HttpStatusCode.Forbidden => "Google Drive refused the download (it may have hit its daily download limit, or be flagged by Google).",
        HttpStatusCode.NotFound => "The file is no longer in Google Drive.",
        _ => $"Download failed (HTTP {(int)status}).",
    });

    /// <summary>Streams the whole file. The stream given to <paramref name="block"/> times out after 60 s without data.</summary>
    public async Task Download(string email, string id, Func<Stream, long, Task> block, CancellationToken ct = default)
    {
        using var request = Request(HttpMethod.Get, email, MediaUrl(id));
        HttpResponseMessage response;
        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            cts.CancelAfter(CallTimeout);
            try { response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("Google Drive didn't respond in time."); }
            catch (HttpRequestException e) { throw new IOException(e.Message, e); }
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode) throw DownloadError(response.StatusCode);
            var length = response.Content.Headers.ContentLength ?? -1;
            await using var raw = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var timed = new IdleTimeoutStream(raw, ReadTimeout, ct);
            await block(timed, length).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Opens the file from byte <paramref name="from"/> (Range: bytes=from-). Returns null at or past the end (416).
    /// The caller owns the response. Each call gets a fresh bearer token, so streams survive token expiry.
    /// </summary>
    public async Task<HttpResponseMessage?> OpenRange(string email, string id, long from, CancellationToken ct = default)
    {
        var request = Request(HttpMethod.Get, email, MediaUrl(id));
        request.Headers.Range = new RangeHeaderValue(from, null);
        HttpResponseMessage response;
        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            cts.CancelAfter(CallTimeout);
            try { response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("Google Drive didn't respond in time."); }
            catch (HttpRequestException e) { throw new IOException(e.Message, e); }
        }
        if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            response.Dispose();
            return null;
        }
        if (!response.IsSuccessStatusCode)
        {
            var status = response.StatusCode;
            response.Dispose();
            throw DownloadError(status);
        }
        return response;
    }

    // ---- resumable upload ----------------------------------------------------------------------------------

    /// <summary>
    /// Resumable upload in 8 MiB chunks. <paramref name="size"/> may be -1 (unknown, e.g. a ZIP entry with a data
    /// descriptor): chunks then declare "/*" until the last one, which declares the total. The stream from
    /// <paramref name="open"/> is disposed at the end. There is no per-chunk retry: jobs retry from byte 0.
    /// </summary>
    public async Task<DriveFile> Upload(string email, string parentId, string name, string mimeType, long size, Func<Stream> open,
        Action<long, long>? onProgress = null, CancellationToken ct = default)
    {
        string session;
        using (var start = Request(HttpMethod.Post,
                   email, $"{Base}upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields={Uri.EscapeDataString(FileFields)}"))
        {
            start.Headers.TryAddWithoutValidation("X-Upload-Content-Type", mimeType);
            if (size >= 0) start.Headers.TryAddWithoutValidation("X-Upload-Content-Length", size.ToString());
            var meta = JsonSerializer.Serialize(new CreateBody { Name = name, MimeType = mimeType, Parents = new List<string> { parentId } }, Json);
            start.Content = new StringContent(meta, Encoding.UTF8);
            start.Content.Headers.ContentType = MediaTypeHeaderValue.Parse("application/json; charset=UTF-8");
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(CallTimeout);
            try
            {
                using var response = await _http.SendAsync(start, cts.Token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode) throw await UploadError("Upload could not start", response, cts.Token).ConfigureAwait(false);
                session = response.Headers.Location?.ToString() ?? throw new IOException("Drive did not return an upload session");
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("Google Drive didn't respond in time."); }
            catch (HttpRequestException e) { throw new IOException(e.Message, e); }
        }

        await using var input = open();
        var buffer = new byte[ChunkSize];
        long offset = 0;
        while (true)
        {
            var read = await ReadChunk(input, buffer, ct).ConfigureAwait(false);
            var last = read < ChunkSize;
            var count = Math.Max(read, 0);
            var total = size >= 0 ? size.ToString() : last ? (offset + count).ToString() : "*";
            var range = count == 0 ? $"bytes */{total}" : $"bytes {offset}-{offset + count - 1}/{total}";

            using var put = Request(HttpMethod.Put, email, session);
            put.Content = new ByteArrayContent(buffer, 0, count);
            put.Content.Headers.TryAddWithoutValidation("Content-Range", range);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(ChunkTimeout);
            HttpResponseMessage response;
            try { response = await _http.SendAsync(put, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("Upload timed out"); }
            catch (HttpRequestException e) { throw new IOException(e.Message, e); }
            using (response)
            {
                if ((int)response.StatusCode == 308)
                {
                    if (last) throw new IOException("File ended before upload completed");
                    offset += count;
                    onProgress?.Invoke(offset, size);
                    continue;
                }
                if (response.IsSuccessStatusCode)
                {
                    onProgress?.Invoke(offset + count, size);
                    var text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                    return JsonSerializer.Deserialize<DriveFile>(text, Json) ?? throw new IOException("Upload failed: empty answer from Drive");
                }
                throw await UploadError("Upload failed", response, ct).ConfigureAwait(false);
            }
        }
    }

    /// <summary>Fills the buffer unless the stream ends first; -1 when nothing at all was read.</summary>
    private static async Task<int> ReadChunk(Stream input, byte[] buffer, CancellationToken ct)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await input.ReadAsync(buffer.AsMemory(total), ct).ConfigureAwait(false);
            if (n <= 0) break;
            total += n;
        }
        return total == 0 ? -1 : total;
    }

    private static async Task<IOException> UploadError(string what, HttpResponseMessage response, CancellationToken ct)
    {
        var body = "";
        try { body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false); }
        catch (Exception) { }
        if (response.StatusCode == HttpStatusCode.Forbidden && body.Contains("storageQuotaExceeded")) return new DriveStorageFullException();
        return new IOException($"{what} (HTTP {(int)response.StatusCode})");
    }

    private sealed class UpdateBody
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("trashed")] public bool? Trashed { get; set; }
    }

    private sealed class CreateBody
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("mimeType")] public string MimeType { get; set; } = "";
        [JsonPropertyName("parents")] public List<string> Parents { get; set; } = new();
    }
}

/// <summary>Fails a read that gets no data for <c>timeout</c> (a stalled connection) instead of hanging forever.</summary>
public sealed class IdleTimeoutStream(Stream inner, TimeSpan timeout, CancellationToken outer) : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
        ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct, outer);
        cts.CancelAfter(timeout);
        try
        {
            return await inner.ReadAsync(buffer, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && !outer.IsCancellationRequested)
        {
            throw new IOException("The download stalled (no data for a minute).");
        }
        catch (HttpRequestException e)
        {
            throw new IOException(e.Message, e);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) inner.Dispose();
        base.Dispose(disposing);
    }
}
