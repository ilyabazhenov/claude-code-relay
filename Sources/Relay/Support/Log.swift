import Foundation
import os

/// Lightweight logging that writes both to the unified log (visible in Console.app,
/// subsystem `com.relay.menubar`) and to `~/.claude/relay/relay.log` for easy tailing
/// while debugging hooks.
enum Log {
    private static let logger = Logger(subsystem: "com.relay.menubar", category: "relay")

    private static let fileURL: URL = ConfigStore.directory
        .appendingPathComponent("relay.log", isDirectory: false)

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static let queue = DispatchQueue(label: "relay.log")

    private static func write(_ level: String, _ message: String) {
        queue.async {
            let line = "[\(timestamp())] \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
