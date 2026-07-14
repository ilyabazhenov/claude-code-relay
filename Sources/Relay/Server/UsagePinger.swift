import Foundation

/// Keeps the usage figures fresh by periodically firing one tiny `claude -p` request
/// **through the usage proxy**, so a fresh set of `anthropic-ratelimit-*` response
/// headers comes back. This is what makes usage tracking work for *any* Claude client
/// (Desktop / IDE / CLI): Relay measures the limits with its own throwaway request on
/// your auth, independent of how you actually use Claude.
///
/// Two guards keep this from being background noise:
///   1. **Activity gate.** It only pings if a real hook event (from any client) arrived
///      within `activityWindow`. Walk away and the pings stop on their own — we never
///      poll a quiet machine.
///   2. **Self-exclusion.** The ping runs in a dedicated cwd (`~/.claude/relay/ping`),
///      and the daemon ignores hook events from that directory, so a ping never counts
///      as "activity" (which would make the gate self-sustaining) and never shows up as
///      a session or notification.
///
/// The ping costs a sliver of the very limit it measures — one `max_tokens`-tiny Haiku
/// turn — which is negligible but non-zero; that's the accepted trade for freshness.
@MainActor
final class UsagePinger {
    /// The cwd every ping runs in. The daemon filters hook events from this path.
    static let pingDirectory: URL = ConfigStore.directory.appendingPathComponent("ping", isDirectory: true)

    private weak var daemon: Daemon?
    private var task: Task<Void, Never>?

    /// How often to ping, and how recently you must have worked for a ping to fire.
    private let intervalSeconds: UInt64 = 300      // 5 minutes
    private let activityWindow: TimeInterval = 3600 // 1 hour
    /// Kill a ping that hangs (network stall) rather than leak a process.
    private let pingTimeout: TimeInterval = 30

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: Self.pingDirectory, withIntermediateDirectories: true)
        task = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.intervalSeconds ?? 300
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                self?.tick()
            }
        }
        Log.info("usage pinger started (every \(intervalSeconds)s, gated on \(Int(activityWindow))s activity)")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Fire a ping immediately, bypassing the activity gate. Used by the `/ping-now`
    /// endpoint and any manual "refresh" affordance.
    func fireNow() {
        guard let daemon, daemon.boundProxyPort > 0 else { return }
        fire(proxyPort: daemon.boundProxyPort, timeout: pingTimeout)
    }

    private func tick() {
        guard let daemon else { return }
        guard daemon.config.effectiveUsageProxyEnabled else { return }
        guard daemon.boundProxyPort > 0 else { return }
        guard let last = daemon.lastUserActivityAt,
              Date().timeIntervalSince(last) <= activityWindow else {
            return   // machine is idle — stay quiet
        }
        fire(proxyPort: daemon.boundProxyPort, timeout: pingTimeout)
    }

    /// Spawn a throwaway `claude -p` through the proxy. Runs via a login shell so the
    /// user's PATH (and thus `claude`) resolves, and in the ping directory so the daemon
    /// can filter its hook events. Auth is handled by `claude` itself. `ANTHROPIC_BASE_URL`
    /// is set only on THIS subprocess — nothing else is routed through Relay.
    private func fire(proxyPort: UInt16, timeout: TimeInterval) {
        let dir = Self.pingDirectory
        DispatchQueue.global(qos: .background).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.currentDirectoryURL = dir
            let command = "printf 'hi' | "
                + "ANTHROPIC_BASE_URL='http://127.0.0.1:\(proxyPort)' "
                + "claude -p --model claude-haiku-4-5-20251001 >/dev/null 2>&1"
            process.arguments = ["-lc", command]
            do {
                try process.run()
            } catch {
                Log.error("usage ping failed to launch: \(error.localizedDescription)")
                return
            }
            // Watchdog: terminate a stuck ping.
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
        }
    }
}
