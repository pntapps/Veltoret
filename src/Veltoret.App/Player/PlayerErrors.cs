using System.Net;
using System.Net.Sockets;
using Veltoret.Core.Player;
using Veltoret.Core.Storage;

namespace Veltoret.App.Player;

/// <summary>
/// Error card messages (Android PlayerViewModel.describe), first match wins. libVLC reports no reason, so the
/// cause comes from the stream reader's last exception and libVLC's last error-level log lines.
/// </summary>
internal static class PlayerErrors
{
    public const string NoAccount = "This file isn't linked to a Google account";

    private static IEnumerable<Exception> Chain(Exception? e)
    {
        for (var c = e; c != null; c = c.InnerException)
        {
            yield return c;
            if (c is AggregateException agg)
                foreach (var inner in agg.InnerExceptions.SelectMany(Chain)) yield return inner;
        }
    }

    private static bool IsAuth(Exception e) =>
        e.GetType().Name.Contains("AuthRequired", StringComparison.Ordinal) ||
        e is HttpRequestException { StatusCode: HttpStatusCode.Unauthorized };

    private static bool IsSmb(Exception e) =>
        e.GetType().Name.StartsWith("Smb", StringComparison.Ordinal) ||
        (e.GetType().Namespace?.Contains(".Smb", StringComparison.Ordinal) ?? false);

    private static bool IsIo(Exception e) => e is IOException or SocketException or TimeoutException or UnauthorizedAccessException;

    public static bool LooksLikeDecoderError(IReadOnlyList<string> log) =>
        log.Any(l => l.Contains("decod", StringComparison.OrdinalIgnoreCase) ||
                     l.Contains("codec", StringComparison.OrdinalIgnoreCase) ||
                     l.Contains("hardware", StringComparison.OrdinalIgnoreCase) ||
                     l.Contains("d3d11", StringComparison.OrdinalIgnoreCase) ||
                     l.Contains("dxva", StringComparison.OrdinalIgnoreCase));

    /// <param name="error">What the stream reader (or opening the stream) threw, if anything.</param>
    /// <param name="log">libVLC's recent error lines, oldest first.</param>
    /// <param name="video">Codec FourCC, profile and size of the video track, when known.</param>
    public static string Describe(Exception? error, IReadOnlyList<string> log, string? account, string fileId, bool online,
        (string FourCC, int Profile, int Width, int Height)? video = null, string? audioFourCC = null)
    {
        var chain = Chain(error).ToList();
        if (chain.Any(IsAuth)) return "Your Google account needs to be reconnected in Settings.";
        var smbError = chain.FirstOrDefault(IsSmb);
        if (smbError != null) return string.IsNullOrWhiteSpace(smbError.Message) ? "Couldn't read this file from the server." : smbError.Message;
        var smb = Accounts.IsSmb(account);
        var local = Accounts.IsLocal(account);
        if (smb && !online) return "You're offline. This video is on a network server, so this device needs to be on the same network.";
        if (smb && chain.Any(IsIo)) return "Couldn't read this video from the network server. Check that it's on and that you're on the same Wi-Fi.";
        if (!local && !online)
            return "You're offline. This video is on Google Drive, so it needs an internet connection. Videos on this device still play.";
        if (local && (chain.Any(e => e is FileNotFoundException or DirectoryNotFoundException or UnauthorizedAccessException or IOException)
                      || !File.Exists(fileId)))
            return "This file isn't available on this device. If it's on a USB drive or another disk, make sure it's connected.";

        var http = chain.OfType<HttpRequestException>().FirstOrDefault();
        var messages = string.Join("\n", chain.Select(e => e.Message));
        if (http?.StatusCode == HttpStatusCode.Forbidden || messages.Contains("403", StringComparison.Ordinal))
            return "Google Drive refused the stream (403). The file may have hit its daily download limit — try again later.";
        if (http?.StatusCode == HttpStatusCode.NotFound || messages.Contains("404", StringComparison.Ordinal))
            return "This file is no longer in Google Drive.";
        if (http != null || chain.Any(e => e is SocketException or TimeoutException or TaskCanceledException or IOException))
            return "Network problem. Check your connection and retry.";

        var logText = string.Join("\n", log);
        if (logText.Contains("demux", StringComparison.OrdinalIgnoreCase) && !LooksLikeDecoderError(log))
            return "This file's container format isn't supported (for example WMV/ASF or RealMedia).";
        if (LooksLikeDecoderError(log))
        {
            if (video == null && audioFourCC == null) return "This device can't decode this file's format.";
            var unsupportedAudio = audioFourCC != null && logText.Contains(audioFourCC.Trim(), StringComparison.OrdinalIgnoreCase);
            if (unsupportedAudio)
                return $"This device can't decode the {MediaFormats.AudioCodec(audioFourCC)} audio track. Try another audio track.";
            if (video is { } v)
            {
                var codec = MediaFormats.VideoCodec(v.FourCC);
                if (codec == "HEVC" && v.Profile == 2)
                    return "This video is 10-bit HEVC (H.265 Main 10), and this device has no decoder for it. An 8-bit H.264 or HEVC version of the file will play.";
                if (codec == "Dolby Vision") return "This video is Dolby Vision, which this device can't decode.";
                var size = v.Width > 0 ? $" at {v.Width}×{v.Height}" : "";
                return $"This device can't decode {codec} video{size}.";
            }
            return "This device can't decode this file's format.";
        }
        return "Couldn't play this video.";
    }
}
