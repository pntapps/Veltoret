import Foundation

/// Ids for things on a network share (port of Android's / Windows' SmbPath): "smb://host" is the server (lists its
/// shares), "smb://host/share" a share, and "smb://host/share/folder/file" anything inside one. The host is part of
/// every id because ids must be unique across sources (they're primary keys of library rows). Ids are not
/// URL-encoded and must stay byte-identical to Android's (the TV matches files by id).
public struct SmbPath: Hashable, Sendable, CustomStringConvertible {
    public static let scheme = "smb://"

    public let host: String
    public let share: String?
    public let segments: [String]

    public init(host: String, share: String?, segments: [String] = []) {
        self.host = host
        self.share = share
        self.segments = segments
    }

    public var id: String {
        var s = SmbPath.scheme + host
        if let share {
            s += "/" + share
            for seg in segments { s += "/" + seg }
        }
        return s
    }

    /// The path inside the share as SMB wants it ("folder\\file"; "" for the share itself).
    public var sharePath: String { segments.joined(separator: "\\") }

    /// The path inside the share as AMSMB2 wants it ("folder/file"; "" for the share itself).
    public var filePath: String { segments.joined(separator: "/") }

    public var name: String { segments.last ?? share ?? host }

    public var parent: SmbPath? {
        if !segments.isEmpty { return SmbPath(host: host, share: share, segments: Array(segments.dropLast())) }
        if share != nil { return SmbPath(host: host, share: nil, segments: []) }
        return nil
    }

    public func child(_ name: String) -> SmbPath {
        share == nil ? SmbPath(host: host, share: name, segments: []) : SmbPath(host: host, share: share, segments: segments + [name])
    }

    /// The server's account id ("smb://host").
    public var account: String { SmbPath.scheme + host }

    public static func isSmb(_ id: String?) -> Bool { id?.hasPrefix(scheme) ?? false }

    public static func accountOf(_ host: String) -> String {
        scheme + host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Parses an id. Throws `SmbError` for anything that isn't "smb://host[/share[/…]]".
    public static func parse(_ id: String) throws -> SmbPath {
        guard isSmb(id) else { throw SmbError("Not a network share path: \(id)") }
        let parts = id.dropFirst(scheme.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { throw SmbError("No server in \(id)") }
        return SmbPath(host: first.lowercased(), share: parts.count > 1 ? parts[1] : nil, segments: Array(parts.dropFirst(2)))
    }

    /// Reads what people type or paste: "\\192.168.0.10\share\folder" (Windows), "smb://nas/share",
    /// "192.168.0.10/share" or just a host name. Returns nil when there's no host.
    public static func fromUserInput(_ text: String) -> SmbPath? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("smb:") { cleaned = String(cleaned.dropFirst(4)) }
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let host = first.lowercased()
        if host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) { return nil }
        return SmbPath(host: host, share: parts.count > 1 ? parts[1] : nil, segments: Array(parts.dropFirst(2)))
    }

    /// The UNC form (\\host\share\a\b), for display.
    public var unc: String {
        "\\\\" + host + (share.map { "\\" + $0 + (segments.isEmpty ? "" : "\\" + sharePath) } ?? "")
    }

    public var description: String { id }
}
