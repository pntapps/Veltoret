using System.Security.Cryptography;
using System.Text;
using Veltoret.Core.Pairing;

namespace Veltoret.Core.Tests.Pairing;

public class PairingCryptoTest
{
    private static readonly byte[] Message = Encoding.UTF8.GetBytes("{\"host\":\"192.168.0.10\",\"username\":\"me\",\"password\":\"p@ss w'rd\"}");

    [Fact]
    public void PhoneAndTvAgreeOnTheKeyAndTheMessageArrives()
    {
        using var tv = PairingCrypto.NewKeyPair();
        using var phone = PairingCrypto.NewKeyPair();
        var salt = PairingCrypto.NewSalt();
        var code = PairingCrypto.NewCode();
        // Keys travel as text, like over the network.
        var tvSeesPhone = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(phone));
        var phoneSeesTv = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(tv));

        var phoneKey = PairingCrypto.SessionKey(phone, phoneSeesTv, code, salt);
        var tvKey = PairingCrypto.SessionKey(tv, tvSeesPhone, code, salt);
        Assert.Equal(phoneKey, tvKey);
        Assert.Equal(32, phoneKey.Length);

        var aad = phone.PublicSpki;
        var sealedMessage = PairingCrypto.Seal(phoneKey, Message, aad);
        Assert.Equal(Message, PairingCrypto.Open(tvKey, sealedMessage, aad));
        // 12-byte nonce; ciphertext || 16-byte tag.
        Assert.Equal(12, Convert.FromBase64String(sealedMessage.Iv).Length);
        Assert.Equal(Message.Length + 16, Convert.FromBase64String(sealedMessage.Data).Length);
    }

    [Fact]
    public void AWrongCodeCannotOpenIt()
    {
        using var tv = PairingCrypto.NewKeyPair();
        using var phone = PairingCrypto.NewKeyPair();
        var salt = PairingCrypto.NewSalt();
        var tvPublic = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(tv));
        var phonePublic = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(phone));
        var sealedMessage = PairingCrypto.Seal(PairingCrypto.SessionKey(phone, tvPublic, "123456", salt), Message, phone.PublicSpki);
        Assert.Null(PairingCrypto.Open(PairingCrypto.SessionKey(tv, phonePublic, "123457", salt), sealedMessage, phone.PublicSpki));
    }

    [Fact]
    public void AnotherKeyPairCannotOpenIt()
    {
        using var tv = PairingCrypto.NewKeyPair();
        using var phone = PairingCrypto.NewKeyPair();
        using var eavesdropper = PairingCrypto.NewKeyPair();
        var salt = PairingCrypto.NewSalt();
        var tvPublic = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(tv));
        var phonePublic = PairingCrypto.DecodeKey(PairingCrypto.EncodeKey(phone));
        var sealedMessage = PairingCrypto.Seal(PairingCrypto.SessionKey(phone, tvPublic, "123456", salt), Message, phone.PublicSpki);
        Assert.Null(PairingCrypto.Open(PairingCrypto.SessionKey(eavesdropper, phonePublic, "123456", salt), sealedMessage, phone.PublicSpki));
    }

    [Fact]
    public void CodesAndTokensLookRight()
    {
        for (var i = 0; i < 50; i++)
        {
            var code = PairingCrypto.NewCode();
            Assert.Equal(6, code.Length);
            Assert.All(code, c => Assert.True(char.IsAsciiDigit(c)));
        }
        var token = PairingCrypto.NewToken();
        Assert.Equal(24, token.Length);
        Assert.DoesNotContain('+', token);
        Assert.DoesNotContain('/', token);
    }

    [Fact]
    public void PublicKeysAreNamedCurveSpki()
    {
        using var keys = PairingCrypto.NewKeyPair();
        // 91 bytes: SEQUENCE { AlgorithmIdentifier { id-ecPublicKey, prime256v1 }, BIT STRING 04 || X || Y }.
        Assert.Equal(91, keys.PublicSpki.Length);
        Assert.Equal(0x30, keys.PublicSpki[0]);
        Assert.Equal(0x04, keys.PublicSpki[26]);
        Assert.Equal(Convert.FromHexString("3059301306072A8648CE3D020106082A8648CE3D030107034200"), keys.PublicSpki[..26]);
    }

    /// <summary>
    /// Cross-check against an independent derivation of the same steps (raw ECDH X, PBKDF2-SHA256 120000, HMAC with
    /// the INFO string), so a change to any parameter is caught.
    /// </summary>
    [Fact]
    public void SessionKeyIsTheDocumentedConstruction()
    {
        using var a = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        using var b = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var salt = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
        var raw = a.DeriveRawSecretAgreement(b.PublicKey);
        var stretched = Rfc2898DeriveBytes.Pbkdf2("654321"u8.ToArray(), salt, 120_000, HashAlgorithmName.SHA256, 32);
        var expected = HMACSHA256.HashData(stretched, raw.Concat("veltoret-send-to-tv-v1"u8.ToArray()).ToArray());

        // Same key through PairingCrypto, importing 'a' via its private key.
        var aKeys = typeof(PairingKeys).GetConstructors(System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)[0]
            .Invoke(new object[] { a }) as PairingKeys;
        var actual = PairingCrypto.SessionKey(aKeys!, PairingCrypto.DecodeKey(Convert.ToBase64String(b.ExportSubjectPublicKeyInfo())), "654321", salt);
        Assert.Equal(expected, actual);
    }
}
