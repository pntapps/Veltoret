import Foundation

/// The media-channel LOAD message for the Default Media Receiver, as the Android Cast SDK sends it
/// (MediaLoadRequestData): autoplay, currentTime in seconds, subtitle tracks (ids 1..n), text track style.
public enum CastLoadRequest {
    public struct SubtitleTrack: Hashable, Sendable {
        public var name: String
        public var url: String
        public var language: String?
        public init(name: String, url: String, language: String?) { self.name = name; self.url = url; self.language = language }
    }

    public static func build(requestId: Int, sessionId: String, videoUrl: String, contentType: String, media: CastMedia,
                             startMs: Int64, subtitles: [SubtitleTrack], activeSubtitleIndex: Int?) -> [String: Any] {
        var images: [[String: Any]] = []
        if let p = media.posterUrl { images.append(["url": p]) }
        if let b = media.backdropUrl { images.append(["url": b]) }
        // 1 = MOVIE, 2 = TV_SHOW.
        var metadata: [String: Any] = ["metadataType": media.isEpisode ? 2 : 1, "title": media.title]
        if let s = media.subtitle { metadata["subtitle"] = s }
        metadata["images"] = images

        var tracks: [[String: Any]] = []
        for (i, sub) in subtitles.enumerated() {
            var track: [String: Any] = [
                "trackId": i + 1, "type": "TEXT", "subtype": "SUBTITLES", "name": sub.name,
                "trackContentId": sub.url, "trackContentType": "text/vtt",
            ]
            if let l = sub.language { track["language"] = l }
            tracks.append(track)
        }

        var request: [String: Any] = [
            "type": "LOAD", "requestId": requestId, "sessionId": sessionId, "autoplay": true,
            "currentTime": Double(startMs) / 1000.0,
        ]
        if let active = activeSubtitleIndex { request["activeTrackIds"] = [active + 1] }
        request["media"] = [
            "contentId": videoUrl,
            "contentUrl": videoUrl,
            "streamType": "BUFFERED",
            "contentType": contentType,
            "metadata": metadata,
            "tracks": tracks,
            // Android: background 0x99000000, foreground 0xFFFFFFFF (ARGB) → CSS #RRGGBBAA.
            "textTrackStyle": [
                "backgroundColor": "#00000099",
                "foregroundColor": "#FFFFFFFF",
                "edgeType": "DROP_SHADOW",
                "fontScale": 1.0,
            ] as [String: Any],
        ] as [String: Any]
        return request
    }
}
