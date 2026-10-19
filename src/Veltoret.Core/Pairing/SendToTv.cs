using Veltoret.Core.Cast;

namespace Veltoret.Core.Pairing;

/// <summary>GET /pair on a TV showing "Use your phone" (WIRE).</summary>
public sealed record PairOffer
{
    public string TvKey { get; init; } = "";
    public string Salt { get; init; } = "";
    public string Name { get; init; } = "";
}

/// <summary>POST /pair (and TvLink /pair): the sealed message (WIRE).</summary>
public sealed record PairMessage
{
    public string PhoneKey { get; init; } = "";
    public string Iv { get; init; } = "";
    public string Data { get; init; } = "";
}

/// <summary>A saved network server handed to the TV (WIRE). Never log or persist it.</summary>
public sealed record PhoneSubmission
{
    public string Address { get; init; } = "";
    public bool Guest { get; init; }
    public string Username { get; init; } = "";
    public string Password { get; init; } = "";
    public string? Name { get; init; }
}

public sealed record SetupReply
{
    public bool Ok { get; init; }
    public string Message { get; init; } = "";
}

/// <summary>A TV showing Veltoret's "Use your phone" panel.</summary>
public sealed record FoundTv(string Name, string Host, int Port);

/// <summary>
/// "Send to TV" (Android SendToTv): finds TVs showing "Use your phone" and sends one saved network server,
/// sealed with the code the TV shows. This PC plays the phone's part.
/// </summary>
public static class SendToTv
{
    public const string ServiceType = "_veltoret._tcp";

    /// <summary>
    /// TVs as they answer (one entry per host; a newer answer replaces an older one). Search ~8 s before showing
    /// "No TV found".
    /// </summary>
    public static async IAsyncEnumerable<FoundTv> Find(TimeSpan window,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var service in Mdns.Browse(ServiceType, window, ct))
        {
            if (service.Address == null || service.Port == 0) continue;
            var host = service.Address.ToString();
            PairOffer? offer = null;
            try { offer = await Offer(host, service.Port, 3_000, ct); }
            catch (Exception e) when (e is IOException or System.Text.Json.JsonException) { }
            if (offer != null) yield return new FoundTv(offer.Name, host, service.Port);
        }
    }

    private static async Task<PairOffer> Offer(string host, int port, int timeout, CancellationToken ct)
    {
        var reply = await LinkHttp.Exchange(host, port, "GET", "/pair", null, null, timeout, timeout, ct);
        if (reply.Status != 200) throw new IOException($"HTTP {reply.Status}");
        return LinkJson.Decode<PairOffer>(reply.Body);
    }

    /// <summary>Sends <paramref name="submission"/>; the TV's answer, or a sentence about what went wrong.</summary>
    public static async Task<SetupReply> Send(FoundTv tv, string code, PhoneSubmission submission, CancellationToken ct = default)
    {
        PairOffer offer;
        try
        {
            offer = await Offer(tv.Host, tv.Port, 5_000, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return new SetupReply { Ok = false, Message = "Couldn't reach the TV. Check it's on the same Wi-Fi and still showing \"Use your phone\"." };
        }
        try
        {
            using var keys = PairingCrypto.NewKeyPair();
            var key = PairingCrypto.SessionKey(keys, PairingCrypto.DecodeKey(offer.TvKey), code.Trim(), PairingCrypto.Unb64(offer.Salt));
            var sealedMessage = PairingCrypto.Seal(key, LinkJson.Encode(submission), keys.PublicSpki);
            var message = new PairMessage { PhoneKey = PairingCrypto.EncodeKey(keys), Iv = sealedMessage.Iv, Data = sealedMessage.Data };
            // The TV answers only after trying the server, which can take up to a minute.
            var reply = await LinkHttp.Exchange(tv.Host, tv.Port, "POST", "/pair", LinkJson.Encode(message), null, 5_000, 75_000, ct);
            return LinkJson.Decode<SetupReply>(reply.Body);
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return new SetupReply { Ok = false, Message = "The TV stopped answering. Check it's still showing \"Use your phone\" and try again." };
        }
    }

    /// <summary>The username the TV expects: "domain\user" when there is a domain.</summary>
    public static string Username(string domain, string user) => string.IsNullOrEmpty(domain) ? user : domain + "\\" + user;
}
