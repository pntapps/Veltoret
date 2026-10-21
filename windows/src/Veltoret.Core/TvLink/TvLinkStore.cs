using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Veltoret.Core.TvLink;

/// <summary>
/// Paired TVs and their shared secrets, plus this PC's own link id (Android TvLinkStore).
/// <c>%LOCALAPPDATA%\Veltoret\tv_link.json</c> = <c>{deviceId, peers:[{id,name,secret}]}</c>; each secret is
/// DPAPI-encrypted for the current Windows user (entropy "veltoret-link"). Never logged; kept out of exports.
/// </summary>
public sealed class TvLinkStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("veltoret-link");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private sealed class FileModel
    {
        public string DeviceId { get; set; } = "";
        public List<PeerModel> Peers { get; set; } = new();
    }

    private sealed class PeerModel
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Secret { get; set; } = "";
    }

    private readonly string _path;
    private readonly object _lock = new();
    private readonly Func<string, string> _protect;
    private readonly Func<string, string> _unprotect;
    private FileModel _model;

    public event Action? Changed;

    public TvLinkStore(string path) : this(path, Protect, Unprotect) { }

    /// <summary>For tests: custom protection.</summary>
    public TvLinkStore(string path, Func<string, string> protect, Func<string, string> unprotect)
    {
        _path = path;
        _protect = protect;
        _unprotect = unprotect;
        _model = Load();
        if (string.IsNullOrEmpty(_model.DeviceId))
        {
            _model.DeviceId = Guid.NewGuid().ToString();
            Save();
        }
    }

    public static string DefaultPath => Path.Combine(AppPaths.Root, "tv_link.json");

    /// <summary>This PC's id in the link protocol (random UUID, made once).</summary>
    public string DeviceId { get { lock (_lock) return _model.DeviceId; } }

    public IReadOnlyList<LinkPeer> Peers
    {
        get
        {
            lock (_lock)
                return _model.Peers.Select(p => new LinkPeer(p.Id, p.Name)).OrderBy(p => p.Name.ToLowerInvariant(), StringComparer.Ordinal).ToList();
        }
    }

    public void Save(LinkPeer peer, string secret)
    {
        lock (_lock)
        {
            _model.Peers.RemoveAll(p => p.Id == peer.Id);
            _model.Peers.Add(new PeerModel { Id = peer.Id, Name = peer.Name, Secret = _protect(secret) });
            Save();
        }
        Changed?.Invoke();
    }

    public void Remove(string id)
    {
        bool removed;
        lock (_lock)
        {
            removed = _model.Peers.RemoveAll(p => p.Id == id) > 0;
            if (removed) Save();
        }
        if (removed) Changed?.Invoke();
    }

    /// <summary>Null when not paired, or when it can't be decrypted (profile copied to another PC): pair again.</summary>
    public string? Secret(string id)
    {
        string? stored;
        lock (_lock) stored = _model.Peers.FirstOrDefault(p => p.Id == id)?.Secret;
        if (stored == null) return null;
        try { return _unprotect(stored); }
        catch (Exception e) when (e is CryptographicException or FormatException) { return null; }
    }

    private FileModel Load()
    {
        try
        {
            if (File.Exists(_path)) return JsonSerializer.Deserialize<FileModel>(File.ReadAllText(_path), Json) ?? new FileModel();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        return new FileModel();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_model, Json));
            File.Move(tmp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

#pragma warning disable CA1416 // DPAPI: Windows only, which is the only place this app runs.
    private static string Protect(string plain) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser));

    private static string Unprotect(string stored) =>
        Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser));
#pragma warning restore CA1416
}
