using System.Text.Json;
using Veltoret.Core.Cast;
using Veltoret.Core.Pairing;

namespace Veltoret.Core.TvLink;

/// <summary>
/// This PC's half of "Play on TV" (Android TvLinkClient): finds Veltoret TVs on the network, pairs with the code
/// the TV shows, and sends signed requests over plain HTTP/1.1 sockets (WIRE §0.2).
/// </summary>
public sealed class TvLinkClient(TvLinkStore store, Func<string>? phoneName = null)
{
    public TvLinkStore Store => store;

    /// <summary>The name the TV shows while pairing.</summary>
    public string PhoneName => phoneName?.Invoke() is { Length: > 0 } n ? n : Environment.MachineName;

    /// <summary>Veltoret TVs as they're found (each answers /hello first) during <paramref name="window"/>.</summary>
    public async IAsyncEnumerable<LinkTv> Find(TimeSpan window,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        var seen = new HashSet<string>();
        await foreach (var service in Mdns.Browse(TvLinkProtocol.ServiceType, window, ct))
        {
            if (service.Address == null || service.Port == 0) continue;
            var host = service.Address.ToString();
            LinkHello? hello = null;
            try { hello = await Hello(host, service.Port, ct); }
            catch (Exception e) when (e is IOException or JsonException) { }
            if (hello == null || hello.Id.Length == 0) continue;
            var key = $"{hello.Id}|{host}|{service.Port}";
            if (!seen.Add(key)) continue;
            yield return new LinkTv(hello.Id, hello.Name, host, service.Port, store.Secret(hello.Id) != null);
        }
    }

    public async Task<LinkHello> Hello(string host, int port, CancellationToken ct = default)
    {
        var reply = await LinkHttp.Exchange(host, port, "GET", "/hello", null, null, 4_000, 3_000, ct);
        if (reply.Status != 200) throw new IOException($"HTTP {reply.Status}");
        return LinkJson.Decode<LinkHello>(reply.Body);
    }

    // ---- Pairing ------------------------------------------------------------------------------------

    /// <summary>Asks <paramref name="tv"/> to show a pairing code. Throws <see cref="LinkException"/> when it can't.</summary>
    public async Task StartPairing(LinkTv tv, CancellationToken ct = default)
    {
        var reply = await Call(tv, "/pair/start", new LinkPairStart { PhoneId = store.DeviceId, PhoneName = PhoneName }, signed: false, 8_000, ct);
        if (!reply.Ok) throw new LinkException(reply.Message, reply.Code);
    }

    /// <summary>Sends a new secret sealed with <paramref name="code"/>; on success the TV is remembered as paired.</summary>
    public async Task Pair(LinkTv tv, string code, CancellationToken ct = default)
    {
        LinkHello hello;
        try { hello = await Hello(tv.Host, tv.Port, ct); }
        catch (Exception e) when (e is IOException or JsonException)
        {
            throw new LinkException($"Couldn't reach {tv.Name}. Check it's on and on the same Wi-Fi.");
        }
        using var keys = PairingCrypto.NewKeyPair();
        var key = PairingCrypto.SessionKey(keys, PairingCrypto.DecodeKey(hello.TvKey), code.Trim(), PairingCrypto.Unb64(hello.Salt));
        var secret = TvLinkProtocol.NewSecret();
        var plain = LinkJson.Encode(new LinkPairSecret { PhoneId = store.DeviceId, PhoneName = PhoneName, Secret = secret });
        var sealedMessage = PairingCrypto.Seal(key, plain, keys.PublicSpki);
        var message = new PairMessage { PhoneKey = PairingCrypto.EncodeKey(keys), Iv = sealedMessage.Iv, Data = sealedMessage.Data };
        var reply = await Call(tv, "/pair", message, signed: false, 15_000, ct);
        if (!reply.Ok) throw new LinkException(reply.Message, reply.Code);
        store.Save(new LinkPeer(hello.Id, hello.Name), secret);
    }

    public void Forget(string tvId) => store.Remove(tvId);

    // ---- Playback -----------------------------------------------------------------------------------

    /// <summary>Plays <paramref name="request"/>; returns where it plays from (<see cref="LinkStatus.SourceTv"/> or SourcePhone).</summary>
    public async Task<string> Play(LinkTv tv, LinkPlay request, CancellationToken ct = default)
    {
        var reply = await Call(tv, "/play", request, signed: true, 15_000, ct);
        if (!reply.Ok) throw new LinkException(reply.Message, reply.Code);
        return reply.Message;
    }

    public async Task Command(LinkTv tv, LinkCommand command, CancellationToken ct = default)
    {
        var reply = await Call(tv, "/command", command, signed: true, 8_000, ct);
        if (!reply.Ok) throw new LinkException(reply.Message, reply.Code);
    }

    public async Task<LinkStatus> Status(LinkTv tv, CancellationToken ct = default)
    {
        var body = await Request(tv, "/status", Array.Empty<byte>(), signed: true, 5_000, ct);
        try { return LinkJson.Decode<LinkStatus>(body); }
        catch (JsonException) { throw new LinkException($"{tv.Name} couldn't do that"); }
    }

    private async Task<LinkReply> Call<T>(LinkTv tv, string path, T value, bool signed, int timeout, CancellationToken ct)
    {
        var body = await Request(tv, path, LinkJson.Encode(value), signed, timeout, ct);
        try { return LinkJson.Decode<LinkReply>(body); }
        catch (JsonException) { throw new LinkException($"{tv.Name} couldn't do that"); }
    }

    /// <summary>POSTs <paramref name="body"/>; returns the response body, or throws <see cref="LinkException"/> with the TV's message.</summary>
    private async Task<string> Request(LinkTv tv, string path, byte[] body, bool signed, int timeout, CancellationToken ct)
    {
        List<KeyValuePair<string, string>>? headers = null;
        if (signed)
        {
            var secret = store.Secret(tv.Id) ?? throw new LinkException($"Pair this PC with {tv.Name} first", "unpaired");
            var time = NextTime();
            headers = new()
            {
                new(TvLinkProtocol.HeaderPhone, store.DeviceId),
                new(TvLinkProtocol.HeaderTime, time.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                new(TvLinkProtocol.HeaderSignature, TvLinkProtocol.Sign(secret, "POST", path, time, body)),
            };
        }
        LinkHttp.Reply reply;
        try
        {
            reply = await LinkHttp.Exchange(tv.Host, tv.Port, "POST", path, body, headers, 4_000, timeout, ct);
        }
        catch (IOException)
        {
            throw new LinkException($"Couldn't reach {tv.Name}. Check it's on and on the same Wi-Fi.");
        }
        if (reply.Status == 200) return reply.Body;
        var refused = LinkJson.TryDecode<LinkReply>(reply.Body);
        if (refused?.Code == "unpaired") store.Remove(tv.Id);
        throw new LinkException(string.IsNullOrEmpty(refused?.Message) ? $"{tv.Name} couldn't do that (HTTP {reply.Status})" : refused!.Message, refused?.Code);
    }

    private static long _lastTime;

    /// <summary>A fresh millisecond per request: the TV refuses a signature it has seen (replay protection).</summary>
    private static long NextTime()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        while (true)
        {
            var last = Interlocked.Read(ref _lastTime);
            var next = Math.Max(now, last + 1);
            if (Interlocked.CompareExchange(ref _lastTime, next, last) == last) return next;
        }
    }
}
