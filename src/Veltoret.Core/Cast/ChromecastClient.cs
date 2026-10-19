using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net.Security;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Veltoret.Core.Cast;

/// <summary>
/// A hand-rolled Cast v2 sender: TLS to port 8009 (self-signed device certificate accepted), length-prefixed
/// protobuf <see cref="CastMessage"/>s, the connection / heartbeat / receiver / media namespaces, and the Default
/// Media Receiver (CC1AD845).
/// </summary>
public sealed class ChromecastClient : IAsyncDisposable
{
    public const string DefaultMediaReceiver = "CC1AD845";
    private const string Sender = "sender-0";
    private const string Receiver = "receiver-0";

    private readonly TcpClient _tcp;
    private readonly SslStream _ssl;
    private readonly SemaphoreSlim _write = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private int _requestId;
    private long _lastHeard = Environment.TickCount64;
    private int _closed;

    /// <summary>The app session (after <see cref="Launch"/>).</summary>
    public string? TransportId { get; private set; }
    public string? SessionId { get; private set; }

    /// <summary>A MEDIA_STATUS message (the whole payload).</summary>
    public event Action<JsonElement>? MediaStatus;
    /// <summary>A RECEIVER_STATUS message (the whole payload).</summary>
    public event Action<JsonElement>? ReceiverStatus;
    /// <summary>The connection dropped, the receiver app closed, or heartbeats stopped.</summary>
    public event Action? Closed;

    private ChromecastClient(TcpClient tcp, SslStream ssl)
    {
        _tcp = tcp;
        _ssl = ssl;
    }

