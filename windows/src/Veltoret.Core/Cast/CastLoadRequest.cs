using System.Text.Json.Nodes;

namespace Veltoret.Core.Cast;

/// <summary>
/// The media-channel LOAD message for the Default Media Receiver, as the Android Cast SDK sends it
/// (MediaLoadRequestData): autoplay, currentTime in seconds, subtitle tracks (ids 1..n), text track style.
/// </summary>
public static class CastLoadRequest
{
    public sealed record SubtitleTrack(string Name, string Url, string? Language);

    public static JsonObject Build(
        int requestId, string sessionId, string videoUrl, string contentType, CastMedia media, long startMs,
        IReadOnlyList<SubtitleTrack> subtitles, int? activeSubtitleIndex)
    {
        var images = new JsonArray();
        if (media.PosterUrl != null) images.Add(new JsonObject { ["url"] = media.PosterUrl });
        if (media.BackdropUrl != null) images.Add(new JsonObject { ["url"] = media.BackdropUrl });
        var metadata = new JsonObject
        {
            // 1 = MOVIE, 2 = TV_SHOW.
            ["metadataType"] = media.IsEpisode ? 2 : 1,
            ["title"] = media.Title,
        };
        if (media.Subtitle != null) metadata["subtitle"] = media.Subtitle;
        metadata["images"] = images;

        var tracks = new JsonArray();
        for (var i = 0; i < subtitles.Count; i++)
        {
            var sub = subtitles[i];
            var track = new JsonObject
            {
                ["trackId"] = i + 1,
                ["type"] = "TEXT",
                ["subtype"] = "SUBTITLES",
                ["name"] = sub.Name,
                ["trackContentId"] = sub.Url,
                ["trackContentType"] = "text/vtt",
            };
            if (sub.Language != null) track["language"] = sub.Language;
            tracks.Add(track);
        }

        var request = new JsonObject
        {
            ["type"] = "LOAD",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
            ["autoplay"] = true,
            ["currentTime"] = startMs / 1000.0,
        };
        if (activeSubtitleIndex is { } active) request["activeTrackIds"] = new JsonArray(active + 1);
        request["media"] = new JsonObject
        {
            ["contentId"] = videoUrl,
            ["contentUrl"] = videoUrl,
            ["streamType"] = "BUFFERED",
            ["contentType"] = contentType,
            ["metadata"] = metadata,
            ["tracks"] = tracks,
            // Android: background 0x99000000, foreground 0xFFFFFFFF (ARGB) → CSS #RRGGBBAA.
            ["textTrackStyle"] = new JsonObject
            {
                ["backgroundColor"] = "#00000099",
                ["foregroundColor"] = "#FFFFFFFF",
                ["edgeType"] = "DROP_SHADOW",
                ["fontScale"] = 1.0,
            },
        };
        return request;
    }
}
