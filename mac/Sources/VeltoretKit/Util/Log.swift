import Foundation
import os

/// App logging. Errors also go to ~/Library/Application Support/Veltoret/logs/errors.log (as on Windows).
/// Never log what a paired device sends, passwords, tokens or file contents.
public enum Log {
    private static let logger = Logger(subsystem: "com.pntapps.veltoret", category: "app")
    private static let lock = NSLock()

    public static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }

    public static func error(_ error: Error, _ context: String = "") {
        let text = context.isEmpty ? "\(error)" : "\(context): \(error)"
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(message)
    }

    private static func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let dir = AppPaths.ensure(AppPaths.logs)
        let file = dir.appendingPathComponent("errors.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            // Keep the log small.
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: file)
            }
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}

/// Milliseconds since the epoch (the database and Android use epoch ms everywhere).
public func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
