namespace Veltoret.Core.Smb;

/// <summary>MIME type from a file name's extension (Android: MimeTypeMap); application/octet-stream when unknown.</summary>
public static class SmbMime
{
    private static readonly Dictionary<string, string> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        ["mkv"] = "video/x-matroska", ["mk3d"] = "video/x-matroska", ["mka"] = "audio/x-matroska",
        ["mp4"] = "video/mp4", ["m4v"] = "video/mp4", ["mov"] = "video/quicktime", ["avi"] = "video/x-msvideo",
        ["wmv"] = "video/x-ms-wmv", ["asf"] = "video/x-ms-asf", ["flv"] = "video/x-flv", ["webm"] = "video/webm",
        ["mpg"] = "video/mpeg", ["mpeg"] = "video/mpeg", ["m2ts"] = "video/mp2t", ["mts"] = "video/mp2t", ["ts"] = "video/mp2t",
        ["3gp"] = "video/3gpp", ["3g2"] = "video/3gpp2", ["ogv"] = "video/ogg", ["vob"] = "video/dvd", ["divx"] = "video/divx",
        ["srt"] = "application/x-subrip", ["vtt"] = "text/vtt", ["ass"] = "text/x-ssa", ["ssa"] = "text/x-ssa",
        ["sub"] = "text/plain", ["idx"] = "text/plain", ["txt"] = "text/plain", ["nfo"] = "text/plain",
        ["zip"] = "application/zip", ["rar"] = "application/vnd.rar", ["7z"] = "application/x-7z-compressed",
        ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif", ["webp"] = "image/webp",
        ["bmp"] = "image/bmp", ["mp3"] = "audio/mpeg", ["m4a"] = "audio/mp4", ["aac"] = "audio/aac", ["flac"] = "audio/flac",
        ["wav"] = "audio/x-wav", ["ogg"] = "audio/ogg", ["opus"] = "audio/ogg", ["pdf"] = "application/pdf",
    };

    public static string For(string name)
    {
        var dot = name.LastIndexOf('.');
        if (dot < 0 || dot == name.Length - 1) return "application/octet-stream";
        return Types.TryGetValue(name[(dot + 1)..], out var t) ? t : "application/octet-stream";
    }
}
