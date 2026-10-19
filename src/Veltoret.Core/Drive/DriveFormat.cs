using System.Globalization;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Drive;

/// <summary>Text helpers for the Files screen, transfers and the Extract dialog (Android: ui/util/Format + StorageSummary).</summary>
public static class DriveFormat
{
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    /// <summary>"—" for ≤ 0; B, KB, MB, GB, TB in 1024 steps, one decimal from GB up.</summary>
    public static string Bytes(long bytes)
    {
        if (bytes <= 0) return "—";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit >= 3 ? value.ToString("0.0", Us) + " " + units[unit] : value.ToString("0", Us) + " " + units[unit];
    }

    private static string SpaceBytes(long b) => b <= 0 ? "0 B" : Bytes(b);

    /// <summary>"Google storage · 4.2 GB used of 15 GB · 10.8 GB free".</summary>
    public static string StorageSummary(StorageSpace space)
    {
        var parts = new List<string> { space.Name };
        parts.Add(space.Total is > 0
            ? $"{SpaceBytes(space.Used)} used of {SpaceBytes(space.Total.Value)}"
            : $"{SpaceBytes(space.Used)} used");
        if (space.Free != null) parts.Add($"{SpaceBytes(space.Free.Value)} free");
        return string.Join(" · ", parts);
    }

    /// <summary>Filled fraction of the storage bar (0..1), or null when the total is unknown (no bar).</summary>
    public static double? StorageFraction(StorageSpace space) =>
        space.Total is > 0 ? Math.Clamp((double)space.Used / space.Total.Value, 0, 1) : null;

    /// <summary>The bar turns Danger at 90 % full.</summary>
    public static bool StorageAlmostFull(StorageSpace space) => StorageFraction(space) >= 0.9;

    /// <summary>"Mar 4, 2025" in local time, or null.</summary>
    public static string? DriveDate(string? iso)
    {
        if (string.IsNullOrEmpty(iso)) return null;
        return DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d)
            ? d.ToLocalTime().ToString("MMM d, yyyy", Us)
            : null;
    }

    /// <summary>"4:05", "1:02:09".</summary>
    public static string Clock(long ms)
    {
        var total = Math.Max(0, ms) / 1000;
        var h = total / 3600;
        var m = total % 3600 / 60;
        var s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }

    /// <summary>MIME type for uploads (Android: mimeFor + MimeTypeMap).</summary>
    public static string MimeFor(string name) => FilenameParser.Extension(name) switch
    {
        "mkv" => "video/x-matroska",
        "srt" => "application/x-subrip",
        "ass" or "ssa" => "text/x-ssa",
        "vtt" => "text/vtt",
        "mp4" or "m4v" => "video/mp4",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "wmv" => "video/x-ms-wmv",
        "asf" => "video/x-ms-asf",
        "flv" => "video/x-flv",
        "f4v" => "video/x-f4v",
        "webm" => "video/webm",
        "ts" or "m2ts" or "mts" => "video/mp2t",
        "mpg" or "mpeg" or "vob" => "video/mpeg",
        "3gp" => "video/3gpp",
        "ogv" => "video/ogg",
        "divx" => "video/divx",
        "rmvb" => "application/vnd.rn-realmedia-vbr",
        "mxf" => "application/mxf",
        "ttml" => "application/ttml+xml",
        "dfxp" => "application/ttaf+xml",
        "zip" => "application/zip",
        "jpg" or "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "txt" or "nfo" => "text/plain",
        "pdf" => "application/pdf",
        "json" => "application/json",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        _ => "application/octet-stream",
    };
}
