using System.Net;
using System.Text;
using Veltoret.Core.Auth;
using Veltoret.Core.Drive;

namespace Veltoret.Core.Tests.Drive;

/// <summary>Minimal in-memory Drive resumable endpoint that records each chunk's Content-Range (Android test's FakeDrive).</summary>
internal sealed class FakeUploadHandler : HttpMessageHandler
{
    public readonly List<string> Ranges = new();
    public readonly MemoryStream Received = new();
    public int Uploads;
    /// <summary>Answer chunks with this status and body instead (a full account, a permission problem…).</summary>
    public (int Code, string Body)? Refuse;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        if (request.Method == HttpMethod.Post)
        {
            var r = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("") };
            r.Headers.Location = new Uri("https://upload.example/session");
            return r;
        }
        if (Refuse is { } refuse) return new HttpResponseMessage((HttpStatusCode)refuse.Code) { Content = new StringContent(refuse.Body) };
        var range = request.Content!.Headers.GetValues("Content-Range").Single();
        Ranges.Add(range);
        var bytes = await request.Content.ReadAsByteArrayAsync(ct);
        Received.Write(bytes);
        // "bytes a-b/total" or "bytes */total": complete once the total is known and reached.
        var total = range[(range.IndexOf('/') + 1)..];
        if (total != "*" && Received.Length == long.Parse(total))
        {
            Uploads++;
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent($"{{\"id\":\"f{Uploads}\",\"name\":\"x\",\"size\":\"{total}\"}}", Encoding.UTF8, "application/json"),
            };
        }
        return new HttpResponseMessage((HttpStatusCode)308) { Content = new StringContent("") };
    }
}

internal sealed class FixedTokens : ITokenProvider
{
    public int Issued;
    public readonly List<string> Invalidated = new();
    public Task<string> AccessToken(string email, CancellationToken ct = default) => Task.FromResult("token-" + Interlocked.Increment(ref Issued));
    public void Invalidate(string email) => Invalidated.Add(email);
}

/// <summary>A stream that refuses to seek or report its length, like an HTTP response.</summary>
internal sealed class NonSeekable(Stream inner) : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

/// <summary>An in-memory Google Drive for extraction tests.</summary>
internal sealed class FakeDriveClient : IDriveClient
{
    public sealed record Item(DriveFile File, byte[] Bytes);

    public readonly Dictionary<string, Item> Items = new();
    public readonly List<string> Trashed = new();
    public readonly List<string> Deleted = new();
    public int Downloads;
    public int UploadCalls;
    public long? Free = 100_000_000;
    /// <summary>Uploads of this file name fail with this exception.</summary>
    public Func<string, Exception?> UploadFailure = _ => null;
    private int _next;

    public string Add(string parent, string name, byte[]? bytes = null, bool folder = false)
    {
        var id = "id" + Interlocked.Increment(ref _next);
        Items[id] = new Item(new DriveFile
        {
            Id = id,
            Name = name,
            MimeType = folder ? DriveFile.FolderMime : "application/octet-stream",
            Size = folder ? null : (bytes?.Length ?? 0).ToString(),
            Parents = new List<string> { parent },
        }, bytes ?? Array.Empty<byte>());
        return id;
    }

    public IEnumerable<Item> Children(string parent) => Items.Values.Where(i => i.File.Parents!.Contains(parent));

    public string? PathOf(string id)
    {
        if (!Items.TryGetValue(id, out var item)) return null;
        var parent = item.File.Parents![0];
        return Items.ContainsKey(parent) ? PathOf(parent) + "/" + item.File.Name : item.File.Name;
    }

    public Task<List<DriveFile>> ListChildren(string email, string folderId, string? orderBy = "folder,name_natural", CancellationToken ct = default) =>
        Task.FromResult(Children(folderId).Select(i => i.File).ToList());

    public Task<DriveFile> CreateFolder(string email, string parentId, string name, CancellationToken ct = default) =>
        Task.FromResult(Items[Add(parentId, name, folder: true)].File);

    public Task Trash(string email, string id, CancellationToken ct = default)
    {
        Trashed.Add(id);
        return Task.CompletedTask;
    }

    public Task DeletePermanently(string email, string id, CancellationToken ct = default)
    {
        Deleted.Add(id);
        Items.Remove(id);
        return Task.CompletedTask;
    }

    public Task<long?> FreeBytes(string email, CancellationToken ct = default) => Task.FromResult(Free);

    public async Task Download(string email, string id, Func<Stream, long, Task> block, CancellationToken ct = default)
    {
        Downloads++;
        var bytes = Items[id].Bytes;
        await block(new NonSeekable(new MemoryStream(bytes)), bytes.Length);
    }

    public async Task<DriveFile> Upload(string email, string parentId, string name, string mimeType, long size, Func<Stream> open,
        Action<long, long>? onProgress = null, CancellationToken ct = default)
    {
        UploadCalls++;
        if (UploadFailure(name) is { } failure) throw failure;
        await using var s = open();
        var ms = new MemoryStream();
        await s.CopyToAsync(ms, ct);
        onProgress?.Invoke(ms.Length, size);
        var id = Add(parentId, name, ms.ToArray());
        return Items[id].File;
    }
}
