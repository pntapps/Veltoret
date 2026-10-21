namespace Veltoret.Core.Smb;

/// <summary>
/// Ids for things on a network share (port of Android's SmbPath): "smb://host" is the server (lists its shares),
/// "smb://host/share" a share, and "smb://host/share/folder/file" anything inside one. The host is part of every
/// id because ids must be unique across sources (they're primary keys of library rows). Ids are not URL-encoded
/// and must stay byte-identical to Android's (the TV matches files by id).
/// </summary>
public sealed class SmbPath : IEquatable<SmbPath>
{
    public const string Scheme = "smb://";

    public string Host { get; }
    public string? Share { get; }
    public IReadOnlyList<string> Segments { get; }

    public SmbPath(string host, string? share, IReadOnlyList<string>? segments = null)
    {
        Host = host;
        Share = share;
        Segments = segments ?? Array.Empty<string>();
    }

    public string Id
    {
        get
        {
            var sb = new System.Text.StringBuilder(Scheme).Append(Host);
            if (Share != null)
            {
                sb.Append('/').Append(Share);
                foreach (var s in Segments) sb.Append('/').Append(s);
            }
            return sb.ToString();
        }
    }

    /// <summary>The path inside the share as SMB wants it ("folder\\file"; "" for the share itself).</summary>
    public string SharePath => string.Join("\\", Segments);

    public string Name => Segments.Count > 0 ? Segments[^1] : Share ?? Host;

    public SmbPath? Parent =>
        Segments.Count > 0 ? new SmbPath(Host, Share, Segments.Take(Segments.Count - 1).ToArray())
        : Share != null ? new SmbPath(Host, null, Array.Empty<string>())
        : null;

    public SmbPath Child(string name) =>
        Share == null ? new SmbPath(Host, name, Array.Empty<string>()) : new SmbPath(Host, Share, Segments.Append(name).ToArray());

    /// <summary>The server's account id ("smb://host").</summary>
    public string Account => Scheme + Host;

    public static bool IsSmb(string? id) => id != null && id.StartsWith(Scheme, StringComparison.Ordinal);

    public static string AccountOf(string host) => Scheme + host.Trim().ToLowerInvariant();

    public static SmbPath Parse(string id)
    {
        if (!IsSmb(id)) throw new ArgumentException($"Not a network share path: {id}");
        var parts = id.Substring(Scheme.Length).Split('/').Where(p => p.Length > 0).ToArray();
        if (parts.Length == 0) throw new ArgumentException($"No server in {id}");
        return new SmbPath(parts[0].ToLowerInvariant(), parts.Length > 1 ? parts[1] : null, parts.Skip(2).ToArray());
    }

    /// <summary>
    /// Reads what people type or paste: "\\192.168.0.10\share\folder" (Windows), "smb://nas/share",
    /// "192.168.0.10/share" or just a host name. Returns null when there's no host.
    /// </summary>
    public static SmbPath? FromUserInput(string text)
    {
        var cleaned = text.Trim();
        if (cleaned.StartsWith("smb:", StringComparison.Ordinal)) cleaned = cleaned.Substring(4);
        cleaned = cleaned.Replace('\\', '/').Trim('/');
        var parts = cleaned.Split('/').Select(p => p.Trim()).Where(p => p.Length > 0).ToArray();
        if (parts.Length == 0) return null;
        var host = parts[0].ToLowerInvariant();
        if (host.Any(char.IsWhiteSpace)) return null;
        return new SmbPath(host, parts.Length > 1 ? parts[1] : null, parts.Skip(2).ToArray());
    }

    /// <summary>The UNC form (\\host\share\a\b), for display.</summary>
    public string Unc => "\\\\" + Host + (Share == null ? "" : "\\" + Share + (Segments.Count > 0 ? "\\" + SharePath : ""));

    public bool Equals(SmbPath? other) =>
        other != null && Host == other.Host && Share == other.Share && Segments.SequenceEqual(other.Segments);

    public override bool Equals(object? obj) => obj is SmbPath p && Equals(p);

    public override int GetHashCode() => Id.GetHashCode(StringComparison.Ordinal);

    public override string ToString() => Id;
}
