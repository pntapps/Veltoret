using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Makaretu.Dns;

namespace Veltoret.Core.Smb;

/// <summary>A file-sharing server found on the local network. <see cref="Name"/> is what it calls itself, when it says.</summary>
public sealed record FoundServer(string Address, string? Name, bool IsRouter = false);

/// <summary>
/// Finds SMB servers on the Wi-Fi/Ethernet network, for people who don't know their server's address (port of
/// Android's SmbDiscovery). Two ways at once:
/// - servers that announce themselves (DNS-SD "_smb._tcp": NAS boxes, Macs, many Linux machines);
/// - a sweep of the local subnet for anything accepting file-sharing connections (TCP 445), which finds routers
///   with a USB drive and Windows PCs that don't announce. Each hit is asked its NetBIOS name.
/// Results stream in as they're found; the sequence completes when both are done.
/// </summary>
public sealed class SmbDiscovery
{
    private const string ServiceType = "_smb._tcp";
    private const int SweepParallelism = 64;
    private const int ConnectTimeoutMs = 400;
    private const int NetBiosTimeoutMs = 700;
    private const int ResolveTimeoutMs = 3_000;
    private const int AnnounceWindowMs = 5_000;
    /// <summary>Never sweep more than a /22 (1022 addresses); bigger networks fall back to the /24 around us.</summary>
    private const int MinPrefix = 22;

    public async IAsyncEnumerable<FoundServer> Discover([EnumeratorCancellation] CancellationToken ct = default)
    {
        var network = LocalNetwork();
        if (network == null) yield break;
        var channel = Channel.CreateUnbounded<FoundServer>();
        var announced = Task.Run(() => Announced(server => channel.Writer.TryWrite(server), ct), ct);
        var swept = Task.Run(() => Sweep(network, server => channel.Writer.TryWrite(server), ct), ct);
        _ = Task.WhenAll(announced, swept).ContinueWith(_ => channel.Writer.TryComplete(), TaskScheduler.Default);
        await foreach (var server in channel.Reader.ReadAllAsync(ct)) yield return server;
    }

    /// <summary>The machine's own name (e.g. "MYNAS") for an address someone typed; null if it doesn't answer.</summary>
    public Task<string?> NameOf(string address, CancellationToken ct = default) => NetBiosName(address, ct);

    // ---------------------------------------------------------------------------------------------

    internal sealed record Network(int OwnAddress, int Prefix, string? Gateway);

    private static readonly string[] VirtualAdapterWords =
        { "hyper-v", "virtual", "vmware", "virtualbox", "vethernet", "wsl", "vpn", "tap-", "tunnel", "loopback", "bluetooth", "npcap", "docker" };

