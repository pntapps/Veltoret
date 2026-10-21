using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Veltoret.Core.Cast;

/// <summary>
/// A tiny HTTP server a Chromecast (or Veltoret on a TV, as vlink://) streams from while casting (Android
/// CastServer, WIRE §4). Plain <see cref="TcpListener"/> on the LAN address facing the receiver, so no URL ACL or
/// admin rights are needed. Runs only while casting; paths carry a random token, and only home-network
/// addresses are answered. Supports Range (seeking) and CORS (the receiver fetches subtitles with XHR).
/// </summary>
public sealed class CastServer : IDisposable
{
    /// <summary>Marks "to the end" in a range whose file size isn't known.</summary>
    public const long OpenEnd = long.MaxValue - 1;

    /// <summary>Opens a seekable stream for a file of any source (Storage.OpenRead).</summary>
    public delegate Task<Stream> Opener(string account, string fileId, CancellationToken ct);

    private abstract class Entry(string mime)
    {
        public string Mime { get; } = mime;
    }

    private sealed class MediaEntry(string account, string fileId, string mime, long? length, IReadOnlyDictionary<long, byte> patches) : Entry(mime)
    {
        public string Account { get; } = account;
        public string FileId { get; } = fileId;
        public long? Length { get; set; } = length;
        public IReadOnlyDictionary<long, byte> Patches { get; } = patches;
    }

    private sealed class TextEntry(byte[] bytes, string mime) : Entry(mime)
    {
        public byte[] Bytes { get; } = bytes;
    }

    private static readonly IReadOnlyDictionary<long, byte> NoPatches = new Dictionary<long, byte>();
    private static readonly Encoding Latin1 = Encoding.Latin1;

    private readonly Opener _open;
    private readonly ConcurrentDictionary<string, Entry> _entries = new();
    private readonly object _lock = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private string _host = "";

    public CastServer(Opener open) => _open = open;

    /// <summary>16 random bytes as lowercase hex, made once per server instance.</summary>
    public string Token { get; } = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    public bool Running { get { lock (_lock) return _listener != null; } }

    /// <summary>Raised (on a pool thread) for every request from a home-network client: the receiver can reach us.</summary>
    public event Action? RequestReceived;

    /// <summary>Listens on <paramref name="address"/> (this PC's address facing the receiver), port 0; idempotent.</summary>
    public void Start(IPAddress address)
    {
        lock (_lock)
        {
            if (_listener != null && _host == address.ToString()) return;
            StopSocket();
            var listener = new TcpListener(address, 0);
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start(16);
            _listener = listener;
            _host = address.ToString();
            var cts = new CancellationTokenSource();
            _cts = cts;
            _ = Task.Run(() => AcceptLoop(listener, cts.Token));
        }
    }

    /// <summary>Stops listening and forgets every entry.</summary>
    public void Stop()
    {
        lock (_lock)
        {
            StopSocket();
            _entries.Clear();
        }
    }

    public void Dispose() => Stop();

    private void StopSocket()
    {
        try { _cts?.Cancel(); } catch (ObjectDisposedException) { }
        try { _listener?.Stop(); } catch (SocketException) { }
        _listener = null;
        _cts = null;
    }

    /// <summary>The URL the receiver loads the file from. <paramref name="id"/> must be URL-safe ([A-Za-z0-9._-]).</summary>
    public string Media(string id, string account, string fileId, string mime, long? length, IReadOnlyDictionary<long, byte>? patches = null)
    {
        _entries[id] = new MediaEntry(account, fileId, mime, length is > 0 ? length : null, patches ?? NoPatches);
        return Url(id);
    }

    /// <summary>Serves <paramref name="text"/> (a WebVTT subtitle) at a URL.</summary>
    public string Text(string id, string text, string mime = "text/vtt")
    {
        _entries[id] = new TextEntry(Encoding.UTF8.GetBytes(text), mime);
        return Url(id);
    }

