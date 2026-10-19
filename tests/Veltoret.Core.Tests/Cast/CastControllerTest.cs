using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Nodes;
using Veltoret.Core.Cast;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.TvLink;

namespace Veltoret.Core.Tests.Cast;

/// <summary>End-to-end over loopback: a fake Chromecast (TLS + Cast v2 framing) and the real controller and server.</summary>
public class CastControllerTest
{
    private sealed class FakeChromecast : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly X509Certificate2 _cert;
        public readonly List<JsonObject> Received = new();
        public readonly TaskCompletionSource<JsonObject> Loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

        public FakeChromecast()
        {
            using var key = RSA.Create(2048);
            var req = new CertificateRequest("CN=fake-cast", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
            _cert = X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx), null);
            _listener.Start();
            _ = Task.Run(Serve);
        }

        private async Task Serve()
        {
            using var client = await _listener.AcceptTcpClientAsync();
            using var ssl = new SslStream(client.GetStream());
            await ssl.AuthenticateAsServerAsync(_cert);
            var launched = false;
            var header = new byte[4];
            try
            {
                while (true)
                {
                    await ssl.ReadExactlyAsync(header);
                    var body = new byte[BinaryPrimitives.ReadUInt32BigEndian(header)];
                    await ssl.ReadExactlyAsync(body);
                    var m = CastMessage.Decode(body);
                    var json = JsonNode.Parse(m.PayloadUtf8!)!.AsObject();
                    lock (Received) Received.Add(json);
                    var type = json["type"]?.GetValue<string>();
                    var rid = json["requestId"]?.GetValue<int>() ?? 0;
                    async Task Reply(string ns, string payload) =>
                        await ssl.WriteAsync(new CastMessage(m.DestinationId, m.SourceId, ns, payload).Frame());
                    switch (type)
                    {
                        case "PING": await Reply(CastMessage.NsHeartbeat, "{\"type\":\"PONG\"}"); break;
                        case "GET_STATUS" when m.Namespace == CastMessage.NsReceiver:
                        case "LAUNCH":
                            if (type == "LAUNCH") launched = true;
                            var apps = launched ? "[{\"appId\":\"CC1AD845\",\"transportId\":\"web-5\",\"sessionId\":\"sess-1\"}]" : "[]";
                            await Reply(CastMessage.NsReceiver, $"{{\"type\":\"RECEIVER_STATUS\",\"requestId\":{rid},\"status\":{{\"applications\":{apps},\"volume\":{{\"level\":0.4,\"muted\":false}}}}}}");
                            break;
                        case "LOAD":
                            Loaded.TrySetResult(json);
                            await Reply(CastMessage.NsMedia, $"{{\"type\":\"MEDIA_STATUS\",\"requestId\":{rid},\"status\":[{{\"mediaSessionId\":1,\"playerState\":\"PLAYING\",\"currentTime\":12.5,\"media\":{{\"duration\":600.0}}}}]}}");
                            break;
                        case "GET_STATUS":
                            await Reply(CastMessage.NsMedia, $"{{\"type\":\"MEDIA_STATUS\",\"requestId\":{rid},\"status\":[{{\"mediaSessionId\":1,\"playerState\":\"PAUSED\",\"currentTime\":20.0}}]}}");
                            break;
                    }
                }
            }
            catch (Exception) { }
        }

        public void Dispose() => _listener.Stop();
    }

    [Fact]
    public async Task ConnectsLoadsAndControls()
    {
        var root = Path.Combine(Path.GetTempPath(), "veltoret-cast-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var db = new VeltoretDb(Path.Combine(root, "test.db"));
            var data = Enumerable.Range(0, 4096).Select(i => (byte)i).ToArray();
            CastServer.Opener open = (_, _, _) => Task.FromResult<Stream>(new MemoryStream(data));
            var factory = new CastMediaFactory(new MediaFileDao(db), new CatalogDao(db), (a, f, ct) => open(a, f, ct), () => "", () => "en");
            var store = new TvLinkStore(Path.Combine(root, "tv_link.json"), s => s, s => s);
            var cast = new CastController(open, new TvLinkClient(store), new WatchRepository(new WatchDao(db)), factory, () => false);
            using var fake = new FakeChromecast();

            await cast.Connect(new CastDevice("cc", "Living Room", CastDeviceKind.Chromecast, "127.0.0.1", fake.Port));
            Assert.True(cast.State.Connected);
            Assert.Equal("Living Room", cast.State.DeviceName);

            var media = new CastMedia
            {
                FileId = "C:\\Videos\\Heat (1995).mp4", Account = "device", FileName = "Heat (1995).mp4", Title = "Heat",
                Subtitles = new[] { new CastSubtitle("sub1", "English", "en", "WEBVTT\n\n") }, ActiveSubtitle = "sub1",
            };
            await cast.Load(media, 754_000);
            var load = await fake.Loaded.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal("sess-1", load["sessionId"]!.GetValue<string>());
            Assert.Equal(754.0, load["currentTime"]!.GetValue<double>());
            Assert.Equal("video/mp4", load["media"]!["contentType"]!.GetValue<string>());
            Assert.Equal(1, load["activeTrackIds"]![0]!.GetValue<int>());
            var url = load["media"]!["contentId"]!.GetValue<string>();
            Assert.Matches($"^http://127\\.0\\.0\\.1:[0-9]+/{cast.Server.Token}/v{CastFormats.JavaHash(media.FileId)}a0$", url);

            // The receiver can fetch the video from the PC.
            using (var http = new HttpClient())
            {
                var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(10, 19);
                var resp = await http.SendAsync(req);
                Assert.Equal(HttpStatusCode.PartialContent, resp.StatusCode);
                Assert.Equal(data[10..20], await resp.Content.ReadAsByteArrayAsync());
                var vtt = await http.GetStringAsync(load["media"]!["tracks"]![0]!["trackContentId"]!.GetValue<string>());
                Assert.Equal("WEBVTT\n\n", vtt);
            }

            // The LOAD reply arrives as MEDIA_STATUS: playing at 12.5 s of 600 s.
            await WaitFor(() => cast.State.Playing && cast.State.DurationMs == 600_000);
            Assert.Equal(0.4, cast.State.Volume);
            cast.Pause();
            cast.SeekTo(30_000);
            cast.SelectSubtitle(null);
            await WaitFor(() => Has(fake, "PAUSE") && Has(fake, "SEEK") && Has(fake, "EDIT_TRACKS_INFO"));
            var seek = Find(fake, "SEEK");
            Assert.Equal(30.0, seek["currentTime"]!.GetValue<double>());
            Assert.Equal(1, seek["mediaSessionId"]!.GetValue<int>());
            Assert.Empty(Find(fake, "EDIT_TRACKS_INFO")["activeTrackIds"]!.AsArray());

            var position = await cast.Disconnect();
            Assert.False(cast.State.Connected);
            Assert.True(position > 0);
            await WaitFor(() => Has(fake, "STOP"));
            Assert.False(cast.Server.Running);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            try { Directory.Delete(root, true); } catch (IOException) { }
        }
    }

    private static bool Has(FakeChromecast f, string type) { lock (f.Received) return f.Received.Any(j => j["type"]?.GetValue<string>() == type); }
    private static JsonObject Find(FakeChromecast f, string type) { lock (f.Received) return f.Received.Last(j => j["type"]?.GetValue<string>() == type); }

    private static async Task WaitFor(Func<bool> condition)
    {
        for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(50);
        Assert.True(condition());
    }
}
