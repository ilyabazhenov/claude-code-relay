import Foundation
import Combine

/// The local daemon: owns configuration and the HTTP server, and routes incoming
/// hook requests. It authenticates every non-health request against the shared
/// secret (`X-Relay-Secret` header).
@MainActor
final class Daemon: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var boundPort: UInt16 = 0
    @Published private(set) var isRunning = false

    let sessions = SessionStore()
    let approvals: ApprovalCoordinator
    let replies: ReplyCoordinator
    let notifier = NotificationManager()
    let rateLimits = RateLimitStore()
    let tokens = TokenUsageStore()
    let stats = StatsStore()

    private var server: HTTPServer?
    private var usageProxy: UsageProxy?
    private var pinger: UsagePinger?
    /// Loopback port the usage proxy is listening on (0 = not running).
    private(set) var boundProxyPort: UInt16 = 0
    /// Timestamp of the last real hook event (from any client), used to gate usage pings
    /// so we never ping an idle machine. Ping-directory events are excluded.
    private(set) var lastUserActivityAt: Date?

    init() {
        let config = (try? ConfigStore.loadOrCreate()) ?? Config(port: 0, secret: "", dangerRules: [])
        self.config = config
        self.approvals = ApprovalCoordinator(sessions: sessions)
        self.replies = ReplyCoordinator(sessions: sessions)

        // Wire the coordinators and notifier together.
        approvals.notifier = notifier
        notifier.approvals = approvals
        notifier.replies = replies
        replies.notifier = notifier
        // Count each finished session into the persistent tally.
        sessions.onSessionCompleted = { [stats] in stats.recordCompletion() }
        applyConfigToRuntime()
    }

    /// Pushes the current config values into the live coordinators and notifier.
    private func applyConfigToRuntime() {
        approvals.approvalsEnabled = config.effectiveApprovalsEnabled
        approvals.dangerRules = config.dangerRules
        approvals.autoAllowSafe = config.effectiveAutoAllowSafe
        notifier.quickReplies = config.effectiveQuickReplies
        notifier.notifyApprovals = config.effectiveNotifyApprovals
        notifier.notifyReplies = config.effectiveNotifyReplies
        Localization.shared.apply(config.effectiveLanguage)
    }

    /// Applies an edited config: persists it and propagates to the runtime + the
    /// notification categories. Called from the settings screen.
    func updateConfig(_ mutate: (inout Config) -> Void) {
        let wasApprovalsEnabled = config.effectiveApprovalsEnabled
        var updated = config
        mutate(&updated)
        config = updated
        try? ConfigStore.save(updated)
        applyConfigToRuntime()
        notifier.reconfigureCategories()
        reconcileUsageProxy()
        // If the approvals master switch flipped, add/remove the PreToolUse hook so the
        // change also removes (or restores) the per-command overhead for new sessions.
        // Already-running sessions are handled immediately by the runtime guard above.
        if updated.effectiveApprovalsEnabled != wasApprovalsEnabled, isRunning {
            try? HooksInstaller.syncApprovalHook(enabled: updated.effectiveApprovalsEnabled,
                                                 port: Int(boundPort), secret: config.secret)
        }
        Log.info("config updated")
    }

    /// Brings the installed PreToolUse hook in line with `approvalsEnabled` at launch,
    /// so flipping the default (or editing config by hand) also adds/removes the hook —
    /// not just the runtime guard. Only touches settings.json when there's a real
    /// mismatch, to avoid needless rewrites (and backup churn) on every launch.
    private func reconcileApprovalHook() {
        guard HooksInstaller.isInstalled() else { return }
        let wanted = config.effectiveApprovalsEnabled
        guard HooksInstaller.isApprovalHookInstalled() != wanted else { return }
        try? HooksInstaller.syncApprovalHook(enabled: wanted, port: Int(boundPort), secret: config.secret)
    }

    func start() {
        guard server == nil else { return }
        let server = HTTPServer { [weak self] request in
            await self?.route(request) ?? .notFound
        }
        do {
            let port = try server.start(requestedPort: UInt16(config.port))
            self.server = server
            self.boundPort = port
            self.isRunning = true
            // Persist the resolved port so hooks (and next launch) can find us.
            if config.port != Int(port) {
                config.port = Int(port)
                try? ConfigStore.save(config)
            }
            notifier.configure()
            reconcileApprovalHook()
            Log.info("daemon listening on 127.0.0.1:\(port)")
        } catch {
            Log.error("failed to start server: \(error.localizedDescription)")
        }
        reconcileUsageProxy()
    }

    func stop() {
        server?.stop()
        server = nil
        pinger?.stop()
        usageProxy?.stop()
        usageProxy = nil
        boundProxyPort = 0
        isRunning = false
    }

    /// Bring the usage proxy + pinger in line with config: start them when usage tracking
    /// is enabled, stop them otherwise. Safe to call repeatedly. Only Relay's own ping
    /// traffic flows through the proxy — the pinger sets `ANTHROPIC_BASE_URL` on its own
    /// `claude -p` subprocess, so your real Claude sessions are never routed through us,
    /// and the numbers are captured no matter which client you actually use.
    private func reconcileUsageProxy() {
        guard config.effectiveUsageProxyEnabled else {
            pinger?.stop()
            usageProxy?.stop()
            usageProxy = nil
            boundProxyPort = 0
            return
        }
        if usageProxy == nil {
            let store = rateLimits
            let proxy = UsageProxy { headers in
                // Hop off the network queue onto the main actor to publish.
                Task { @MainActor in store.ingestHeaders(headers) }
            }
            do {
                let port = try proxy.start(requestedPort: UInt16(config.effectiveProxyPort))
                usageProxy = proxy
                boundProxyPort = port
                if config.proxyPort != Int(port) {
                    config.proxyPort = Int(port)
                    try? ConfigStore.save(config)
                }
                Log.info("usage proxy listening on 127.0.0.1:\(port)")
            } catch {
                Log.error("failed to start usage proxy: \(error.localizedDescription)")
            }
        }
        if pinger == nil { pinger = UsagePinger(daemon: self) }
        pinger?.start()
    }

    /// Force a fresh usage reading right now, bypassing the pinger's activity gate. Fires
    /// one throwaway ping through the proxy; the fresh `anthropic-ratelimit-*` headers it
    /// gets back flow into `rateLimits` a few seconds later. Returns `false` when usage
    /// tracking isn't running (proxy disabled), so callers can reflect that in the UI.
    @discardableResult
    func refreshUsageNow() -> Bool {
        guard config.effectiveUsageProxyEnabled, boundProxyPort > 0 else { return false }
        pinger?.fireNow()
        return true
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Health is unauthenticated so it can be probed easily.
        if request.method == "GET" && request.path == "/health" {
            return .ok("ok")
        }

        // Everything else requires the shared secret.
        guard authenticated(request) else {
            Log.error("rejected \(request.method) \(request.path): bad secret")
            return .unauthorized
        }

        switch (request.method, request.path) {
        case ("POST", "/event"):
            return handleEvent(request)
        case ("POST", "/approve"):
            return await handleApprove(request)
        case ("GET", "/sessions"):
            return handleSessionsSnapshot()
        case ("GET", "/usage"):
            return handleUsageSnapshot()
        case ("GET", "/usage/history"):
            return handleUsageHistory()
        case ("POST", "/usage"):
            return handleUsageIngest(request)
        case ("POST", "/ping-now"):
            let fired = refreshUsageNow()
            return .json(["ok": true, "fired": fired])
        case ("GET", "/pending"):
            return handlePendingSnapshot()
        case ("POST", "/resolve"):
            return handleResolve(request)
        case ("POST", "/reply"):
            return handleReply(request)
        default:
            return .notFound
        }
    }

    /// Submit a text reply for a waiting session (used by the reply notification /
    /// menu field, and by tests). Body: `{"session_id":"...","text":"..."}`.
    private func handleReply(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = request.jsonObject(),
              let sessionId = object["session_id"] as? String,
              let text = object["text"] as? String else {
            return .text("bad reply", status: 400)
        }
        let result = replies.submit(sessionId: sessionId, text: text)
        switch result {
        case .injected:
            return .json(["ok": true, "result": "injected"])
        case .notWaiting:
            return .json(["ok": false, "result": "not_waiting"])
        case .alreadyAnswering:
            return .json(["ok": false, "result": "already_answering"])
        case .failed(let message):
            return .json(["ok": false, "result": "failed", "error": message])
        }
    }

    /// Blocking PreToolUse approval. Returns the exact `hookSpecificOutput` JSON the
    /// hook should print, or an empty body to signal passthrough (fail-open / safe
    /// command when auto-allow is off).
    private func handleApprove(_ request: HTTPRequest) async -> HTTPResponse {
        guard let object = request.jsonObject(), let approvalRequest = ApprovalRequest(json: object) else {
            Log.error("POST /approve: unparseable payload")
            return HTTPResponse(status: 200, body: Data())   // fail-open
        }
        let outcome = await approvals.evaluate(approvalRequest)

        guard outcome.decision != .passthrough else {
            return HTTPResponse(status: 200, body: Data())   // empty → normal permission flow
        }

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": outcome.decision.rawValue,
                "permissionDecisionReason": outcome.reason
            ]
        ]
        return .json(payload)
    }

    /// Debug/testing: list pending approvals.
    private func handlePendingSnapshot() -> HTTPResponse {
        let list = approvals.pending.map { approval -> [String: Any] in
            [
                "id": approval.id,
                "session_id": approval.sessionId,
                "project": approval.sessionProject,
                "tool": approval.toolName,
                "command": approval.command,
                "matched_rule": approval.matchedRule ?? ""
            ]
        }
        return .json(["pending": list])
    }

    /// Debug/testing: resolve a pending approval as if a button were pressed.
    /// Body: `{"request_id": "...", "decision": "allow"|"deny"}`.
    private func handleResolve(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = request.jsonObject(),
              let id = object["request_id"] as? String,
              let decisionRaw = object["decision"] as? String,
              let decision = ApprovalDecision(rawValue: decisionRaw) else {
            return .text("bad resolve", status: 400)
        }
        approvals.resolve(id: id, decision: decision)
        return .json(["ok": true])
    }

    /// Debug/introspection: a JSON snapshot of the current session registry. Used by
    /// tests and useful for troubleshooting; requires the shared secret like any
    /// other endpoint.
    private func handleSessionsSnapshot() -> HTTPResponse {
        let snapshot = sessions.ordered.map { session -> [String: Any] in
            [
                "id": session.id,
                "project": session.projectName,
                "cwd": session.cwd,
                "state": session.state.rawValue,
                "tmux_pane": session.tmuxPane ?? "",
                "last_assistant_message": session.lastAssistantMessage ?? ""
            ]
        }
        return .json(["sessions": snapshot])
    }

    /// Debug/introspection: the latest usage snapshot.
    private func handleUsageSnapshot() -> HTTPResponse {
        guard let snap = rateLimits.snapshot else {
            return .json(["captured": false])
        }
        return .json([
            "captured": true,
            "captured_at_epoch": Int(snap.capturedAt.timeIntervalSince1970),
            "five_hour_percent": snap.fiveHourPercent as Any,
            "weekly_percent": snap.weeklyPercent as Any,
            "five_hour_reset_epoch": snap.fiveHourResetAt.map { Int($0.timeIntervalSince1970) } as Any,
            "weekly_reset_epoch": snap.weeklyResetAt.map { Int($0.timeIntervalSince1970) } as Any
        ])
    }

    /// Debug/introspection: the accumulated usage series and completed windows.
    private func handleUsageHistory() -> HTTPResponse {
        let samples = rateLimits.history.samples.map { sample -> [String: Any] in
            [
                "at_epoch": Int(sample.at.timeIntervalSince1970),
                "five_hour": sample.fiveHour as Any,
                "weekly": sample.weekly as Any
            ]
        }
        let windows = rateLimits.history.windows.map { window -> [String: Any] in
            [
                "kind": window.kind.rawValue,
                "started_at_epoch": Int(window.startedAt.timeIntervalSince1970),
                "ended_at_epoch": Int(window.endedAt.timeIntervalSince1970),
                "peak_fraction": window.peakFraction,
                "hit_limit": window.hitLimit
            ]
        }
        return .json(["samples": samples, "windows": windows])
    }

    /// Ingest a usage update from the status-line script. Body (any field optional):
    /// `{"five_hour_percent":23.5,"five_hour_reset_epoch":1738425600,
    ///   "seven_day_percent":41.2,"seven_day_reset_epoch":1738857600}`.
    private func handleUsageIngest(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = request.jsonObject() else {
            return .text("bad usage", status: 400)
        }
        func percent(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        func epoch(_ key: String) -> Date? {
            guard let seconds = (object[key] as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        rateLimits.ingestStatusline(
            fiveHourPercent: percent("five_hour_percent"),
            fiveHourReset: epoch("five_hour_reset_epoch"),
            weeklyPercent: percent("seven_day_percent"),
            weeklyReset: epoch("seven_day_reset_epoch")
        )
        return .json(["ok": true])
    }

    /// Handles a lifecycle event (SessionStart/End, Stop, Notification).
    private func handleEvent(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = request.jsonObject(), let event = HookEvent(json: object) else {
            Log.error("POST /event: unparseable or unrecognized payload")
            return .text("bad event", status: 400)
        }

        // Relay's own usage-ping sessions run in a dedicated cwd: ignore them entirely so
        // they never create a phantom session and — crucially — never count as activity,
        // which would let the ping gate sustain itself on an idle machine.
        if event.cwd == UsagePinger.pingDirectory.path {
            return .json(["ok": true, "ignored": "ping"])
        }
        lastUserActivityAt = Date()

        sessions.apply(event)

        switch event.name {
        case .stop:
            // Fold this turn's exact per-model token usage in from the transcript.
            tokens.ingest(sessionId: event.sessionId, transcriptPath: event.transcriptPath)
            // Claude is waiting for a text reply — surface a notification with a reply
            // field so the user can answer without touching the terminal.
            if let session = sessions.session(id: event.sessionId) {
                let question = resolveQuestion(for: session)
                notifier.showReply(ReplyPrompt(sessionId: session.id,
                                               project: session.projectName,
                                               question: question))
            }
        case .userPromptSubmit:
            // The user answered directly — take down any lingering reply banner.
            notifier.dismissReply(sessionId: event.sessionId)
        default:
            break
        }
        return .json(["ok": true])
    }

    /// The assistant's question to display: the message the Stop hook delivered, or a
    /// transcript fallback, or a generic prompt.
    private func resolveQuestion(for session: Session) -> String {
        if let message = session.lastAssistantMessage, !message.isEmpty {
            return message
        }
        if let path = session.transcriptPath,
           let message = TranscriptReader.lastAssistantMessage(path: path), !message.isEmpty {
            return message
        }
        return "Claude is waiting for your reply."
    }

    private func authenticated(_ request: HTTPRequest) -> Bool {
        guard !config.secret.isEmpty else { return false }
        let provided = request.headers["x-relay-secret"] ?? ""
        return Self.constantTimeEquals(provided, config.secret)
    }

    /// Compare two strings without an early byte-by-byte exit, so a mismatch's position
    /// can't be inferred from timing. The length check only leaks the length, which for
    /// our fixed 64-hex-char secret is not sensitive.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
