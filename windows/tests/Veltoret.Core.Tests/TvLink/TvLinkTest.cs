using System.Net;
using System.Net.Sockets;
using System.Text;
using Veltoret.Core.Pairing;
using Veltoret.Core.TvLink;

namespace Veltoret.Core.Tests.TvLink;

public class TvLinkTest
{
    private readonly string _secret = TvLinkProtocol.NewSecret();
    private static readonly byte[] Body = Encoding.UTF8.GetBytes("{\"type\":\"pause\"}");

    [Fact]
    public void SignedRequestsVerify()
    {
        const long time = 1_000_000L;
        var signature = TvLinkProtocol.Sign(_secret, "POST", "/command", time, Body);
        Assert.Equal(44, signature.Length);
        Assert.True(TvLinkProtocol.Verify(_secret, "POST", "/command", time, Body, signature, now: time + 1_000));
    }

    [Fact]
    public void AnyChangeBreaksTheSignature()
    {
        const long time = 1_000_000L;
        var signature = TvLinkProtocol.Sign(_secret, "POST", "/command", time, Body);
        Assert.False(TvLinkProtocol.Verify(_secret, "POST", "/play", time, Body, signature, now: time));
        Assert.False(TvLinkProtocol.Verify(_secret, "POST", "/command", time + 1, Body, signature, now: time));
        Assert.False(TvLinkProtocol.Verify(_secret, "POST", "/command", time, Encoding.UTF8.GetBytes("{\"type\":\"stop\"}"), signature, now: time));
        Assert.False(TvLinkProtocol.Verify(TvLinkProtocol.NewSecret(), "POST", "/command", time, Body, signature, now: time));
    }

    [Fact]
    public void OldRequestsAreRefused()
    {
        const long time = 1_000_000L;
        var signature = TvLinkProtocol.Sign(_secret, "POST", "/status", time, Array.Empty<byte>());
        Assert.False(TvLinkProtocol.Verify(_secret, "POST", "/status", time, Array.Empty<byte>(), signature, now: time + TvLinkProtocol.MaxSkewMs + 1));
    }

    [Fact]
    public void StreamUrls()
    {
        Assert.Equal("vlink://192.168.1.20:4000/abc/v1", TvLinkProtocol.StreamUrl("http://192.168.1.20:4000/abc/v1"));
        Assert.True(TvLinkProtocol.IsStream("vlink://192.168.1.20:4000/abc/v1"));
        Assert.False(TvLinkProtocol.IsStream("content://media/external/video/1"));
    }

    [Fact]
    public void CanonicalStringIsExact()
    {
        // HMAC over "POST /command 1000000\n" + body, keyed with the decoded secret.
        var key = Convert.FromBase64String(_secret);
        var expected = Convert.ToBase64String(System.Security.Cryptography.HMACSHA256.HashData(key,
            Encoding.UTF8.GetBytes("POST /command 1000000\n").Concat(Body).ToArray()));
        Assert.Equal(expected, TvLinkProtocol.Sign(_secret, "POST", "/command", 1_000_000, Body));
    }

    [Fact]
    public void JsonFollowsKotlinRules()
    {
        // Nulls aren't written; names are camelCase.
        Assert.Equal("{\"type\":\"pause\"}", Encoding.UTF8.GetString(LinkJson.Encode(new LinkCommand { Type = LinkCommand.Pause })));
        Assert.Equal("{\"type\":\"subtitle\"}", Encoding.UTF8.GetString(LinkJson.Encode(new LinkCommand { Type = LinkCommand.Subtitle })));
        Assert.Equal("{\"type\":\"seek\",\"positionMs\":754000}", Encoding.UTF8.GetString(LinkJson.Encode(new LinkCommand { Type = LinkCommand.Seek, PositionMs = 754000 })));
        // The TV leaves out defaults: {} is an idle TV.
        var idle = LinkJson.Decode<LinkStatus>("{}");
        Assert.False(idle.Active);
        Assert.Empty(idle.Audio);
        Assert.Equal("", idle.Source);
        Assert.True(LinkJson.Decode<LinkStatus>("{\"ended\":true,\"unknown\":5}").Ended);
        var reply = LinkJson.Decode<LinkReply>("{\"ok\":true}");
        Assert.True(reply.Ok);
        Assert.Equal("", reply.Message);
        Assert.Null(reply.Code);
        var status = LinkJson.Decode<LinkStatus>("{\"active\":true,\"positionMs\":5,\"audio\":[{\"id\":\"a0\",\"label\":\"English\"}],\"audioSelected\":\"a0\"}");
        Assert.Equal("a0", status.Audio[0].Id);
        Assert.Equal("", status.Audio[0].Detail);
        var play = Encoding.UTF8.GetString(LinkJson.Encode(new LinkPlay { Title = "Heat", FileId = "smb://nas/h/Heat (1995).mkv", AccountEmail = "smb://nas", StartMs = 0 }));
        Assert.Equal("{\"title\":\"Heat\",\"fileId\":\"smb://nas/h/Heat (1995).mkv\",\"accountEmail\":\"smb://nas\",\"startMs\":0}", play);
    }

