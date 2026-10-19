using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace Veltoret.Core.Auth;

/// <summary>Small named secrets (refresh tokens, the imported OAuth client). Never log what goes in here.</summary>
public interface ISecretStore
{
    string? Read(string name);
    void Write(string name, string value);
    void Delete(string name);
}

/// <summary>
/// Secrets as files under <see cref="AppPaths.Secrets"/>, each encrypted with DPAPI for the current Windows user
/// (another user on the PC, or a copy of the files on another PC, can't read them).
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class DpapiSecretStore(string directory) : ISecretStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Veltoret.Secrets.v1");
    private readonly object _lock = new();

    private string PathFor(string name) => Path.Combine(directory, name + ".bin");

    public string? Read(string name)
    {
        lock (_lock)
        {
            var path = PathFor(name);
            if (!File.Exists(path)) return null;
            try
            {
                var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch (Exception e) when (e is CryptographicException or IOException)
            {
                return null;
            }
        }
    }

    public void Write(string name, string value)
    {
        lock (_lock)
        {
            Directory.CreateDirectory(directory);
            var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser);
            var path = PathFor(name);
            var tmp = path + ".tmp";
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, path, overwrite: true);
        }
    }

    public void Delete(string name)
    {
        lock (_lock)
        {
            try { File.Delete(PathFor(name)); }
            catch (IOException) { }
        }
    }
}

/// <summary>For tests.</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = new();
    public string? Read(string name) { lock (_values) return _values.GetValueOrDefault(name); }
    public void Write(string name, string value) { lock (_values) _values[name] = value; }
    public void Delete(string name) { lock (_values) _values.Remove(name); }
    public IReadOnlyCollection<string> Names { get { lock (_values) return _values.Keys.ToList(); } }
}
