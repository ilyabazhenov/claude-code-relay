import Foundation

/// Persistent configuration for the Relay daemon.
///
/// Stored at `~/.claude/relay/config.json`. The `port` and `secret` are generated
/// on first launch and then reused. The hook scripts read the same file (indirectly,
/// via the values baked in at install time) so that they can reach the daemon and
/// authenticate with the shared secret.
struct Config: Codable {
    var port: Int
    var secret: String
    /// Rules describing which commands require an explicit approval. Populated in M2.
    var dangerRules: [String]

    // MARK: - M4 preferences (all optional for backward compatibility)

    /// Master switch for the command-approval feature (the PreToolUse Bash gate). When
    /// off, Relay stops intercepting commands entirely: every call passes through to
    /// Claude Code's normal permission flow, and the approval hook is stripped from
    /// settings.json so it adds no per-command overhead. Off by default — opt-in.
    var approvalsEnabled: Bool? = nil
    /// Auto-approve commands that match no danger rule. When false, such commands
    /// fall through to Claude Code's normal permission prompt.
    var autoAllowSafe: Bool? = nil
    /// One-tap canned replies shown on waiting sessions.
    var quickReplies: [String]? = nil
    /// Master toggles for the two notification kinds.
    var notifyApprovals: Bool? = nil
    var notifyReplies: Bool? = nil

    // MARK: - Usage tracking

    /// When on, the daemon runs a tiny loopback proxy and periodically fires a throwaway
    /// `claude -p` through it (only that ping is routed through Relay) to read the
    /// account's 5-hour / weekly rate-limit headers — works for any Claude client. On by
    /// default; the ping costs a sliver of the very limit it measures.
    var usageProxyEnabled: Bool? = nil
    /// Preferred loopback port for the usage proxy (0 = auto). Resolved on launch.
    var proxyPort: Int? = nil

    /// Which usage windows the menu-bar label shows. Stored as the raw value of
    /// `MenuBarUsageDisplay`; defaults to showing both.
    var menuBarUsageDisplay: String? = nil
    /// Whether the menu-bar numbers carry a `%` sign. Off by default.
    var menuBarShowPercent: Bool? = nil

    // MARK: - Localization

    /// UI language preference: "system" (default), "en", or "ru". Stored as the raw
    /// value of `AppLanguage`.
    var language: String? = nil

    // MARK: - Launch at login

    /// User's intent to start Relay automatically when they log in. The system login-item
    /// database (via `SMAppService`) is the real source of truth; this only mirrors what
    /// the user last chose so the settings screen has something to show. Off by default.
    var launchAtLogin: Bool? = nil

    var effectiveApprovalsEnabled: Bool { approvalsEnabled ?? false }
    var effectiveAutoAllowSafe: Bool { autoAllowSafe ?? true }
    var effectiveQuickReplies: [String] { quickReplies ?? Config.defaultQuickReplies }
    var effectiveNotifyApprovals: Bool { notifyApprovals ?? true }
    var effectiveNotifyReplies: Bool { notifyReplies ?? true }
    var effectiveUsageProxyEnabled: Bool { usageProxyEnabled ?? true }
    var effectiveProxyPort: Int { proxyPort ?? 0 }
    var effectiveLanguage: AppLanguage { language.flatMap(AppLanguage.init(rawValue:)) ?? .system }
    var effectiveMenuBarUsageDisplay: MenuBarUsageDisplay {
        menuBarUsageDisplay.flatMap(MenuBarUsageDisplay.init(rawValue:)) ?? .both
    }
    var effectiveMenuBarShowPercent: Bool { menuBarShowPercent ?? false }

    static let defaultQuickReplies: [String] = ["yes", "no", "continue", "go ahead"]

    static let defaultDangerRules: [String] = [
        "rm -rf",
        "rm -fr",
        "git push --force",
        "git push -f",
        "git reset --hard",
        "git clean -fd",
        "sudo ",
        "~/.ssh",
        "/.ssh/",
        "mkfs",
        "dd if=",
        ":>",           // truncate
        "DROP TABLE",
        "DROP DATABASE",
        "DELETE FROM",
        "chmod -R 777"
    ]
}

/// What the menu-bar label shows: both usage windows, only the 5-hour, or only the weekly.
enum MenuBarUsageDisplay: String, CaseIterable {
    case both
    case fiveHour
    case weekly

    var showsFiveHour: Bool { self != .weekly }
    var showsWeekly: Bool { self != .fiveHour }
}

/// Owns reading and writing the on-disk configuration.
enum ConfigStore {
    /// `~/.claude/relay`
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("relay", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// Load the existing config, or create a fresh one (with a random port + secret)
    /// if none exists yet. Any freshly generated values are written back to disk.
    static func loadOrCreate() throws -> Config {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: fileURL),
           var config = try? JSONDecoder().decode(Config.self, from: data) {
            // Backfill danger rules for configs written before M2.
            if config.dangerRules.isEmpty {
                config.dangerRules = Config.defaultDangerRules
                try? save(config)
            }
            return config
        }

        let config = Config(
            port: 0,                        // 0 = "pick a free port"; resolved by the server
            secret: randomSecret(),
            dangerRules: Config.defaultDangerRules
        )
        try save(config)
        return config
    }

    static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 32 bytes of cryptographically-random data, hex-encoded.
    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to a still-unpredictable-enough source; should never happen.
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
