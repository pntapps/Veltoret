import Foundation
import VeltoretKit
import VeltoretPlayerKit

/// Error card messages (Android PlayerViewModel.describe / Windows PlayerErrors), first match wins. libVLC reports
/// no reason, so the cause comes from the stream server's last source error and libVLC's last error log lines.
enum PlayerErrors {
    static let noAccount = "This file isn't linked to a Google account"

    /// The error and everything it wraps (Swift errors carrying `underlying`/`error`/`cause`, NSError's
    /// NSUnderlyingErrorKey).
    static func chain(_ error: Error?) -> [Error] {
        var out: [Error] = []
        var current = error
        var depth = 0
        while let e = current, depth < 8 {
            out.append(e)
            depth += 1
            current = nil
            for child in Mirror(reflecting: e).children {
                if let label = child.label, ["underlying", "underlyingError", "error", "cause", "inner"].contains(label),
                   let inner = child.value as? Error {
                    current = inner
                    break
                }
            }
            if current == nil, let inner = (e as NSError).userInfo[NSUnderlyingErrorKey] as? Error { current = inner }
        }
        return out
    }

    private static func typeName(_ e: Error) -> String { String(describing: type(of: e)) }

    /// The user sentence an error carries (`message` property, LocalizedError, or the description).
    static func message(_ e: Error) -> String {
        if let m = Mirror(reflecting: e).children.first(where: { $0.label == "message" })?.value as? String { return m }
        if let l = e as? LocalizedError, let d = l.errorDescription { return d }
        return (e as NSError).localizedDescription
    }

    private static func isAuth(_ e: Error) -> Bool {
        let name = typeName(e)
        if name.contains("AuthRequired") { return true }
        let m = message(e)
        return m.contains("401") && m.lowercased().contains("unauthor")
    }

    private static func isSmb(_ e: Error) -> Bool { typeName(e).hasPrefix("Smb") }

    private static func isIo(_ e: Error) -> Bool {
        if e is URLError || e is POSIXError || e is CocoaError { return true }
        let domain = (e as NSError).domain
        return domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain || domain == NSCocoaErrorDomain
            || typeName(e).contains("IO")
    }

    private static func isFileMissing(_ e: Error) -> Bool {
        if let c = e as? CocoaError {
            return [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission, .fileReadUnknown].contains(c.code)
        }
        let ns = e as NSError
        return ns.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(EACCES), Int(EPERM), Int(EIO)].contains(ns.code)
    }

    static func looksLikeDecoderError(_ log: [String]) -> Bool {
        log.contains { l in
            let s = l.lowercased()
            return s.contains("decod") || s.contains("codec") || s.contains("hardware") || s.contains("videotoolbox")
        }
    }

    /// - Parameters:
    ///   - error: what the stream source (or opening the stream) threw, if anything.
    ///   - log: libVLC's recent error lines, oldest first.
    ///   - video: codec FourCC, profile and size of the video track, when known.
    static func describe(_ error: Error?, log: [String], account: String?, fileId: String, online: Bool,
                         video: (fourCC: String, profile: Int, width: Int, height: Int)? = nil,
                         audioFourCC: String? = nil) -> String {
        let chain = chain(error)
        if chain.contains(where: isAuth) { return "Your Google account needs to be reconnected in Settings." }
        if let smb = chain.first(where: isSmb) {
            let m = message(smb).trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "Couldn't read this file from the server." : m
        }
        let smb = Accounts.isSmb(account)
        let local = Accounts.isLocal(account)
        if smb && !online {
            return "You're offline. This video is on a network server, so this device needs to be on the same network."
        }
        if smb && chain.contains(where: isIo) {
            return "Couldn't read this video from the network server. Check that it's on and that you're on the same Wi-Fi."
        }
        if !local && !online {
            return "You're offline. This video is on Google Drive, so it needs an internet connection. Videos on this device still play."
        }
        if local && (chain.contains(where: isFileMissing) || !FileManager.default.fileExists(atPath: fileId)) {
            return "This file isn't available on this device. If it's on a USB drive or another disk, make sure it's connected."
        }

        let messages = chain.map(message).joined(separator: "\n")
        if messages.contains("403") {
            return "Google Drive refused the stream (403). The file may have hit its daily download limit — try again later."
        }
        if messages.contains("404") { return "This file is no longer in Google Drive." }
        if !chain.isEmpty && chain.contains(where: { isIo($0) || $0 is CancellationError }) {
            return "Network problem. Check your connection and retry."
        }
        if !chain.isEmpty && !local { return "Network problem. Check your connection and retry." }

        let logText = log.joined(separator: "\n")
        let decoder = looksLikeDecoderError(log)
        if logText.lowercased().contains("demux") && !decoder {
            return "This file's container format isn't supported (for example WMV/ASF or RealMedia)."
        }
        if decoder {
            if video == nil && audioFourCC == nil { return "This device can't decode this file's format." }
            if let a = audioFourCC, logText.lowercased().contains(a.trimmingCharacters(in: .whitespaces).lowercased()) {
                return "This device can't decode the \(MediaFormats.audioCodec(a) ?? a.uppercased()) audio track. Try another audio track."
            }
            if let v = video {
                let codec = MediaFormats.videoCodec(v.fourCC) ?? v.fourCC.uppercased()
                if codec == "HEVC" && v.profile == 2 {
                    return "This video is 10-bit HEVC (H.265 Main 10), and this device has no decoder for it. An 8-bit H.264 or HEVC version of the file will play."
                }
                if codec == "Dolby Vision" { return "This video is Dolby Vision, which this device can't decode." }
                let size = v.width > 0 ? " at \(v.width)×\(v.height)" : ""
                return "This device can't decode \(codec) video\(size)."
            }
            return "This device can't decode this file's format."
        }
        return "Couldn't play this video."
    }
}
