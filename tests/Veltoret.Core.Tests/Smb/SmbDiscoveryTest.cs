using System.Net;
using System.Text;
using Veltoret.Core.Smb;

namespace Veltoret.Core.Tests.Smb;

public class SmbDiscoveryTest
{
    private static int Ip(int a, int b, int c, int d) => (a << 24) | (b << 16) | (c << 8) | d;

    [Fact]
    public void SweepsTheSubnetWithoutNetworkAndBroadcast()
    {
        var hosts = SmbDiscovery.SubnetHosts(Ip(192, 168, 0, 57), 24);
        Assert.Equal(254, hosts.Count);
        Assert.Equal("192.168.0.1", SmbDiscovery.FromInt(hosts.First()));
        Assert.Equal("192.168.0.254", SmbDiscovery.FromInt(hosts.Last()));
    }

    [Fact]
    public void HugeNetworksFallBackToTheNearby254()
    {
        var hosts = SmbDiscovery.SubnetHosts(Ip(10, 1, 2, 3), 8);
        Assert.Equal(254, hosts.Count);
        Assert.Equal("10.1.2.1", SmbDiscovery.FromInt(hosts.First()));
        Assert.Equal(1022, SmbDiscovery.SubnetHosts(Ip(10, 1, 2, 3), 22).Count);
    }

    [Fact]
    public void IntConversionRoundTrips()
    {
        Assert.Equal(Ip(192, 168, 1, 200), SmbDiscovery.ToInt(IPAddress.Parse("192.168.1.200")));
        Assert.Equal("192.168.1.200", SmbDiscovery.FromInt(Ip(192, 168, 1, 200)));
    }

    [Fact]
    public void QueryAsksForTheWildcardName()
    {
        var q = NetBios.NodeStatusQuery(0x1234);
        Assert.Equal(50, q.Length);
        Assert.Equal(0x12, q[0]);
        Assert.Equal(32, q[12]);
        Assert.Equal("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", Encoding.ASCII.GetString(q, 13, 32));
        Assert.Equal(0x21, q[47]);
    }

    /// <summary>A node status answer listing <paramref name="names"/> as (name, suffix, group).</summary>
    private static byte[] Answer(params (string Name, int Suffix, bool Group)[] names)
    {
        var o = new MemoryStream();
        o.Write(new byte[12]);
        o.WriteByte(32);
        o.Write(Enumerable.Repeat((byte)'A', 32).ToArray());
        o.WriteByte(0);
        o.Write(new byte[] { 0, 0x21, 0, 1, 0, 0, 0, 0, 0, 0 }); // type, class, TTL, length
        o.WriteByte((byte)names.Length);
        foreach (var (name, suffix, group) in names)
        {
            o.Write(Encoding.ASCII.GetBytes(name.PadRight(15)));
            o.WriteByte((byte)suffix);
            o.WriteByte(group ? (byte)0x80 : (byte)0x04);
            o.WriteByte(0);
        }
        return o.ToArray();
    }

    [Fact]
    public void ReadsTheFileServerName()
    {
        var reply = Answer(("WORKGROUP", 0x00, true), ("ROUTER-AX", 0x00, false), ("ROUTER-AX", 0x20, false));
        Assert.Equal("ROUTER-AX", NetBios.ParseNodeStatus(reply));
    }

    [Fact]
    public void FallsBackToTheWorkstationNameAndIgnoresGroups()
    {
        Assert.Equal("NAS", NetBios.ParseNodeStatus(Answer(("HOME", 0x20, true), ("NAS", 0x00, false))));
        Assert.Null(NetBios.ParseNodeStatus(Answer(("WORKGROUP", 0x00, true))));
        Assert.Null(NetBios.ParseNodeStatus(new byte[5]));
    }

    [Fact]
    public void EntriesPastTheReceivedLengthAreSkipped()
    {
        var reply = Answer(("NAS", 0x00, false), ("NAS", 0x20, false));
        // Cut the second entry off: only the first (workstation) name is readable.
        Assert.Equal("NAS", NetBios.ParseNodeStatus(reply, reply.Length - 18));
    }
}
