using Veltoret.Core.Smb;

namespace Veltoret.Core.Tests.Smb;

public class SmbPathTest
{
    [Fact]
    public void ReadsWindowsPaths()
    {
        var p = SmbPath.FromUserInput("\\\\192.168.0.10\\h\\My Movies")!;
        Assert.Equal("192.168.0.10", p.Host);
        Assert.Equal("h", p.Share);
        Assert.Equal(new[] { "My Movies" }, p.Segments);
    }

    [Fact]
    public void ReadsOtherWaysPeopleTypeAddresses()
    {
        Assert.Equal(new SmbPath("nas", "Media", new[] { "Films" }), SmbPath.FromUserInput("smb://NAS/Media/Films/"));
        Assert.Equal(new SmbPath("192.168.0.10", "share", Array.Empty<string>()), SmbPath.FromUserInput(" 192.168.0.10/share "));
        Assert.Equal(new SmbPath("router", null, Array.Empty<string>()), SmbPath.FromUserInput("router"));
        Assert.Null(SmbPath.FromUserInput("   "));
        Assert.Null(SmbPath.FromUserInput("\\\\"));
    }

    [Fact]
    public void IdsRoundTrip()
    {
        var p = new SmbPath("192.168.0.10", "h", new[] { "Movies", "Heat (1995).mkv" });
        Assert.Equal("smb://192.168.0.10/h/Movies/Heat (1995).mkv", p.Id);
        Assert.Equal(p, SmbPath.Parse(p.Id));
        Assert.Equal("Movies\\Heat (1995).mkv", p.SharePath);
        Assert.Equal("Heat (1995).mkv", p.Name);
    }

    [Fact]
    public void WalksUpAndDown()
    {
        var server = SmbPath.Parse("smb://nas");
        Assert.Null(server.Share);
        Assert.Equal("", server.Child("Media").SharePath);
        Assert.Equal("smb://nas/Media/TV", server.Child("Media").Child("TV").Id);
        Assert.Equal("smb://nas/Media", SmbPath.Parse("smb://nas/Media/TV").Parent!.Id);
        Assert.Equal("smb://nas", SmbPath.Parse("smb://nas/Media").Parent!.Id);
        Assert.Null(server.Parent);
    }

    [Fact]
    public void AccountIsTheServer()
    {
        Assert.Equal("smb://nas", SmbPath.AccountOf(" NAS "));
        Assert.True(SmbPath.IsSmb("smb://nas/Media"));
        Assert.False(SmbPath.IsSmb("device"));
        Assert.False(SmbPath.IsSmb(null));
    }

    // Windows additions

    [Fact]
    public void HostIsLowercasedButNamesKeepTheirCase()
    {
        var p = SmbPath.Parse("smb://NAS/Media/Films");
        Assert.Equal("nas", p.Host);
        Assert.Equal("smb://nas/Media/Films", p.Id);
    }

    [Fact]
    public void UpperCaseSchemeIsNotStrippedFromInput()
    {
        // Android removes only the lowercase "smb:" prefix; "SMB://nas" keeps "SMB:" as the host.
        Assert.Equal("smb:", SmbPath.FromUserInput("SMB://nas/share")!.Host);
    }

    [Fact]
    public void UncForDisplay()
    {
        Assert.Equal("\\\\nas\\Media\\TV", SmbPath.Parse("smb://nas/Media/TV").Unc);
        Assert.Equal("\\\\nas", SmbPath.Parse("smb://nas").Unc);
    }
}