    [Fact]
    public void StoreKeepsSecretsAndDeviceId()
    {
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid() + ".json");
        try
        {
            var store = new TvLinkStore(path, s => "x" + s, s => s[1..]);
            var id = store.DeviceId;
            Assert.True(Guid.TryParse(id, out _));
            store.Save(new LinkPeer("tv1", "Living room"), "c2VjcmV0");
            var again = new TvLinkStore(path, s => "x" + s, s => s[1..]);
            Assert.Equal(id, again.DeviceId);
            Assert.Equal("c2VjcmV0", again.Secret("tv1"));
            Assert.Single(again.Peers);
            Assert.DoesNotContain("\"c2VjcmV0\"", File.ReadAllText(path));
            again.Remove("tv1");
            Assert.Null(again.Secret("tv1"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void DpapiStoreRoundTrips()
    {
        if (!OperatingSystem.IsWindows()) return;
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid() + ".json");
        try
        {
            var store = new TvLinkStore(path);
            store.Save(new LinkPeer("tv1", "TV"), "c2VjcmV0");
            Assert.Equal("c2VjcmV0", new TvLinkStore(path).Secret("tv1"));
        }
        finally { File.Delete(path); }
    }

    // ---- A fake TV (the Android TvLinkServer's rules) ---------------------------------------------

    private sealed class FakeTv : IDisposable
    {
        public readonly TcpListener Listener = new(IPAddress.Loopback, 0);
        public readonly PairingKeys Keys = PairingCrypto.NewKeyPair();
        public readonly byte[] Salt = PairingCrypto.NewSalt();
        public string Code = "123456";
        public readonly Dictionary<string, string> Secrets = new();
        public readonly HashSet<string> Seen = new();
        public readonly List<(string Path, string Body)> Requests = new();
        public volatile bool Playing;
        public int Port => ((IPEndPoint)Listener.LocalEndpoint).Port;

        public FakeTv()
        {
            Listener.Start();
            _ = Task.Run(Loop);
        }

        private async Task Loop()
        {
            while (true)
            {
                TcpClient c;
                try { c = await Listener.AcceptTcpClientAsync(); } catch { return; }
                using (c) await Handle(c.GetStream());
            }
        }

        private async Task Handle(NetworkStream s)
        {
            var head = new List<byte>();
            while (!(head.Count >= 4 && head[^4] == '\r' && head[^3] == '\n' && head[^2] == '\r' && head[^1] == '\n'))
            {
                var b = s.ReadByte();
                if (b < 0) return;
                head.Add((byte)b);
            }
            var lines = Encoding.Latin1.GetString(head.ToArray()).Split("\r\n");
            var parts = lines[0].Split(' ');
            var headers = lines.Skip(1).Where(l => l.Contains(':')).ToDictionary(l => l[..l.IndexOf(':')].Trim().ToLowerInvariant(), l => l[(l.IndexOf(':') + 1)..].Trim());
            var length = headers.TryGetValue("content-length", out var cl) ? int.Parse(cl) : 0;
            var body = new byte[length];
            await s.ReadExactlyAsync(body);
            var (status, reply) = Route(parts[0], parts[1], headers, body);
            var bytes = Encoding.UTF8.GetBytes(reply);
            await s.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"));
            await s.WriteAsync(bytes);
        }

        private (string, string) Route(string method, string path, Dictionary<string, string> headers, byte[] body)
        {
            lock (Requests) Requests.Add((path, Encoding.UTF8.GetString(body)));
            if (method == "GET" && path == "/hello")
                return ("200 OK", Encoding.UTF8.GetString(LinkJson.Encode(new LinkHello { Id = "tv-1", Name = "Living room", Version = 1, TvKey = PairingCrypto.EncodeKey(Keys), Salt = PairingCrypto.B64(Salt) })));
            if (path == "/pair/start") return ("200 OK", "{\"ok\":true,\"message\":\"Enter the code shown on the TV\"}");
            if (path == "/pair")
            {
                var message = LinkJson.Decode<PairMessage>(Encoding.UTF8.GetString(body));
                var phoneKey = Convert.FromBase64String(message.PhoneKey);
                var key = PairingCrypto.SessionKey(Keys, PairingCrypto.DecodeKey(message.PhoneKey), Code, Salt);
                var plain = PairingCrypto.Open(key, new PairingCrypto.Sealed(message.Iv, message.Data), phoneKey);
                if (plain == null) return ("403 Forbidden", "{\"ok\":false,\"message\":\"That code didn't match. The TV now shows a new code; enter that one.\",\"code\":\"wrong_code\"}");
                var secret = LinkJson.Decode<LinkPairSecret>(Encoding.UTF8.GetString(plain));
                Secrets[secret.PhoneId] = secret.Secret;
                return ("200 OK", "{\"ok\":true,\"message\":\"Paired\"}");
            }
            // Signed endpoints.
            if (!headers.TryGetValue("x-veltoret-phone", out var phone) || !headers.TryGetValue("x-veltoret-time", out var t)
                || !headers.TryGetValue("x-veltoret-signature", out var sig) || !Secrets.TryGetValue(phone, out var sec)
                || !TvLinkProtocol.Verify(sec, method, path, long.Parse(t), body, sig, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
                || !Seen.Add(sig))
                return ("401 Unauthorized", "{\"ok\":false,\"message\":\"Pair this phone with the TV again\",\"code\":\"unpaired\"}");
            return path switch
            {
                "/play" => Play(),
                "/command" => ("200 OK", "{\"ok\":true}"),
                "/status" => ("200 OK", Playing
                    ? "{\"active\":true,\"title\":\"Heat\",\"source\":\"phone\",\"playing\":true,\"positionMs\":5000,\"durationMs\":60000,\"audio\":[{\"id\":\"a0\",\"label\":\"English\"},{\"id\":\"a1\",\"label\":\"French\",\"detail\":\"AC3 · 5.1\"}],\"audioSelected\":\"a0\"}"
                    : "{}"),
                _ => ("404 Not Found", "{\"ok\":false,\"message\":\"Not found\"}"),
            };
        }

        private (string, string) Play()
        {
            Playing = true;
            return ("200 OK", "{\"ok\":true,\"message\":\"phone\"}");
        }

        public void Dispose()
        {
            Listener.Stop();
            Keys.Dispose();
        }
    }

    [Fact]
    public async Task PairsAndSignsLikeTheAndroidPhone()
    {
        using var tvServer = new FakeTv();
        var path = Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid() + ".json");
        try
        {
            var store = new TvLinkStore(path, s => s, s => s);
            var client = new TvLinkClient(store, () => "My PC");
            var hello = await client.Hello("127.0.0.1", tvServer.Port);
            var tv = new LinkTv(hello.Id, hello.Name, "127.0.0.1", tvServer.Port, false);

            await client.StartPairing(tv);
            Assert.Contains("\"phoneName\":\"My PC\"", tvServer.Requests.Last().Body);

            var wrong = await Assert.ThrowsAsync<LinkException>(() => client.Pair(tv, "000000"));
            Assert.Equal("wrong_code", wrong.Code);
            Assert.Null(store.Secret("tv-1"));

            await client.Pair(tv, " 123456 ");
            Assert.NotNull(store.Secret("tv-1"));
            Assert.Equal(store.Secret("tv-1"), tvServer.Secrets[store.DeviceId]);

            Assert.Equal("phone", await client.Play(tv, new LinkPlay { Title = "Heat", FileId = "x", AccountEmail = "device" }));
            tvServer.Playing = false;
            await client.Command(tv, new LinkCommand { Type = LinkCommand.Pause });
            await client.Command(tv, new LinkCommand { Type = LinkCommand.Pause }); // same body, fresh signature
            Assert.False((await client.Status(tv)).Active);
            Assert.Equal("", tvServer.Requests.Last().Body);

            // The TV forgot us: a 401 forgets the pairing here too.
            tvServer.Secrets.Clear();
            var unpaired = await Assert.ThrowsAsync<LinkException>(() => client.Status(tv));
            Assert.Equal("unpaired", unpaired.Code);
            Assert.Null(store.Secret("tv-1"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public async Task UnreachableTvSaysSo()
    {
        var store = new TvLinkStore(Path.Combine(Path.GetTempPath(), "veltoret-test-" + Guid.NewGuid() + ".json"), s => s, s => s);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        var e = await Assert.ThrowsAsync<LinkException>(() => new TvLinkClient(store).StartPairing(new LinkTv("x", "Bedroom TV", "127.0.0.1", port, false)));
        Assert.Equal("Couldn't reach Bedroom TV. Check it's on and on the same Wi-Fi.", e.Message);
    }

    [Fact]
    public async Task ControllerPlaysOnTheTvAndTakesBackWhenItCloses()
    {
        using var tvServer = new FakeTv();
        var root = Path.Combine(Path.GetTempPath(), "veltoret-link-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var db = new Veltoret.Core.Data.VeltoretDb(Path.Combine(root, "t.db"));
            var store = new TvLinkStore(Path.Combine(root, "tv_link.json"), s => s, s => s);
            var client = new TvLinkClient(store, () => "My PC");
            Veltoret.Core.Cast.CastServer.Opener open = (_, _, _) => Task.FromResult<Stream>(new MemoryStream(new byte[100]));
            var factory = new Veltoret.Core.Cast.CastMediaFactory(new Veltoret.Core.Data.MediaFileDao(db), new Veltoret.Core.Data.CatalogDao(db), (a, f, ct) => open(a, f, ct), () => "", () => "en");
            var cast = new Veltoret.Core.Cast.CastController(open, client, new Veltoret.Core.Library.WatchRepository(new Veltoret.Core.Data.WatchDao(db)), factory, () => false);
            var tv = new LinkTv("tv-1", "Living room", "127.0.0.1", tvServer.Port, false);
            await client.StartPairing(tv);
            await client.Pair(tv, "123456");

            await cast.Connect(new Veltoret.Core.Cast.CastDevice("tv-1", "Living room", Veltoret.Core.Cast.CastDeviceKind.Veltoret, "127.0.0.1", tvServer.Port, Paired: true));
            Assert.True(cast.State.Connected);
            Assert.NotNull(cast.State.Link);
            await cast.Load(new Veltoret.Core.Cast.CastMedia { FileId = "smb://nas/h/Heat (1995).mkv", Account = "smb://nas", Title = "Heat", SubtitleLanguage = LinkPlay.SubtitlesOff }, 1_000);
            var play = tvServer.Requests.Last(r => r.Path == "/play").Body;
            Assert.Contains("\"fileId\":\"smb://nas/h/Heat (1995).mkv\"", play);
            Assert.Contains("\"subtitleLanguage\":\"off\"", play);
            Assert.Matches("\"streamUrl\":\"vlink://127\\.0\\.0\\.1:[0-9]+/[0-9a-f]{32}/v[0-9]+\"", play);
            Assert.Equal("phone", cast.State.LinkSource);

            for (var i = 0; i < 60 && cast.State.PositionMs != 5000; i++) await Task.Delay(100);
            Assert.Equal(5000, cast.State.PositionMs);
            Assert.Equal(2, cast.State.LinkAudio.Count);
            Assert.True(cast.State.Playing);

            cast.SelectLinkAudio("a1");
            for (var i = 0; i < 50 && !tvServer.Requests.Any(r => r.Path == "/command" && r.Body.Contains("a1")); i++) await Task.Delay(50);
            Assert.Contains(tvServer.Requests, r => r.Path == "/command" && r.Body == "{\"type\":\"audio\",\"track\":\"a1\"}");

            // Back on the TV closes its player: the PC takes over.
            tvServer.Playing = false;
            for (var i = 0; i < 60 && cast.State.Connected; i++) await Task.Delay(100);
            Assert.False(cast.State.Connected);
            Assert.Equal(5000, cast.State.PositionMs);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            try { Directory.Delete(root, true); } catch (IOException) { }
        }
    }
}