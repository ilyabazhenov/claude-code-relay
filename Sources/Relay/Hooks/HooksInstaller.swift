import Foundation

/// Installs / uninstalls Relay's Claude Code hooks.
///
/// - Writes the hook scripts into `~/.claude/relay/` with the daemon's port and
///   secret baked in.
/// - Merges hook registrations into `~/.claude/settings.json` **without** clobbering
///   the user's existing hooks (a timestamped backup is taken first).
/// - Uninstall removes only the entries Relay added (identified by the script path).
enum HooksInstaller {
    /// Absolute path used to identify Relay's own hook entries in settings.json.
    static var scriptsDir: URL { ConfigStore.directory }
    static var eventScriptPath: String {
        scriptsDir.appendingPathComponent("event.sh").path
    }
    static var preToolUseScriptPath: String {
        scriptsDir.appendingPathComponent("pretooluse.sh").path
    }
    static var statuslineScriptPath: String {
        scriptsDir.appendingPathComponent("statusline.sh").path
    }

    /// Tools whose Bash-like calls are routed through the approval hook.
    private static let approvalMatcher = "Bash"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The lifecycle events Relay registers a hook for. Each maps to the event script.
    private static let lifecycleEvents = ["SessionStart", "SessionEnd", "Stop", "Notification", "UserPromptSubmit"]

    // MARK: - Status

