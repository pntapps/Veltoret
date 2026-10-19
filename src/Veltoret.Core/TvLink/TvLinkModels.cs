namespace Veltoret.Core.TvLink;

// "Play on TV" messages (WIRE). Names are the Kotlin names (camelCase via LinkJson); defaults are the Kotlin
// defaults, because the TV leaves out every field equal to its default.

/// <summary>GET /hello: who the TV is, and its pairing key.</summary>
public sealed record LinkHello
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public int Version { get; init; }
    public string TvKey { get; init; } = "";
    public string Salt { get; init; } = "";
}

/// <summary>POST /pair/start.</summary>
public sealed record LinkPairStart
{
    public string PhoneId { get; init; } = "";
    public string PhoneName { get; init; } = "";
}

/// <summary>Sealed with the code into POST /pair.</summary>
public sealed record LinkPairSecret
{
    public string PhoneId { get; init; } = "";
    public string PhoneName { get; init; } = "";
    public string Secret { get; init; } = "";
}

public sealed record LinkReply
{
    public bool Ok { get; init; }
    public string Message { get; init; } = "";
    public string? Code { get; init; }
}

/// <summary>POST /play: what to play. The TV prefers its own copy and falls back to <see cref="StreamUrl"/>.</summary>
public sealed record LinkPlay
{
    public const string SubtitlesOff = "off";

    public string Title { get; init; } = "";
    public string? Subtitle { get; init; }
    public string FileId { get; init; } = "";
    public string AccountEmail { get; init; } = "";
    public string? FileName { get; init; }
    public int? MovieId { get; init; }
    public int? ShowId { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    /// <summary>"vlink://ip:port/token/id".</summary>
    public string? StreamUrl { get; init; }
    public long StartMs { get; init; }
    public string? AudioLanguage { get; init; }
    /// <summary>A language code, <see cref="SubtitlesOff"/>, or null to keep the TV's usual choice.</summary>
    public string? SubtitleLanguage { get; init; }
}

/// <summary>POST /command.</summary>
public sealed record LinkCommand
{
    public const string Play = "play";
    public const string Pause = "pause";
    public const string Seek = "seek";
    public const string Stop = "stop";
    public const string Audio = "audio";
    /// <summary><see cref="Track"/> null turns subtitles off.</summary>
    public const string Subtitle = "subtitle";

    public string Type { get; init; } = "";
    public long? PositionMs { get; init; }
    public string? Track { get; init; }
}

public sealed record LinkTrack
{
    public string Id { get; init; } = "";
    public string Label { get; init; } = "";
    public string Detail { get; init; } = "";
}

/// <summary>POST /status: what the TV is playing now. The idle TV answers <c>{}</c>.</summary>
public sealed record LinkStatus
{
    public const string SourceTv = "tv";
    public const string SourcePhone = "phone";

    public bool Active { get; init; }
    public string Title { get; init; } = "";
    public string Source { get; init; } = "";
    public bool Playing { get; init; }
    public bool Buffering { get; init; }
    public long PositionMs { get; init; }
    public long DurationMs { get; init; }
    public bool Ended { get; init; }
    public string? Error { get; init; }
    public IReadOnlyList<LinkTrack> Audio { get; init; } = Array.Empty<LinkTrack>();
    public string? AudioSelected { get; init; }
    public IReadOnlyList<LinkTrack> Subtitles { get; init; } = Array.Empty<LinkTrack>();
    public string? SubtitleSelected { get; init; }
}

/// <summary>A TV running Veltoret's "Play on TV" listener. <see cref="Paired"/>: this PC has its secret.</summary>
public sealed record LinkTv(string Id, string Name, string Host, int Port, bool Paired);

/// <summary>A paired TV as stored.</summary>
public sealed record LinkPeer(string Id, string Name);

/// <summary>A request the TV refused (or couldn't be reached), with the sentence to show and its code.</summary>
public sealed class LinkException(string message, string? code = null) : IOException(message)
{
    public string? Code { get; } = code;
}
