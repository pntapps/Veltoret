using System.Security.Cryptography;
using System.Text;
using Veltoret.Core.Pairing;

namespace Veltoret.Core.TvLink;

/// <summary>Constants and request signing of "Play on TV" (Android TvLink object, WIRE).</summary>
public static class TvLinkProtocol
{
    public const string ServiceType = "_veltoret-play._tcp";
    public const int Version = 1;
    public const string StreamScheme = "vlink";
    public const string HeaderPhone = "X-Veltoret-Phone";
    public const string HeaderTime = "X-Veltoret-Time";
    public const string HeaderSignature = "X-Veltoret-Signature";
    public const long MaxSkewMs = 5 * 60_000L;

    public static string NewSecret() => PairingCrypto.B64(RandomNumberGenerator.GetBytes(32));

    /// <summary>Base64(HMAC-SHA256(secret, UTF8("{method} {path} {time}\n") || body)).</summary>
    public static string Sign(string secret, string method, string path, long time, byte[] body)
    {
        var head = Encoding.UTF8.GetBytes($"{method} {path} {time}\n");
        var data = new byte[head.Length + body.Length];
        head.CopyTo(data, 0);
        body.CopyTo(data, head.Length);
        return PairingCrypto.B64(HMACSHA256.HashData(PairingCrypto.Unb64(secret), data));
    }

    /// <summary>Constant-time check of <paramref name="signature"/>, within <see cref="MaxSkewMs"/> of <paramref name="now"/>.</summary>
    public static bool Verify(string secret, string method, string path, long time, byte[] body, string signature, long now)
    {
        if (Math.Abs(now - time) > MaxSkewMs) return false;
        var expected = Sign(secret, method, path, time, body);
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(signature));
    }

    /// <summary>"vlink://host:port/token/id" for "http://host:port/token/id".</summary>
    public static string StreamUrl(string httpUrl) =>
        StreamScheme + (httpUrl.StartsWith("http", StringComparison.Ordinal) ? httpUrl["http".Length..] : httpUrl);

    public static bool IsStream(string fileId) => fileId.StartsWith(StreamScheme + "://", StringComparison.Ordinal);
}
