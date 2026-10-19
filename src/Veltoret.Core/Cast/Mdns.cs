using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using Makaretu.Dns;

namespace Veltoret.Core.Cast;

/// <summary>A resolved DNS-SD service instance. <see cref="Address"/> is the first IPv4 address.</summary>
public sealed record MdnsService(string Instance, IPAddress? Address, int Port, IReadOnlyDictionary<string, string> Txt)
{
    public string? TxtValue(string key) => Txt.TryGetValue(key, out var v) ? v : null;
}

/// <summary>
/// DNS-SD browsing over multicast DNS (Makaretu.Dns.Multicast): PTR for the service type, then SRV / TXT / A for
/// each instance. Emits an instance whenever it becomes resolvable or its records change.
/// </summary>
public static class Mdns
{
    private sealed class Instance
    {
        public required DomainName Name;
        public string? Target;
        public int Port;
        public Dictionary<string, string>? Txt;
        public IPAddress? Address;
        public string? Emitted;
    }

    /// <param name="serviceType">"_googlecast._tcp" (with or without the trailing dot / ".local").</param>
    public static async IAsyncEnumerable<MdnsService> Browse(string serviceType, TimeSpan window,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        var type = serviceType.TrimEnd('.');
        if (!type.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) type += ".local";
        var typeName = new DomainName(type);
        var channel = Channel.CreateUnbounded<MdnsService>();
        var gate = new object();
        var instances = new Dictionary<string, Instance>(StringComparer.OrdinalIgnoreCase);
        var addresses = new Dictionary<string, IPAddress>(StringComparer.OrdinalIgnoreCase);

        MulticastService mdns;
        try
        {
            mdns = new MulticastService(null) { UseIpv6 = false, IgnoreDuplicateMessages = false };
        }
        catch (Exception)
        {
            yield break;
        }

        void Query(DomainName name, DnsType t)
        {
            try { mdns.SendQuery(name, DnsClass.IN, t); } catch (Exception) { /* network went away */ }
        }

        void Resolve(bool force)
        {
            List<(DomainName, DnsType)> queries = new();
            lock (gate)
            {
                foreach (var inst in instances.Values)
                {
                    if (inst.Target == null) queries.Add((inst.Name, DnsType.SRV));
                    if (inst.Txt == null) queries.Add((inst.Name, DnsType.TXT));
                    if (inst.Target != null && inst.Address == null) queries.Add((new DomainName(inst.Target), DnsType.A));
                }
            }
            if (force || queries.Count > 0)
                foreach (var (n, t) in queries) Query(n, t);
        }

        void OnAnswer(object? sender, MessageEventArgs e)
        {
            var records = e.Message.Answers.Concat(e.Message.AdditionalRecords).ToList();
            var ready = new List<MdnsService>();
            lock (gate)
            {
                foreach (var r in records)
                    if (r is PTRRecord ptr && r.Name == typeName && !instances.ContainsKey(ptr.DomainName.ToString()))
                        instances[ptr.DomainName.ToString()] = new Instance { Name = ptr.DomainName };
                foreach (var r in records)
                {
                    switch (r)
                    {
                        case SRVRecord srv when instances.TryGetValue(r.Name.ToString(), out var i):
                            i.Target = srv.Target.ToString();
                            i.Port = srv.Port;
                            break;
                        case TXTRecord txt when instances.TryGetValue(r.Name.ToString(), out var i):
                            i.Txt = ParseTxt(txt.Strings);
                            break;
                        case ARecord a when a.Address.AddressFamily == AddressFamily.InterNetwork:
                            addresses[r.Name.ToString()] = a.Address;
                            break;
                    }
                }
                foreach (var i in instances.Values)
                {
                    if (i.Target != null && addresses.TryGetValue(i.Target, out var address)) i.Address = address;
                    // Some responders put the address straight into the SRV's own answer set.
                    if (i.Address == null || i.Port == 0) continue;
                    var key = $"{i.Address}:{i.Port}:{string.Join(";", (i.Txt ?? new()).Select(kv => kv.Key + "=" + kv.Value))}";
                    if (key == i.Emitted) continue;
                    i.Emitted = key;
                    ready.Add(new MdnsService(i.Name.Labels.Count > 0 ? i.Name.Labels[0] : i.Name.ToString(), i.Address, i.Port,
                        i.Txt ?? new Dictionary<string, string>()));
                }
            }
            foreach (var s in ready) channel.Writer.TryWrite(s);
            Resolve(force: false);
        }

        mdns.AnswerReceived += OnAnswer;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        stop.CancelAfter(window);
        try
        {
            mdns.Start();
        }
        catch (Exception)
        {
            mdns.AnswerReceived -= OnAnswer;
            mdns.Dispose();
            yield break;
        }

        // Ask again now and then: responders that missed the first query (or were busy) answer later.
        var pump = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    Query(typeName, DnsType.PTR);
                    Resolve(force: true);
                    await Task.Delay(1_500, stop.Token);
                }
            }
            catch (OperationCanceledException) { }
            finally { channel.Writer.TryComplete(); }
        });

        try
        {
            while (true)
            {
                MdnsService item;
                try
                {
                    if (!await channel.Reader.WaitToReadAsync(CancellationToken.None)) break;
                    if (!channel.Reader.TryRead(out item!)) continue;
                }
                catch (ChannelClosedException) { break; }
                yield return item;
            }
        }
        finally
        {
            stop.Cancel();
            mdns.AnswerReceived -= OnAnswer;
            try { mdns.Stop(); } catch (Exception) { }
            mdns.Dispose();
            try { await pump; } catch (Exception) { }
        }
    }

    /// <summary>"fn=Living Room" → fn: Living Room. Keys are lowercased (DNS-SD keys are case-insensitive).</summary>
    public static Dictionary<string, string> ParseTxt(IEnumerable<string> strings)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in strings)
        {
            var eq = s.IndexOf('=');
            if (eq <= 0) { if (s.Length > 0) map.TryAdd(s, ""); continue; }
            map.TryAdd(s[..eq], s[(eq + 1)..]);
        }
        return map;
    }
}