    /// True if `settings.json` currently references any of Relay's hook scripts.
    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        let dirPrefix = scriptsDir.path + "/"
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let inner = (group["hooks"] as? [[String: Any]]) ?? []
                if inner.contains(where: { ($0["command"] as? String)?.hasPrefix(dirPrefix) == true }) {
                    return true
                }
            }
        }
        return false
    }

    /// True if the PreToolUse approval hook specifically is present in settings.json.
    /// (Distinct from `isInstalled()`, which is true if *any* Relay hook is present.)
    static func isApprovalHookInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let groups = (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] else {
            return false
        }
        return groups.contains { group in
            let inner = (group["hooks"] as? [[String: Any]]) ?? []
            return inner.contains { ($0["command"] as? String) == preToolUseScriptPath }
        }
    }

    // MARK: - Install

    static func install(port: Int, secret: String, approvalsEnabled: Bool = true) throws {
        try writeScripts(port: port, secret: secret)
        try withSettings { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            for event in lifecycleEvents {
                upsertGroup(in: &hooks, event: event, matcher: nil,
                            command: eventScriptPath, timeout: 5)
            }
            if approvalsEnabled {
                // Blocking approval hook for Bash tool calls (M2). The generous timeout
                // must exceed the hook's curl --max-time; the daemon caps the real wait.
                upsertGroup(in: &hooks, event: "PreToolUse", matcher: approvalMatcher,
                            command: preToolUseScriptPath, timeout: 600)
            } else {
                removeEntry(from: &hooks, command: preToolUseScriptPath)
            }
            root["hooks"] = hooks
            installStatusLine(in: &root)
        }
        Log.info("hooks installed (port \(port), approvals \(approvalsEnabled ? "on" : "off"))")
    }

    /// Adds or removes *only* the PreToolUse approval hook, leaving the lifecycle and
    /// status-line hooks untouched. Called when the user flips the approvals master
    /// switch while hooks are already installed. No-op if hooks aren't installed.
    static func syncApprovalHook(enabled: Bool, port: Int, secret: String) throws {
        guard isInstalled() else { return }
        if enabled {
            // The script may have been removed when approvals were last turned off.
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try writeScript(HookScripts.render(HookScripts.preToolUseScript, port: port, secret: secret),
                            to: preToolUseScriptPath)
        }
        try withSettings { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            if enabled {
                upsertGroup(in: &hooks, event: "PreToolUse", matcher: approvalMatcher,
                            command: preToolUseScriptPath, timeout: 600)
            } else {
                removeEntry(from: &hooks, command: preToolUseScriptPath)
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        if !enabled { try? FileManager.default.removeItem(atPath: preToolUseScriptPath) }
        Log.info("approval hook \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Uninstall

    static func uninstall() throws {
        try withSettings { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            removeRelayEntries(from: &hooks)
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            removeStatusLine(in: &root)
        }
        // Leave the scripts dir/config in place (harmless); only remove scripts.
        try? FileManager.default.removeItem(atPath: eventScriptPath)
        try? FileManager.default.removeItem(atPath: preToolUseScriptPath)
        try? FileManager.default.removeItem(atPath: statuslineScriptPath)
        Log.info("hooks uninstalled")
    }

    // MARK: - Script files

    private static func writeScripts(port: Int, secret: String) throws {
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try writeScript(HookScripts.render(HookScripts.eventScript, port: port, secret: secret),
                        to: eventScriptPath)
        try writeScript(HookScripts.render(HookScripts.preToolUseScript, port: port, secret: secret),
                        to: preToolUseScriptPath)
        try writeScript(HookScripts.render(HookScripts.statuslineScript, port: port, secret: secret),
                        to: statuslineScriptPath)
    }

    private static func writeScript(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - settings.json merge

    /// Loads settings.json (or `{}`), takes a one-time backup, hands the whole mutable
    /// root object to `mutate`, and writes the result back atomically.
    private static func withSettings(_ mutate: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
            try backup(data)
        }

        mutate(&root)

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Status line (usage meters)

    /// Registers Relay's status-line command — but only if the user hasn't set their own.
    /// Claude Code's `statusLine` is a single command, so we won't clobber a custom one;
    /// in that case the usage figures simply won't flow (logged for visibility).
    private static func installStatusLine(in root: inout [String: Any]) {
        let existing = (root["statusLine"] as? [String: Any])?["command"] as? String
        let ours = scriptsDir.path + "/"
        if existing == nil || existing?.hasPrefix(ours) == true {
            root["statusLine"] = [
                "type": "command",
                "command": statuslineScriptPath,
                "padding": 0
            ]
        } else {
            Log.info("statusLine already customized; leaving it (usage meters need Relay's status line)")
        }
    }

    /// Removes Relay's status-line entry, leaving a user's custom one intact.
    private static func removeStatusLine(in root: inout [String: Any]) {
        let ours = scriptsDir.path + "/"
        if let command = (root["statusLine"] as? [String: Any])?["command"] as? String,
           command.hasPrefix(ours) {
            root.removeValue(forKey: "statusLine")
        }
    }

    private static func backup(_ data: Data) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.relay-backup-\(stamp)")
        // Only create one backup per second; ignore if it already exists.
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? data.write(to: backupURL)
        }
    }

    // MARK: - Hooks object manipulation

    /// Inserts or updates Relay's hook group for `event`, matching on our `command`
    /// path so re-installs are idempotent and user hooks are untouched.
    private static func upsertGroup(in hooks: inout [String: Any],
                                    event: String,
                                    matcher: String?,
                                    command: String,
                                    timeout: Int) {
        var groups = (hooks[event] as? [[String: Any]]) ?? []

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout
        ]

        // Find an existing group that already contains our command.
        if let index = groups.firstIndex(where: { group in
            let inner = (group["hooks"] as? [[String: Any]]) ?? []
            return inner.contains { ($0["command"] as? String) == command }
        }) {
            groups[index]["hooks"] = [hookEntry]
            if let matcher { groups[index]["matcher"] = matcher }
        } else {
            var group: [String: Any] = ["hooks": [hookEntry]]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
        }

        hooks[event] = groups
    }

    /// Removes just the hook entries whose command equals `command`, across every event.
    /// Empties out groups and events that become empty. Used to strip a single hook
    /// (the approval gate) without disturbing the rest.
    private static func removeEntry(from hooks: inout [String: Any], command: String) {
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                let inner = ((group["hooks"] as? [[String: Any]]) ?? []).filter {
                    ($0["command"] as? String) != command
                }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
    }

    /// Strips every hook entry whose command lives in Relay's scripts dir. Empties
    /// out groups and events that become empty.
    private static func removeRelayEntries(from hooks: inout [String: Any]) {
        let dirPrefix = scriptsDir.path + "/"
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                let inner = ((group["hooks"] as? [[String: Any]]) ?? []).filter { entry in
                    let command = (entry["command"] as? String) ?? ""
                    return !command.hasPrefix(dirPrefix)
                }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
    }
}
