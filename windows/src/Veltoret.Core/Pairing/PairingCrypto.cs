using System.Security.Cryptography;
using System.Text;

namespace Veltoret.Core.Pairing;

/// <summary>
/// A fresh P-256 key pair for one pairing attempt. <see cref="PublicSpki"/> is the X.509 SubjectPublicKeyInfo
/// DER (named curve, uncompressed point): what goes on the wire, and the AAD when sealing.
/// </summary>
public sealed class PairingKeys : IDisposable
{
    internal ECDiffieHellman Ecdh { get; }
    public byte[] PublicSpki { get; }

    internal PairingKeys(ECDiffieHellman ecdh)
    {
        Ecdh = ecdh;
        PublicSpki = ecdh.ExportSubjectPublicKeyInfo();
    }

    public void Dispose() => Ecdh.Dispose();
}

/// <summary>Port of Android's PairingCrypto (WIRE): shared by "Play on TV" pairing and "Send to TV".</summary>
public static class PairingCrypto
{
    private const int CodeIterations = 120_000;
    private const string Info = "veltoret-send-to-tv-v1";

    public sealed record Sealed(string Iv, string Data);

    public static PairingKeys NewKeyPair() => new(ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256));

    /// <summary>Uniform over 100000..999999 (TV side; used by tests).</summary>
    public static string NewCode() => (RandomNumberGenerator.GetInt32(900_000) + 100_000).ToString();

    public static byte[] NewSalt() => RandomNumberGenerator.GetBytes(16);

    /// <summary>Base64(18 random bytes), URL-safe: 24 chars, no padding.</summary>
    public static string NewToken() => B64(RandomNumberGenerator.GetBytes(18)).Replace('+', '-').Replace('/', '_');

    public static string EncodeKey(PairingKeys keys) => B64(keys.PublicSpki);

    /// <summary>Decodes a Base64 SPKI public key (the TV's tvKey or a phone's phoneKey).</summary>
    public static ECDiffieHellmanPublicKey DecodeKey(string text)
    {
        // Not disposed: the returned public key may still refer to it.
        var other = ECDiffieHellman.Create();
        other.ImportSubjectPublicKeyInfo(Unb64(text), out _);
        return other.PublicKey;
    }

    /// <summary>
    /// HMAC-SHA256(PBKDF2-SHA256(code, salt, 120000, 32), rawEcdhX || "veltoret-send-to-tv-v1"): the AES-256 key
    /// both sides arrive at.
    /// </summary>
    public static byte[] SessionKey(PairingKeys own, ECDiffieHellmanPublicKey other, string code, byte[] salt)
    {
        var shared = own.Ecdh.DeriveRawSecretAgreement(other);
        var stretched = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(code), salt, CodeIterations, HashAlgorithmName.SHA256, 32);
        var data = new byte[shared.Length + Encoding.UTF8.GetByteCount(Info)];
        shared.CopyTo(data, 0);
        Encoding.UTF8.GetBytes(Info, 0, Info.Length, data, shared.Length);
        return HMACSHA256.HashData(stretched, data);
    }

    /// <summary>AES-256-GCM, 12-byte random nonce, 16-byte tag appended to the ciphertext (as Java does).</summary>
    public static Sealed Seal(byte[] key, byte[] plain, byte[] aad)
    {
        var iv = RandomNumberGenerator.GetBytes(12);
        var output = new byte[plain.Length + 16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(iv, plain, output.AsSpan(0, plain.Length), output.AsSpan(plain.Length), aad);
        return new Sealed(B64(iv), B64(output));
    }

    /// <summary>Null when the key is wrong (a wrong code) or the message was changed.</summary>
    public static byte[]? Open(byte[] key, Sealed sealedMessage, byte[] aad)
    {
        try
        {
            var iv = Unb64(sealedMessage.Iv);
            var data = Unb64(sealedMessage.Data);
            if (data.Length < 16) return null;
            var plain = new byte[data.Length - 16];
            using var gcm = new AesGcm(key, 16);
            gcm.Decrypt(iv, data.AsSpan(0, plain.Length), data.AsSpan(plain.Length), plain, aad);
            return plain;
        }
        catch (Exception e) when (e is CryptographicException or FormatException or ArgumentException)
        {
            return null;
        }
    }

    public static string B64(byte[] bytes) => Convert.ToBase64String(bytes);
    public static byte[] Unb64(string text) => Convert.FromBase64String(text);
}