    /// <summary>The Wi-Fi or Ethernet network's IPv4 address and gateway; null with no such network.</summary>
    internal static Network? LocalNetwork()
    {
        var candidates = new List<(Network Net, bool HasGateway)>();
        NetworkInterface[] nics;
        try { nics = NetworkInterface.GetAllNetworkInterfaces(); }
        catch { return null; }
        foreach (var nic in nics)
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType is not (NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet
                or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx
                or NetworkInterfaceType.Ethernet3Megabit)) continue;
            var label = (nic.Name + " " + nic.Description).ToLowerInvariant();
            if (VirtualAdapterWords.Any(label.Contains)) continue;
            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch { continue; }
            var v4 = props.UnicastAddresses.FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IsLinkLocal(a.Address));
            if (v4 == null) continue;
            var gateway = props.GatewayAddresses
                .Select(g => g.Address)
                .FirstOrDefault(g => g.AddressFamily == AddressFamily.InterNetwork && !g.Equals(IPAddress.Any));
            candidates.Add((new Network(ToInt(v4.Address), v4.PrefixLength, gateway?.ToString()), gateway != null));
        }
        // The interface with a default gateway is the one the PC actually uses (Android: the active network).
        return candidates.OrderByDescending(c => c.HasGateway).Select(c => c.Net).FirstOrDefault();
    }

    private static bool IsLinkLocal(IPAddress a)
    {
        var b = a.GetAddressBytes();
        return b[0] == 169 && b[1] == 254;
    }

    private static async Task Sweep(Network network, Action<FoundServer> emit, CancellationToken ct)
    {
        using var permits = new SemaphoreSlim(SweepParallelism);
        var tasks = new List<Task>();
        foreach (var host in SubnetHosts(network.OwnAddress, network.Prefix))
        {
            if (host == network.OwnAddress) continue;
            tasks.Add(Task.Run(async () =>
            {
                await permits.WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    var address = FromInt(host);
                    if (await AcceptsSmb(address, ct).ConfigureAwait(false))
                        emit(new FoundServer(address, await NetBiosName(address, ct).ConfigureAwait(false), address == network.Gateway));
                }
                finally
                {
                    permits.Release();
                }
            }, ct));
        }
        try { await Task.WhenAll(tasks).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    private static async Task<bool> AcceptsSmb(string address, CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(ConnectTimeoutMs);
            using var client = new TcpClient(AddressFamily.InterNetwork);
            await client.ConnectAsync(IPAddress.Parse(address), 445, cts.Token).ConfigureAwait(false);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<string?> NetBiosName(string address, CancellationToken ct)
    {
        try
        {
            if (!IPAddress.TryParse(address, out var ip))
                ip = (await Dns.GetHostAddressesAsync(address, AddressFamily.InterNetwork, ct).ConfigureAwait(false)).First();
            using var udp = new UdpClient(AddressFamily.InterNetwork);
            var query = NetBios.NodeStatusQuery((int)(System.Diagnostics.Stopwatch.GetTimestamp() & 0x7FFF));
            await udp.SendAsync(query, new IPEndPoint(ip, NetBios.Port), ct).ConfigureAwait(false);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(NetBiosTimeoutMs);
            var reply = await udp.ReceiveAsync(cts.Token).ConfigureAwait(false);
            var buffer = reply.Buffer.Length > 1024 ? reply.Buffer[..1024] : reply.Buffer;
            return NetBios.ParseNodeStatus(buffer, buffer.Length);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Servers announcing "_smb._tcp" over multicast DNS, for <see cref="AnnounceWindowMs"/>.</summary>
    private static async Task Announced(Action<FoundServer> emit, CancellationToken ct)
    {
        MulticastService? mdns = null;
        ServiceDiscovery? sd = null;
        var resolving = new SemaphoreSlim(1); // one resolve at a time, like Android
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new List<Task>();
        try
        {
            mdns = new MulticastService(nics => nics) { UseIpv6 = false };
            sd = new ServiceDiscovery(mdns);
            var serviceDomain = new DomainName(ServiceType + ".local");
            sd.ServiceInstanceDiscovered += (_, e) =>
            {
                var instance = e.ServiceInstanceName;
                if (!instance.IsSubdomainOf(serviceDomain)) return;
                lock (seen) if (!seen.Add(instance.ToString())) return;
                var from = e.RemoteEndPoint?.Address;
                var task = Task.Run(async () =>
                {
                    await resolving.WaitAsync(ct).ConfigureAwait(false);
                    try
                    {
                        var address = await Resolve(mdns, instance, e.Message, ct).ConfigureAwait(false);
                        if (address == null && from != null && from.AddressFamily == AddressFamily.InterNetwork) address = from.ToString();
                        if (address != null) emit(new FoundServer(address, instance.Labels.Count > 0 ? instance.Labels[0] : null));
                    }
                    catch { }
                    finally { resolving.Release(); }
                }, ct);
                lock (pending) pending.Add(task);
            };
            mdns.Start();
            sd.QueryServiceInstances(ServiceType);
            await Task.Delay(AnnounceWindowMs, ct).ConfigureAwait(false);
        }
        catch
        {
            // Browsing couldn't start (or was cancelled): this half ends quietly.
        }
        finally
        {
            Task[] left;
            lock (pending) left = pending.ToArray();
            try { await Task.WhenAll(left).WaitAsync(TimeSpan.FromMilliseconds(ResolveTimeoutMs + 500)).ConfigureAwait(false); } catch { }
            try { sd?.Dispose(); } catch { }
            try { mdns?.Stop(); mdns?.Dispose(); } catch { }
        }
    }

    private static async Task<string?> Resolve(MulticastService mdns, DomainName instance, Message? announcement, CancellationToken ct)
    {
        string? FromRecords(IEnumerable<ResourceRecord> records)
        {
            var list = records.ToList();
            var srv = list.OfType<SRVRecord>().FirstOrDefault(r => r.Name == instance);
            if (srv == null) return null;
            return list.OfType<ARecord>().FirstOrDefault(a => a.Name == srv.Target)?.Address.ToString();
        }

        if (announcement != null)
        {
            var quick = FromRecords(announcement.Answers.Concat(announcement.AdditionalRecords));
            if (quick != null) return quick;
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(ResolveTimeoutMs);
        try
        {
            var query = new Message();
            query.Questions.Add(new Question { Name = instance, Type = DnsType.SRV, Class = DnsClass.IN });
            var answer = await mdns.ResolveAsync(query, cts.Token).ConfigureAwait(false);
            var records = answer.Answers.Concat(answer.AdditionalRecords).ToList();
            var found = FromRecords(records);
            if (found != null) return found;
            var srv = records.OfType<SRVRecord>().FirstOrDefault();
            if (srv == null) return null;
            var aQuery = new Message();
            aQuery.Questions.Add(new Question { Name = srv.Target, Type = DnsType.A, Class = DnsClass.IN });
            var aAnswer = await mdns.ResolveAsync(aQuery, cts.Token).ConfigureAwait(false);
            return aAnswer.Answers.Concat(aAnswer.AdditionalRecords).OfType<ARecord>().FirstOrDefault()?.Address.ToString();
        }
        catch
        {
            return null;
        }
    }

    // ---------------------------------------------------------------------------------------------

    /// <summary>The other addresses on our subnet (network and broadcast addresses left out).</summary>
    public static List<int> SubnetHosts(int own, int prefix)
    {
        var bits = prefix >= MinPrefix && prefix <= 30 ? prefix : 24;
        var mask = -1 << (32 - bits);
        var @base = own & mask;
        var size = 1 << (32 - bits);
        var hosts = new List<int>(size - 2);
        for (var i = 1; i < size - 1; i++) hosts.Add(@base + i);
        return hosts;
    }

    public static int ToInt(IPAddress address)
    {
        var b = address.GetAddressBytes();
        return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    }

    public static string FromInt(int ip) =>
        $"{(ip >>> 24) & 0xFF}.{(ip >>> 16) & 0xFF}.{(ip >>> 8) & 0xFF}.{ip & 0xFF}";
}
