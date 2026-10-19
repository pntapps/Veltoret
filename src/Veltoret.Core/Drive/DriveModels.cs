using System.Text.Json.Serialization;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Drive;

/// <summary>Drive is out of space (HTTP 403 storageQuotaExceeded). Retrying can't help until space is freed.</summary>
public sealed class DriveStorageFullException() : IOException("Google Drive is full");

/// <summary>A file or folder as Drive v3 returns it. int64 values (size, duration) arrive as JSON strings.</summary>
public sealed class DriveFile
{
    public const string FolderMime = "application/vnd.google-apps.folder";

    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("mimeType")] public string MimeType { get; set; } = "";
    [JsonPropertyName("size")] public string? Size { get; set; }
    [JsonPropertyName("modifiedTime")] public string? ModifiedTime { get; set; }
    [JsonPropertyName("parents")] public List<string>? Parents { get; set; }
    [JsonPropertyName("fileExtension")] public string? FileExtension { get; set; }
    [JsonPropertyName("videoMediaMetadata")] public VideoMetadata? VideoMediaMetadata { get; set; }
    [JsonPropertyName("capabilities")] public Capabilities? Capabilities { get; set; }

    [JsonIgnore] public bool IsFolder => MimeType == FolderMime;
    [JsonIgnore] public long SizeBytes => long.TryParse(Size, out var n) ? n : 0;

    public StorageItem ToItem() => new()
    {
        Id = Id,
        Name = Name,
        MimeType = MimeType,
        IsFolder = IsFolder,
        SizeBytes = SizeBytes,
        ModifiedTime = ModifiedTime,
        Parents = Parents ?? new List<string>(),
        Width = VideoMediaMetadata?.Width,
        Height = VideoMediaMetadata?.Height,
        DurationMs = long.TryParse(VideoMediaMetadata?.DurationMillis, out var d) ? d : null,
        CanRename = Capabilities?.CanRename ?? true,
        CanTrash = Capabilities?.CanTrash ?? true,
        CanDelete = Capabilities?.CanDelete ?? false,
        CanAddChildren = Capabilities?.CanAddChildren ?? true,
    };
}

public sealed class VideoMetadata
{
    [JsonPropertyName("width")] public int? Width { get; set; }
    [JsonPropertyName("height")] public int? Height { get; set; }
    [JsonPropertyName("durationMillis")] public string? DurationMillis { get; set; }
}

public sealed class Capabilities
{
    [JsonPropertyName("canRename")] public bool? CanRename { get; set; }
    [JsonPropertyName("canTrash")] public bool? CanTrash { get; set; }
    [JsonPropertyName("canDelete")] public bool? CanDelete { get; set; }
    [JsonPropertyName("canAddChildren")] public bool? CanAddChildren { get; set; }
}

public sealed class DriveFileList
{
    [JsonPropertyName("nextPageToken")] public string? NextPageToken { get; set; }
    [JsonPropertyName("files")] public List<DriveFile> Files { get; set; } = new();
}

public sealed class DriveAbout
{
    [JsonPropertyName("user")] public DriveUser? User { get; set; }
    [JsonPropertyName("storageQuota")] public StorageQuota? StorageQuota { get; set; }
}

public sealed class DriveUser
{
    [JsonPropertyName("displayName")] public string? DisplayName { get; set; }
    [JsonPropertyName("emailAddress")] public string? EmailAddress { get; set; }
    [JsonPropertyName("photoLink")] public string? PhotoLink { get; set; }
}

public sealed class StorageQuota
{
    [JsonPropertyName("limit")] public string? Limit { get; set; }
    [JsonPropertyName("usage")] public string? Usage { get; set; }
}

/// <summary>What happens to the ZIP once every file in it has been extracted.</summary>
public enum ZipAfterExtract { Keep, Trash, Delete }

/// <summary>The Drive calls ZIP extraction and uploads need (DriveRepository; an in-memory fake in tests).</summary>
public interface IDriveClient
{
    Task<List<DriveFile>> ListChildren(string email, string folderId, string? orderBy = "folder,name_natural", CancellationToken ct = default);
    Task<DriveFile> CreateFolder(string email, string parentId, string name, CancellationToken ct = default);
    Task Trash(string email, string id, CancellationToken ct = default);
    Task DeletePermanently(string email, string id, CancellationToken ct = default);
    Task<long?> FreeBytes(string email, CancellationToken ct = default);
    /// <summary>Streams the file's bytes to <paramref name="block"/> with its length (-1 when unknown).</summary>
    Task Download(string email, string id, Func<Stream, long, Task> block, CancellationToken ct = default);
    Task<DriveFile> Upload(string email, string parentId, string name, string mimeType, long size, Func<Stream> open,
        Action<long, long>? onProgress = null, CancellationToken ct = default);
}
