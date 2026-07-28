import Foundation
import os

/// Lightweight logging that writes both to the unified log (visible in Console.app,
/// subsystem `com.relay.menubar`) and to `~/.claude/relay/relay.log` for easy tailing
/// while debugging hooks.
enum Log {
    private static let logger = Logger(subsystem: "com.relay.menubar", category: "relay")

    /// Directory the log file lives in. Under test it's a throwaway one.
    ///
    /// The stores take an injected directory so a test never touches `~/.claude/relay`, but
    /// `Log` is reached through static members from every layer and has no such seam — so a
    /// `swift test` run appended its lines straight into the real `relay.log`, interleaved
    /// with the live daemon's. Reading that file back is a normal way to diagnose the app,
    /// and fake entries in it cost real debugging time.
    private static let directory: URL = isRunningTests
        ? FileManager.default.temporaryDirectory.appendingPathComponent("relay-tests", isDirectory: true)
        : ConfigStore.directory

    /// Where the tail-able log ends up. Internal so a test can assert it stays out of the
    /// user's directory.
    static let fileURL: URL = directory.appendingPathComponent("relay.log", isDirectory: false)

    /// Whether this process is a test run. XCTest sets its environment before any test code
    /// executes, so this holds no matter which test happens to log first; the class lookup
    /// also covers a swift-testing run that doesn't export the variables.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

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
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
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
