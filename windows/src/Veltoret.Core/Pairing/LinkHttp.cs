using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Veltoret.Core.Pairing;

/// <summary>
/// The JSON rules of the Android app's kotlinx Json (WIRE): camelCase names, nulls not written, unknown keys
/// ignored, case-sensitive names. DTO properties carry the Kotlin defaults, because the TV omits every field
/// equal to its default.
/// </summary>
public static class LinkJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        NumberHandling = JsonNumberHandling.Strict,
    };

    /// <summary>UTF-8, no BOM.</summary>
    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Decode<T>(string text) => JsonSerializer.Deserialize<T>(text, Options) ?? throw new JsonException("Empty body");

    public static T? TryDecode<T>(string text) where T : class
    {
        try { return JsonSerializer.Deserialize<T>(text, Options); }
        catch (JsonException) { return null; }
    }
}

/// <summary>
/// One HTTP/1.1 request to a Veltoret mini-server (TV link, "Use your phone"), byte for byte as the Android
/// clients send it (WIRE §0.2). The server closes after replying; the whole reply is read until EOF.
/// </summary>
public static class LinkHttp
{
    public sealed record Reply(int Status, string Body);

    /// <param name="body">null: no Content-Type / Content-Length (GET). Empty array: sent with Content-Length: 0.</param>
    public static async Task<Reply> Exchange(
        string host, int port, string method, string path, byte[]? body,
        IReadOnlyList<KeyValuePair<string, string>>? headers, int connectTimeoutMs, int readTimeoutMs,
        CancellationToken ct = default)
    {
        using var client = new TcpClient();
        client.NoDelay = true;
        using (var connect = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            connect.CancelAfter(connectTimeoutMs);
            try
            {
                await client.ConnectAsync(host, port, connect.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new IOException("Connect timed out");
            }
            catch (SocketException e)
            {
                throw new IOException(e.Message, e);
            }
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(readTimeoutMs);
        try
        {
            var stream = client.GetStream();
            var head = new StringBuilder();
            head.Append(method).Append(' ').Append(path).Append(" HTTP/1.1\r\n");
            head.Append("Host: ").Append(host).Append(':').Append(port).Append("\r\n");
            head.Append("Connection: close\r\n");
            if (headers != null)
                foreach (var (k, v) in headers) head.Append(k).Append(": ").Append(v).Append("\r\n");
            var bytes = body ?? Array.Empty<byte>();
            if (body != null) head.Append("Content-Type: application/json\r\nContent-Length: ").Append(bytes.Length).Append("\r\n");
            head.Append("\r\n");
            var headBytes = Encoding.UTF8.GetBytes(head.ToString());
            var request = new byte[headBytes.Length + bytes.Length];
            headBytes.CopyTo(request, 0);
            bytes.CopyTo(request, headBytes.Length);
            await stream.WriteAsync(request, timeout.Token);
            await stream.FlushAsync(timeout.Token);

            using var all = new MemoryStream();
            await stream.CopyToAsync(all, timeout.Token);
            var text = Encoding.UTF8.GetString(all.GetBuffer(), 0, (int)all.Length);
            return Parse(text);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new IOException("Timed out");
        }
        catch (SocketException e)
        {
            throw new IOException(e.Message, e);
        }
    }

    /// <summary>Status from line 1 (split on ' ', element 1); body = everything after the first blank line.</summary>
    public static Reply Parse(string text)
    {
        var lineEnd = text.IndexOf("\r\n", StringComparison.Ordinal);
        var first = lineEnd >= 0 ? text[..lineEnd] : text;
        var parts = first.Split(' ');
        if (parts.Length < 2 || !int.TryParse(parts[1], out var status)) throw new IOException("Not HTTP");
        var split = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        return new Reply(status, split >= 0 ? text[(split + 4)..] : "");
    }
}
