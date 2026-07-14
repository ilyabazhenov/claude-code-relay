import Foundation

/// Injects text into a tmux pane via `tmux send-keys`.
///
/// The reply is sent in two steps: the literal text (`-l`, so no key names are
/// interpreted), then a separate `Enter` — mirroring how a person would type and
/// press return.
struct TmuxInjector {
    /// Path candidates for the tmux binary (Homebrew on Apple Silicon / Intel, or PATH).
    private static let candidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    static func tmuxPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["RELAY_TMUX"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum InjectError: Error, CustomStringConvertible {
        case tmuxNotFound
        case noPane
        case sendFailed(String)

        var description: String {
            switch self {
            case .tmuxNotFound: return "tmux not found"
            case .noPane:       return "no tmux pane for session"
            case .sendFailed(let s): return "send-keys failed: \(s)"
            }
        }
    }

    /// Sends `text` literally to `pane`, then presses Enter. Throws on any failure.
    func send(text: String, toPane pane: String) throws {
        guard let tmux = Self.tmuxPath() else { throw InjectError.tmuxNotFound }
        guard !pane.isEmpty else { throw InjectError.noPane }

        // 1) literal text — `--` guards against text that starts with '-'.
        try run(tmux, ["send-keys", "-t", pane, "-l", "--", text])
        // 2) submit
        try run(tmux, ["send-keys", "-t", pane, "Enter"])
        Log.info("injected \(text.count) chars into pane \(pane)")
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw InjectError.sendFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "status \(process.terminationStatus)"
            throw InjectError.sendFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