    private string Url(string id)
    {
        lock (_lock)
        {
            var listener = _listener ?? throw new InvalidOperationException("Cast server isn't running");
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var host = _host.Contains(':') ? $"[{_host}]" : _host;
            return $"http://{host}:{port}/{Token}/{id}";
        }
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct); }
            catch (Exception) { break; }
            _ = Task.Run(async () =>
            {
                using (client)
                {
                    try { await Handle(client, ct); }
                    // The Chromecast closes connections whenever it seeks or has buffered enough; that's normal.
                    catch (Exception) { }
                }
            }, CancellationToken.None);
        }
    }

    private async Task Handle(TcpClient client, CancellationToken serverCt)
    {
        client.ReceiveTimeout = 30_000;
        client.SendTimeout = 30_000;
        client.NoDelay = true;
        var remote = ((IPEndPoint)client.Client.RemoteEndPoint!).Address;
        var stream = client.GetStream();
        var requestLine = ReadLine(stream);
        if (requestLine == null) return;
        var headers = new Dictionary<string, string>();
        var headBytes = requestLine.Length;
        while (true)
        {
            var line = ReadLine(stream);
            if (line == null || line.Length == 0) break;
            headBytes += line.Length;
            if (headBytes > 16 * 1024) return;
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var parts = requestLine.Split(' ');
        var method = parts.Length > 0 ? parts[0] : "";
        var target = parts.Length > 1 ? parts[1] : "";
        var q = target.IndexOf('?');
        var path = q >= 0 ? target[..q] : target;

        if (!IsHomeNetwork(remote)) { Respond(stream, 403, "Forbidden"); return; }
        RequestReceived?.Invoke();
        if (method == "OPTIONS") { Respond(stream, 204, null); return; }
        var segments = path.Trim('/').Split('/');
        if (segments.Length != 2 || segments[0] != Token || !_entries.TryGetValue(segments[1], out var entry))
        {
            Respond(stream, 404, "Not found");
            return;
        }
        var head = method == "HEAD";
        switch (entry)
        {
            case TextEntry text:
                Respond(stream, 200, null, new()
                {
                    new("Content-Type", text.Mime + "; charset=utf-8"),
                    new("Content-Length", text.Bytes.Length.ToString(CultureInfo.InvariantCulture)),
                });
                if (!head) stream.Write(text.Bytes);
                stream.Flush();
                break;
            case MediaEntry media:
                headers.TryGetValue("range", out var range);
                await ServeMedia(stream, media, range, head, serverCt);
                break;
        }
    }

    private async Task ServeMedia(NetworkStream output, MediaEntry entry, string? rangeHeader, bool head, CancellationToken ct)
    {
        Stream? source = null;
        try
        {
            var total = entry.Length;
            if (total == null)
            {
                source = await _open(entry.Account, entry.FileId, ct);
                try { total = source.Length > 0 ? source.Length : null; } catch (NotSupportedException) { }
                entry.Length = total;
            }
            (long First, long Last)? range = rangeHeader != null ? ParseRange(rangeHeader, total) : null;
            if (rangeHeader != null && range == null)
            {
                Respond(output, 416, null, new() { new("Content-Range", $"bytes */{(total?.ToString(CultureInfo.InvariantCulture) ?? "*")}") });
                return;
            }
            var start = range?.First ?? 0L;
            // An open range on a file of unknown size ("bytes=500-") streams to the end.
            long? end = range is { } r && r.Last != OpenEnd ? r.Last : total - 1;
            long? length = end is { } e ? e - start + 1 : null;
            var headers = new List<KeyValuePair<string, string>>
            {
                new("Content-Type", entry.Mime),
                new("Accept-Ranges", "bytes"),
            };
            if (length != null) headers.Add(new("Content-Length", length.Value.ToString(CultureInfo.InvariantCulture)));
            if (range != null)
                headers.Add(new("Content-Range", $"bytes {start}-{(end?.ToString(CultureInfo.InvariantCulture) ?? "")}/{(total?.ToString(CultureInfo.InvariantCulture) ?? "*")}"));
            Respond(output, range != null ? 206 : 200, null, headers);
            if (head) return;

            source ??= await _open(entry.Account, entry.FileId, ct);
            if (start > 0)
            {
                if (source.CanSeek) source.Seek(start, SeekOrigin.Begin);
                else await Skip(source, start, ct);
            }
            var buffer = new byte[256 * 1024];
            var remaining = length ?? long.MaxValue;
            var position = start;
            while (remaining > 0)
            {
                var n = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), ct);
                if (n <= 0) break;
                CastAudio.Apply(entry.Patches, position, buffer, n);
                output.Write(buffer, 0, n);
                remaining -= n;
                position += n;
            }
            output.Flush();
        }
        finally
        {
            if (source != null) await source.DisposeAsync();
        }
    }

    private static async Task Skip(Stream s, long count, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        while (count > 0)
        {
            var n = await s.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, count)), ct);
            if (n <= 0) break;
            count -= n;
        }
    }

    /// <summary>One header line, ISO-8859-1, without its CR LF; null at EOF.</summary>
    private static string? ReadLine(Stream s)
    {
        var bytes = new List<byte>(128);
        while (true)
        {
            var b = s.ReadByte();
            if (b < 0) return bytes.Count == 0 ? null : Latin1.GetString(bytes.ToArray());
            if (b == '\n') break;
            bytes.Add((byte)b);
            if (bytes.Count > 8192) return null;
        }
        if (bytes.Count > 0 && bytes[^1] == '\r') bytes.RemoveAt(bytes.Count - 1);
        return Latin1.GetString(bytes.ToArray());
    }

    /// <summary>Writes the response head in the exact order Android does (CORS first), then a text body if any.</summary>
    private static void Respond(Stream output, int code, string? body, List<KeyValuePair<string, string>>? headers = null)
    {
        output.Write(ResponseHead(code, body, headers, out var bodyBytes));
        if (bodyBytes != null) output.Write(bodyBytes);
        output.Flush();
    }

    public static byte[] ResponseHead(int code, string? body, IReadOnlyList<KeyValuePair<string, string>>? headers, out byte[]? bodyBytes)
    {
        var text = new StringBuilder();
        text.Append("HTTP/1.1 ").Append(code).Append(' ').Append(Reason(code)).Append("\r\n");
        text.Append("Access-Control-Allow-Origin: *\r\n");
        text.Append("Access-Control-Allow-Headers: Range, Content-Type\r\n");
        text.Append("Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\n");
        text.Append("Connection: close\r\n");
        if (headers != null)
            foreach (var (k, v) in headers) text.Append(k).Append(": ").Append(v).Append("\r\n");
        bodyBytes = body != null ? Encoding.UTF8.GetBytes(body) : null;
        if (bodyBytes != null) text.Append("Content-Type: text/plain\r\nContent-Length: ").Append(bodyBytes.Length).Append("\r\n");
        text.Append("\r\n");
        return Latin1.GetBytes(text.ToString());
    }

    private static string Reason(int code) => code switch
    {
        200 => "OK",
        204 => "No Content",
        206 => "Partial Content",
        403 => "Forbidden",
        404 => "Not Found",
        416 => "Range Not Satisfiable",
        _ => "Error",
    };

    /// <summary>
    /// "bytes=500-" / "bytes=500-999" / "bytes=-200" against a file of <paramref name="total"/> bytes (null = unknown).
    /// Returns the inclusive byte range, or null when it can't be satisfied.
    /// </summary>
    public static (long First, long Last)? ParseRange(string header, long? total)
    {
        var trimmed = header.Trim();
        var spec = trimmed.StartsWith("bytes=", StringComparison.Ordinal) ? trimmed["bytes=".Length..] : trimmed;
        var comma = spec.IndexOf(',');
        if (comma >= 0) spec = spec[..comma];
        spec = spec.Trim();
        var dash = spec.IndexOf('-');
        if (!trimmed.StartsWith("bytes=", StringComparison.Ordinal) || dash < 0) return null;
        var startText = spec[..dash].Trim();
        var endText = spec[(dash + 1)..].Trim();
        if (startText.Length == 0)
        {
            // Suffix range: the last N bytes.
            if (!TryLong(endText, out var n)) return null;
            if (total == null || n <= 0) return null;
            return (Math.Max(0, total.Value - n), total.Value - 1);
        }
        if (!TryLong(startText, out var start)) return null;
        if (total != null && start >= total) return null;
        long? last = total - 1;
        long end;
        if (TryLong(endText, out var e)) end = last != null ? Math.Min(e, last.Value) : e;
        else if (last != null) end = last.Value;
        else return (start, OpenEnd);
        return end < start ? null : (start, end);
    }

    private static bool TryLong(string text, out long value) =>
        long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    /// <summary>Only devices on the home network (and this PC) may stream.</summary>
    public static bool IsHomeNetwork(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return true;
        var b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return b[0] == 10
                || (b[0] == 172 && (b[1] & 0xF0) == 16)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
                || b[0] == 127;
        }
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return address.IsIPv6LinkLocal || address.IsIPv6SiteLocal
                // IPv6 unique local addresses (fc00::/7).
                || (b.Length == 16 && (b[0] & 0xFE) == 0xFC);
        }
        return false;
    }

    /// <summary>This PC's address on the network the receiver is on (a UDP "connect" picks the interface).</summary>
    public static IPAddress AddressFacing(IPAddress receiver)
    {
        using var socket = new Socket(receiver.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
        socket.Connect(receiver, 8009);
        return ((IPEndPoint)socket.LocalEndPoint!).Address;
    }
}
