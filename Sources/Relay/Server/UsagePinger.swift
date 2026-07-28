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
///
/// **Fable's weekly window is the awkward one.** Its `…-7d_oi-*` headers come back only on
/// a response *from Fable* — Haiku omits them, and so does Opus — so the cheap Haiku ping
/// can never see it. Measuring that limit therefore spends the very allowance it reports,
/// and on a plan that meters Fable separately it's usually the scarcest one. We settle it
/// by rate: Haiku every tick keeps the 5h/7d figures live, Fable only every
/// `fableEveryNTicks`-th tick. A weekly window moves slowly enough that a half-hour-old
/// reading is still a good one, and the number holds between refreshes rather than blanking.
@MainActor
final class UsagePinger {
    /// The cwd every ping runs in. The daemon filters hook events from this path.
    static let pingDirectory: URL = ConfigStore.directory.appendingPathComponent("ping", isDirectory: true)

    private weak var daemon: Daemon?
    private var task: Task<Void, Never>?

    /// How often to ping, and how recently you must have worked for a ping to fire. The
    /// activity window is shared: the UI needs it to tell "the feed is broken" apart from
    /// "you walked away and we deliberately stopped pinging".
    private let intervalSeconds: UInt64 = 300      // 5 minutes
    static let activityWindow: TimeInterval = 3600 // 1 hour
    /// Kill a ping that hangs (network stall) rather than leak a process.
    private let pingTimeout: TimeInterval = 30

    /// The cheap model used for the routine ping, and the one whose responses are the only
    /// source of Fable's weekly window.
    private let cheapModel = "claude-haiku-4-5-20251001"
    private let fableModel = "claude-fable-5"

    /// Fable is pinged on every Nth tick — 6 × 5 min = every half hour.
    private static let fableEveryNTicks = 6
    /// Starts already due, so the first tick after launch reads Fable rather than waiting
    /// half an hour. Must start *at* the threshold, not above it: this counter is
    /// incremented before it's tested, and a sentinel like `Int.max` would trap on overflow.
    private var ticksSinceFablePing = UsagePinger.fableEveryNTicks

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
        Log.info("usage pinger started (every \(intervalSeconds)s, gated on \(Int(Self.activityWindow))s activity)")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Fire a ping immediately, bypassing the activity gate. Used by the `/ping-now`
    /// endpoint and the panel's refresh button. A manual refresh is an explicit "tell me
    /// where I stand", so it always includes Fable — the whole point is the full picture.
    func fireNow() {
        guard let daemon, daemon.boundProxyPort > 0 else { return }
        ticksSinceFablePing = 0
        fire(proxyPort: daemon.boundProxyPort, model: cheapModel, timeout: pingTimeout)
        fire(proxyPort: daemon.boundProxyPort, model: fableModel, timeout: pingTimeout)
    }

    private func tick() {
        guard let daemon else { return }
        guard daemon.config.effectiveUsageProxyEnabled else { return }
        guard daemon.boundProxyPort > 0 else { return }
        guard let last = daemon.lastUserActivityAt,
              Date().timeIntervalSince(last) <= Self.activityWindow else {
            return   // machine is idle — stay quiet
        }
        fire(proxyPort: daemon.boundProxyPort, model: cheapModel, timeout: pingTimeout)

        // Fable's window costs Fable tokens to read, so it rides a slower cadence. Counting
        // ticks (not wall time) means an idle machine doesn't accrue a debt of pings.
        ticksSinceFablePing += 1
        if ticksSinceFablePing >= Self.fableEveryNTicks {
            ticksSinceFablePing = 0
            fire(proxyPort: daemon.boundProxyPort, model: fableModel, timeout: pingTimeout)
        }
    }

    /// Spawn a throwaway `claude -p` through the proxy. Runs via a login shell so the
    /// user's PATH (and thus `claude`) resolves, and in the ping directory so the daemon
    /// can filter its hook events. Auth is handled by `claude` itself. `ANTHROPIC_BASE_URL`
    /// is set only on THIS subprocess — nothing else is routed through Relay.
    ///
    /// stderr is captured rather than discarded: a ping that fails (an expired login is the
    /// usual one) produces no headers and would otherwise fail *silently* — the usage
    /// figures simply freeze, which is indistinguishable from "you haven't used anything".
    /// The outcome goes to `daemon.recordPingOutcome` so the UI can say so out loud.
    private func fire(proxyPort: UInt16, model: String, timeout: TimeInterval) {
        let dir = Self.pingDirectory
        DispatchQueue.global(qos: .background).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.currentDirectoryURL = dir
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            let command = "printf 'hi' | "
                + "ANTHROPIC_BASE_URL='http://127.0.0.1:\(proxyPort)' "
                + "claude -p --model \(model) >/dev/null"
            process.arguments = ["-lc", command]
            do {
                try process.run()
            } catch {
                let reason = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.daemon?.recordPingOutcome(.failed(reason))
                }
                return
            }
            // Watchdog: terminate a stuck ping.
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            // Drain stderr before waiting: a pipe that fills would deadlock the child.
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // A watchdog kill is the one failure with no stderr to explain it, and the
            // process itself records it — no need for a flag shared across two queues.
            let outcome: PingOutcome
            if process.terminationReason == .uncaughtSignal {
                outcome = .failed("timed out after \(Int(timeout))s")
            } else if process.terminationStatus != 0 {
                outcome = .failed(Self.firstLine(errData) ?? "exit \(process.terminationStatus)")
            } else {
                outcome = .succeeded
            }
            Task { @MainActor [weak self] in
                self?.daemon?.recordPingOutcome(outcome)
            }
        }
    }

    /// The first non-empty line of captured stderr, trimmed to something loggable. `claude`
    /// puts the useful part first (`Not logged in · Please run /login`); the rest is noise.
    private static func firstLine(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return String(line.prefix(200))
    }
}

/// How a single ping ended. `failed` carries a human-readable reason for the log and the UI.
enum PingOutcome: Equatable {
    case succeeded
    case failed(String)
}

/// Why the usage figures on screen shouldn't be read as current.
enum UsageFeedTrouble: Equatable {
    /// Pings are coming back with an error — the reason is `claude`'s own first stderr line,
    /// which for the common case is `Not logged in · Please run /login`.
    case pingFailing(String)
    /// Pings aren't erroring, but nothing fresh has arrived while you've been working.
    case noReading(minutes: Int)
}
