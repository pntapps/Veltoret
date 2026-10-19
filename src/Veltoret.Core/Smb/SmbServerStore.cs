using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Veltoret.Core.Data;

namespace Veltoret.Core.Smb;

/// <summary>
/// A network share server (SMB: Windows file sharing, Samba on routers and NAS boxes). Its account id is
/// <see cref="Account"/> ("smb://host"); files are "smb://host/share/folder/file" (see <see cref="SmbPath"/>).
/// </summary>
public sealed record SmbServer
{
    public string Host { get; init; } = "";
    public int Port { get; init; } = 445;
    /// <summary>Empty for guest access.</summary>
    public string Username { get; init; } = "";
    public string Domain { get; init; } = "";
    /// <summary>What the user sees; the host unless the server told us its name.</summary>
    public string Name { get; init; } = "";

    [JsonIgnore] public string Account => SmbPath.AccountOf(Host);
    [JsonIgnore] public bool Guest => Username.Length == 0;
    [JsonIgnore] public string DisplayName => string.IsNullOrEmpty(Name) ? Host : Name;
}

/// <summary>
/// Saved servers and their passwords (Android: SmbServerStore). Passwords are encrypted with DPAPI for the current
/// Windows user (entropy "veltoret-smb"); a blob that can't be decrypted (profile copied to another PC) means
/// "sign in again". The file lives under <see cref="AppPaths.Secrets"/> and is never logged or exported.
/// </summary>
public sealed class SmbServerStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("veltoret-smb");
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    private readonly string _path;
    private readonly object _lock = new();
    private List<Entry> _entries;

    public SmbServerStore(string path)
    {
        _path = path;
        _entries = Load();
    }

    /// <summary>Raised (on any thread) after a server is saved or removed.</summary>
    public event Action? Changed;

    /// <summary>Saved servers, sorted by name.</summary>
    public IReadOnlyList<SmbServer> Servers
    {
        get { lock (_lock) return _entries.Select(e => e.ToServer()).OrderBy(s => s.DisplayName.ToLowerInvariant(), StringComparer.Ordinal).ToList(); }
    }

    public SmbServer? Server(string account)
    {
        lock (_lock) return _entries.FirstOrDefault(e => e.ToServer().Account == account)?.ToServer();
    }

    public void Save(SmbServer server, string password)
    {
        lock (_lock)
        {
            _entries.RemoveAll(e => e.ToServer().Account == server.Account);
            _entries.Add(Entry.From(server with { Host = server.Host.Trim().ToLowerInvariant() }, password.Length == 0 ? "" : Protect(password)));
            Persist();
        }
        Changed?.Invoke();
    }

    public void Remove(string account)
    {
        lock (_lock)
        {
            _entries.RemoveAll(e => e.ToServer().Account == account);
            Persist();
        }
        Changed?.Invoke();
    }

    /// <summary>"" for guest or an empty password; null when it can't be decrypted (sign in again) or the server is unknown.</summary>
    public string? Password(string account)
    {
        string? stored;
        lock (_lock) stored = _entries.FirstOrDefault(e => e.ToServer().Account == account)?.Password;
        if (stored == null) return null;
        if (stored.Length == 0) return "";
        try
        {
            return Unprotect(stored);
        }
        catch
        {
            return null;
        }
    }

    private static string Protect(string password)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Passwords are encrypted with Windows DPAPI");
        return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(password), Entropy, DataProtectionScope.CurrentUser));
    }

    private static string Unprotect(string stored)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser));
    }

    private List<Entry> Load()
    {
        try
        {
            if (!File.Exists(_path)) return new();
            var file = JsonSerializer.Deserialize<FileShape>(File.ReadAllText(_path), Json);
            return file?.Servers?.Where(e => !string.IsNullOrWhiteSpace(e.Host)).ToList() ?? new();
        }
        catch
        {
            return new();
        }
    }

    private void Persist()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(new FileShape { Servers = _entries }, Json));
        if (File.Exists(_path)) File.Replace(tmp, _path, null);
        else File.Move(tmp, _path);
    }

    private sealed class FileShape
    {
        public List<Entry>? Servers { get; set; }
    }

    private sealed class Entry
    {
        public string Host { get; set; } = "";
        public int Port { get; set; } = 445;
        public string Username { get; set; } = "";
        public string Domain { get; set; } = "";
        public string? Name { get; set; }
        /// <summary>Base64 DPAPI blob, or "" for guest / no password.</summary>
        public string Password { get; set; } = "";

        public SmbServer ToServer() => new()
        {
            Host = Host.Trim().ToLowerInvariant(),
            Port = Port <= 0 ? 445 : Port,
            Username = Username ?? "",
            Domain = Domain ?? "",
            Name = string.IsNullOrEmpty(Name) ? Host.Trim().ToLowerInvariant() : Name,
        };

        public static Entry From(SmbServer s, string password) => new()
        {
            Host = s.Host, Port = s.Port, Username = s.Username, Domain = s.Domain,
            Name = string.IsNullOrEmpty(s.Name) ? s.Host : s.Name, Password = password,
        };
    }
}

/// <summary>Library account rows for saved servers (Android: AccountRepository.addServerAccount / ensureServerAccounts).</summary>
public static class SmbAccounts
{
    public static async Task AddServerAccount(AccountDao dao, SmbServer server)
    {
        var existing = (await dao.Accounts()).FirstOrDefault(a => a.Email == server.Account);
        await dao.Upsert(new AccountEntity
        {
            Email = server.Account,
            DisplayName = server.DisplayName,
            PhotoUrl = null,
            AddedAt = existing?.AddedAt ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        });
    }

    /// <summary>Back-fills account rows for saved servers (runs at app start).</summary>
    public static async Task EnsureServerAccounts(AccountDao dao, SmbServerStore store)
    {
        var accounts = (await dao.Accounts()).Select(a => a.Email).ToHashSet();
        foreach (var server in store.Servers)
            if (!accounts.Contains(server.Account)) await AddServerAccount(dao, server);
    }
}
