using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Veltoret.Core.Auth;

/// <summary>
/// The redirect target of the installed-app flow (RFC 8252): listens on http://127.0.0.1:{free port}/ for the one
/// request the browser makes after the Google screen, answers it with a small page, and hands back its query.
/// A plain TcpListener on the loopback address (no http.sys URL reservation, works without admin rights).
/// </summary>
public sealed class LoopbackReceiver : IDisposable
{
    private readonly TcpListener _listener;

    public int Port { get; }
    public string RedirectUri => $"http://127.0.0.1:{Port}/";

    public LoopbackReceiver()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
    }

    /// <summary>
    /// Waits for the redirect and returns its query parameters. Requests without code/error (a favicon, a
    /// prefetch) get a 404 and are ignored. <paramref name="pageFor"/> builds the HTML reply from the parameters.
    /// </summary>
    public async Task<Dictionary<string, string>> WaitForRedirect(Func<Dictionary<string, string>, string> pageFor, CancellationToken ct)
    {
        using var reg = ct.Register(() => { try { _listener.Stop(); } catch (Exception) { } });
        while (true)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
            }
            catch (Exception) when (ct.IsCancellationRequested)
            {
                throw new OperationCanceledException(ct);
            }
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    using var readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    readCts.CancelAfter(TimeSpan.FromSeconds(10));
                    var target = await ReadRequestTarget(stream, readCts.Token).ConfigureAwait(false);
                    if (target == null) continue;
                    var query = ParseQuery(target);
                    if (!query.ContainsKey("code") && !query.ContainsKey("error"))
                    {
                        await Respond(stream, 404, "Not found", "").ConfigureAwait(false);
                        continue;
                    }
                    await Respond(stream, 200, "OK", pageFor(query)).ConfigureAwait(false);
                    return query;
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    // A broken or slow connection: wait for the next one.
                }
            }
        }
    }

    private static async Task<string?> ReadRequestTarget(NetworkStream stream, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(total), ct).ConfigureAwait(false);
            if (n <= 0) break;
            total += n;
            if (Encoding.ASCII.GetString(buffer, 0, total).Contains("\r\n\r\n")) break;
        }
        var text = Encoding.ASCII.GetString(buffer, 0, total);
        var line = text.Split("\r\n", 2)[0];
        var parts = line.Split(' ');
        if (parts.Length < 2 || parts[0] != "GET") return null;
        return parts[1];
    }

    public static Dictionary<string, string> ParseQuery(string target)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var q = target.IndexOf('?');
        if (q < 0) return result;
        foreach (var pair in target[(q + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var key = Uri.UnescapeDataString((eq < 0 ? pair : pair[..eq]).Replace('+', ' '));
            var value = eq < 0 ? "" : Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
            result[key] = value;
        }
        return result;
    }

    private static async Task Respond(NetworkStream stream, int code, string reason, string html)
    {
        var body = Encoding.UTF8.GetBytes(html);
        var head = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {code} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(head).ConfigureAwait(false);
        await stream.WriteAsync(body).ConfigureAwait(false);
        await stream.FlushAsync().ConfigureAwait(false);
    }

    /// <summary>The page the browser shows after Google sends it back.</summary>
    public static string Page(string title, string text) =>
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Veltoret</title><style>" +
        "body{margin:0;background:#0B0B0D;color:#F3EFE6;font-family:Inter,Segoe UI,sans-serif;display:flex;" +
        "align-items:center;justify-content:center;min-height:100vh}" +
        "div{max-width:440px;padding:32px;border:1px solid #2C2C35;border-radius:16px;background:#15151A}" +
        "h1{font-size:22px;margin:0 0 12px;color:#E8A33D}p{margin:0;color:#9C9AA3;line-height:1.5}</style></head>" +
        $"<body><div><h1>{WebUtility.HtmlEncode(title)}</h1><p>{WebUtility.HtmlEncode(text)}</p></div></body></html>";

    public void Dispose()
    {
        try { _listener.Stop(); } catch (Exception) { }
    }
}
