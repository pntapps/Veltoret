using Veltoret.Core.Smb;

namespace Veltoret.Core.Tests.Smb;

public class SmbServerStoreTest : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "veltoret-smb-test-" + Guid.NewGuid().ToString("N"));
    private string FilePath => Path.Combine(_dir, "smb_servers.json");

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    [Fact]
    public void SavesServersAndEncryptsPasswords()
    {
        var store = new SmbServerStore(FilePath);
        store.Save(new SmbServer { Host = "NAS", Username = "me", Domain = "HOME", Name = "MYNAS" }, "s3cret pass");

        var server = store.Server("smb://nas")!;
        Assert.Equal("nas", server.Host);
        Assert.Equal("MYNAS", server.Name);
        Assert.Equal("HOME", server.Domain);
        Assert.False(server.Guest);
        Assert.Equal("s3cret pass", store.Password("smb://nas"));
        Assert.DoesNotContain("s3cret", File.ReadAllText(FilePath));

        // A fresh store reads the same file back.
        var again = new SmbServerStore(FilePath);
        Assert.Equal("s3cret pass", again.Password("smb://nas"));
        Assert.Single(again.Servers);
    }

    [Fact]
    public void GuestHasAnEmptyPasswordAndRemoveForgetsIt()
    {
        var store = new SmbServerStore(FilePath);
        store.Save(new SmbServer { Host = "192.168.0.1", Name = "ROUTER-AX" }, "");
        Assert.True(store.Server("smb://192.168.0.1")!.Guest);
        Assert.Equal("", store.Password("smb://192.168.0.1"));

        store.Remove("smb://192.168.0.1");
        Assert.Null(store.Server("smb://192.168.0.1"));
        Assert.Null(store.Password("smb://192.168.0.1"));
        Assert.Empty(new SmbServerStore(FilePath).Servers);
    }

    [Fact]
    public void UnreadablePasswordMeansSignInAgain()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(FilePath, """{ "servers": [ { "host": "nas", "port": 445, "username": "me", "domain": "", "name": "nas", "password": "bm90LWRwYXBp" } ] }""");
        var store = new SmbServerStore(FilePath);
        Assert.NotNull(store.Server("smb://nas"));
        Assert.Null(store.Password("smb://nas"));
    }

    [Fact]
    public void ErrorsAreWordedForPeople()
    {
        Assert.Equal("Wrong username or password",
            SmbErrors.Describe(new SmbStatusException(SMBLibrary.NTStatus.STATUS_LOGON_FAILURE, "Sign in")));
        Assert.Equal("That folder or file isn't on the server any more",
            SmbErrors.Describe(new IOException("x", new SmbStatusException(SMBLibrary.NTStatus.STATUS_OBJECT_PATH_NOT_FOUND, "Open"))));
        Assert.Equal("Couldn't find that server on your network. Check the address.",
            SmbErrors.Describe(new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.HostNotFound)));
        Assert.Equal("Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi.",
            SmbErrors.Describe(new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.ConnectionRefused)));
        Assert.Equal("Something went wrong talking to the server", SmbErrors.Describe(new Exception("")));
    }

    [Fact]
    public void MimeTypesFromExtensions()
    {
        Assert.Equal("video/x-matroska", SmbMime.For("Heat (1995).MKV"));
        Assert.Equal("application/octet-stream", SmbMime.For("README"));
    }
}