    public static async Task<ChromecastClient> Connect(string host, int port, CancellationToken ct)
    {
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                timeout.CancelAfter(8_000);
                await tcp.ConnectAsync(host, port, timeout.Token);
            }
            // Cast devices use self-signed certificates; sender-side device authentication is optional.
            var ssl = new SslStream(tcp.GetStream(), false, (_, _, _, _) => true);
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                timeout.CancelAfter(8_000);
                await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = host }, timeout.Token);
            }
            var client = new ChromecastClient(tcp, ssl);
            client.Begin();
            await client.Send(CastMessage.NsConnection, Receiver, new JsonObject { ["type"] = "CONNECT" });
            return client;
        }
        catch
        {
            tcp.Dispose();
            throw;
        }
    }

    private void Begin()
    {
        _ = Task.Run(ReadLoop);
        _ = Task.Run(HeartbeatLoop);
    }

    // ---- Receiver ------------------------------------------------------------------------------------

    /// <summary>Joins the Default Media Receiver if it is already running, else launches it; then connects to it.</summary>
    public async Task Launch(CancellationToken ct)
    {
        var status = await Request(CastMessage.NsReceiver, Receiver, new JsonObject { ["type"] = "GET_STATUS" }, ct);
        if (!FindApp(status, out var transport, out var session))
        {
            status = await Request(CastMessage.NsReceiver, Receiver,
                new JsonObject { ["type"] = "LAUNCH", ["appId"] = DefaultMediaReceiver }, ct, timeoutMs: 20_000);
            if (!FindApp(status, out transport, out session))
            {
                // LAUNCH replies once the app is starting; its RECEIVER_STATUS may follow separately.
                for (var i = 0; i < 20 && !FindApp(status, out transport, out session); i++)
                {
                    await Task.Delay(500, ct);
                    status = await Request(CastMessage.NsReceiver, Receiver, new JsonObject { ["type"] = "GET_STATUS" }, ct);
                }
                if (!FindApp(status, out transport, out session)) throw new IOException("The TV didn't start the player");
            }
        }
        TransportId = transport;
        SessionId = session;
        await Send(CastMessage.NsConnection, transport, new JsonObject { ["type"] = "CONNECT" });
    }

    private static bool FindApp(JsonElement status, out string transportId, out string sessionId)
    {
        transportId = sessionId = "";
        if (!status.TryGetProperty("status", out var s) || !s.TryGetProperty("applications", out var apps) || apps.ValueKind != JsonValueKind.Array)
            return false;
        foreach (var app in apps.EnumerateArray())
        {
            if (app.TryGetProperty("appId", out var id) && id.GetString() == DefaultMediaReceiver
                && app.TryGetProperty("transportId", out var t) && app.TryGetProperty("sessionId", out var sid))
            {
                transportId = t.GetString() ?? "";
                sessionId = sid.GetString() ?? "";
                return transportId.Length > 0;
            }
        }
        return false;
    }

    /// <summary>Asks for RECEIVER_STATUS (volume); the answer comes through <see cref="ReceiverStatus"/>.</summary>
    public Task ReceiverGetStatus() =>
        Send(CastMessage.NsReceiver, Receiver, new JsonObject { ["type"] = "GET_STATUS", ["requestId"] = NextId() });

    public Task SetVolume(double level) =>
        Send(CastMessage.NsReceiver, Receiver, new JsonObject
        {
            ["type"] = "SET_VOLUME", ["requestId"] = NextId(), ["volume"] = new JsonObject { ["level"] = Math.Clamp(level, 0, 1) },
        });

    public Task SetMuted(bool muted) =>
        Send(CastMessage.NsReceiver, Receiver, new JsonObject
        {
            ["type"] = "SET_VOLUME", ["requestId"] = NextId(), ["volume"] = new JsonObject { ["muted"] = muted },
        });

    /// <summary>Stops the receiver app on the TV (stopReceiverApplicationWhenEndingSession) and closes.</summary>
    public async Task StopApp()
    {
        if (SessionId is { Length: > 0 } session)
        {
            try { await Send(CastMessage.NsReceiver, Receiver, new JsonObject { ["type"] = "STOP", ["sessionId"] = session, ["requestId"] = NextId() }); }
            catch (Exception) { }
        }
    }

    // ---- Media ---------------------------------------------------------------------------------------

    /// <summary>Sends LOAD and waits for its MEDIA_STATUS, or throws <see cref="CastLoadException"/> (LOAD_FAILED …).</summary>
    public async Task<JsonElement> Load(Func<int, string, JsonObject> build, CancellationToken ct)
    {
        var transport = TransportId ?? throw new InvalidOperationException("Not launched");
        var id = NextId();
        var payload = build(id, SessionId ?? "");
        var reply = await RequestWithId(CastMessage.NsMedia, transport, payload, id, ct, timeoutMs: 60_000);
        var type = reply.TryGetProperty("type", out var t) ? t.GetString() : null;
        if (type is "LOAD_FAILED" or "LOAD_CANCELLED" or "INVALID_REQUEST")
        {
            var code = reply.TryGetProperty("detailedErrorCode", out var d) && d.ValueKind == JsonValueKind.Number ? d.GetInt32().ToString() : type!;
            throw new CastLoadException(code);
        }
        return reply;
    }

    public Task MediaCommand(string type, long mediaSessionId, JsonObject? extra = null)
    {
        var transport = TransportId ?? throw new InvalidOperationException("Not launched");
        var payload = new JsonObject { ["type"] = type, ["mediaSessionId"] = mediaSessionId, ["requestId"] = NextId() };
        if (extra != null)
            foreach (var (k, v) in extra.ToList())
            {
                extra.Remove(k);
                payload[k] = v;
            }
        return Send(CastMessage.NsMedia, transport, payload);
    }

    public Task MediaGetStatus()
    {
        var transport = TransportId ?? throw new InvalidOperationException("Not launched");
        return Send(CastMessage.NsMedia, transport, new JsonObject { ["type"] = "GET_STATUS", ["requestId"] = NextId() });
    }

    // ---- Plumbing ------------------------------------------------------------------------------------

    private int NextId() => Interlocked.Increment(ref _requestId);

    public Task<JsonElement> Request(string ns, string destination, JsonObject payload, CancellationToken ct, int timeoutMs = 10_000)
    {
        var id = NextId();
        payload["requestId"] = id;
        return RequestWithId(ns, destination, payload, id, ct, timeoutMs);
    }

    private async Task<JsonElement> RequestWithId(string ns, string destination, JsonObject payload, int id, CancellationToken ct, int timeoutMs)
    {
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;
        try
        {
            await Send(ns, destination, payload);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct, _cts.Token);
            timeout.CancelAfter(timeoutMs);
            await using (timeout.Token.Register(() => tcs.TrySetException(new IOException("The TV didn't answer"))))
                return await tcs.Task;
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    public async Task Send(string ns, string destination, JsonObject payload)
    {
        var frame = new CastMessage(Sender, destination, ns, payload.ToJsonString()).Frame();
        await _write.WaitAsync(_cts.Token);
        try
        {
            await _ssl.WriteAsync(frame, _cts.Token);
            await _ssl.FlushAsync(_cts.Token);
        }
        finally
        {
            _write.Release();
        }
    }

    private async Task ReadLoop()
    {
        var header = new byte[4];
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                await _ssl.ReadExactlyAsync(header, _cts.Token);
                var length = (int)BinaryPrimitives.ReadUInt32BigEndian(header);
                if (length is < 0 or > 1 << 20) throw new InvalidDataException("Bad frame");
                var body = new byte[length];
                await _ssl.ReadExactlyAsync(body, _cts.Token);
                Interlocked.Exchange(ref _lastHeard, Environment.TickCount64);
                var message = CastMessage.Decode(body);
                if (message.PayloadUtf8 is { } json) await Dispatch(message, json);
            }
        }
        catch (Exception)
        {
            // Dropped (or closed by us).
        }
        Close();
    }

    private async Task Dispatch(CastMessage message, string json)
    {
        JsonElement payload;
        try
        {
            using var doc = JsonDocument.Parse(json);
            payload = doc.RootElement.Clone();
        }
        catch (JsonException) { return; }
        var type = payload.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        switch (message.Namespace)
        {
            case CastMessage.NsHeartbeat:
                if (type == "PING")
                    try { await Send(CastMessage.NsHeartbeat, message.SourceId, new JsonObject { ["type"] = "PONG" }); } catch (Exception) { }
                return;
            case CastMessage.NsConnection:
                // The receiver app (or the device) closed our virtual connection.
                if (type == "CLOSE" && (message.SourceId == TransportId || message.SourceId == Receiver)) Close();
                return;
        }
        if (payload.TryGetProperty("requestId", out var rid) && rid.ValueKind == JsonValueKind.Number && rid.TryGetInt32(out var id) && id != 0
            && _pending.TryRemove(id, out var tcs))
        {
            tcs.TrySetResult(payload);
        }
        switch (type)
        {
            case "MEDIA_STATUS":
                MediaStatus?.Invoke(payload);
                break;
            case "RECEIVER_STATUS":
                ReceiverStatus?.Invoke(payload);
                // Our app was stopped from elsewhere (another phone, the TV's remote).
                if (TransportId != null && !FindApp(payload, out _, out _)) Close();
                break;
        }
    }

    private async Task HeartbeatLoop()
    {
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                await Task.Delay(5_000, _cts.Token);
                // Drop the connection after about 3 missed beats.
                if (Environment.TickCount64 - Interlocked.Read(ref _lastHeard) > 16_000) break;
                await Send(CastMessage.NsHeartbeat, Receiver, new JsonObject { ["type"] = "PING" });
            }
        }
        catch (Exception) { }
        Close();
    }

    private void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        try { _cts.Cancel(); } catch (ObjectDisposedException) { }
        foreach (var p in _pending.Values) p.TrySetException(new IOException("The connection to the TV was lost"));
        try { _ssl.Dispose(); } catch (Exception) { }
        try { _tcp.Dispose(); } catch (Exception) { }
        Closed?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        if (Volatile.Read(ref _closed) == 0)
        {
            try
            {
                if (TransportId != null) await Send(CastMessage.NsConnection, TransportId, new JsonObject { ["type"] = "CLOSE" });
                await Send(CastMessage.NsConnection, Receiver, new JsonObject { ["type"] = "CLOSE" });
            }
            catch (Exception) { }
        }
        Closed = null; // a deliberate close isn't a drop
        Close();
    }
}

/// <summary>The receiver refused the video (LOAD_FAILED, LOAD_CANCELLED, INVALID_REQUEST).</summary>
public sealed class CastLoadException(string code) : IOException($"The TV couldn't play this video ({code})")
{
    public string Code { get; } = code;
}
