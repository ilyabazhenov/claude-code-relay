import Foundation
import Combine

/// The verdict Relay hands back for a tool call.
enum ApprovalDecision: String {
    case allow      // permissionDecision: "allow"
    case deny       // permissionDecision: "deny"
    case ask        // permissionDecision: "ask" — escalate to Claude's own prompt
    case passthrough // no decision emitted; Claude's normal permission flow applies
}

/// The full outcome for a request: a decision plus a human-readable reason.
struct ApprovalOutcome {
    let decision: ApprovalDecision
    let reason: String
}

/// An incoming PreToolUse approval request, as posted by `pretooluse.sh`.
struct ApprovalRequest {
    let sessionId: String
    let cwd: String
    let tmuxPane: String?
    let toolName: String
    let command: String

    init?(json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        self.cwd = (json["cwd"] as? String) ?? ""
        self.tmuxPane = (json["tmux_pane"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.toolName = (json["tool_name"] as? String) ?? "tool"
        self.command = (json["command"] as? String) ?? ""
    }
}

/// Coordinates blocking PreToolUse approvals.
///
/// Safe commands are auto-allowed (configurable). Dangerous ones create a
/// `PendingApproval`, surface a notification + menu card, and **park the hook's HTTP
/// request** (via a continuation) until the user decides or a timeout elapses — in
/// which case we pass through (fail-open).
@MainActor
final class ApprovalCoordinator: ObservableObject {
    private let sessions: SessionStore
    weak var notifier: NotificationManager?

    /// Master switch for the whole approval gate. When false, `evaluate` passes every
    /// command straight through — Relay stays out of the loop entirely.
    var approvalsEnabled: Bool = true
    /// Danger rules, kept in sync with config.
    var dangerRules: [String] = []
    /// When true, commands that match no danger rule are auto-approved. When false,
    /// they pass through to Claude Code's normal permission flow.
    var autoAllowSafe: Bool = true

    /// Server-side wait before giving up and passing through. Must be shorter than
    /// the hook's curl `--max-time` so that *we* decide the timeout, not curl.
    private let waitTimeout: TimeInterval = 270

    @Published private(set) var pending: [PendingApproval] = []
    private var continuations: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]

    init(sessions: SessionStore) {
        self.sessions = sessions
    }

    // MARK: - Evaluation (called from the /approve route)

    func evaluate(_ request: ApprovalRequest) async -> ApprovalOutcome {
        // Feature switched off entirely — never intercept, just hand back to Claude's
        // own permission flow. (New sessions won't even call us; this covers sessions
        // whose hook was installed before the user turned approvals off.)
        guard approvalsEnabled else {
            return ApprovalOutcome(decision: .passthrough, reason: "")
        }

        sessions.ensure(id: request.sessionId, cwd: request.cwd, tmuxPane: request.tmuxPane)

        let matched = DangerRules.firstMatch(command: request.command, rules: dangerRules)

        guard let matchedRule = matched else {
            // Not dangerous.
            if autoAllowSafe {
                Log.info("auto-allow [\(request.toolName)] \(request.command.prefix(60))")
                return ApprovalOutcome(decision: .allow, reason: "Auto-approved by Relay (no danger rule matched)")
            } else {
                return ApprovalOutcome(decision: .passthrough, reason: "")
            }
        }

        // Dangerous — ask the user.
        let approval = PendingApproval(
            id: UUID().uuidString,
            sessionId: request.sessionId,
            toolName: request.toolName,
            command: request.command,
            matchedRule: matchedRule,
            createdAt: Date(),
            cwd: request.cwd
        )
        Log.info("approval requested [\(request.toolName)] rule=\(matchedRule): \(request.command.prefix(80))")

        let decision = await park(approval)

        switch decision {
        case .allow:
            return ApprovalOutcome(decision: .allow, reason: "Approved by user via Relay")
        case .deny:
            return ApprovalOutcome(decision: .deny, reason: "Denied by user via Relay")
        case .ask:
            return ApprovalOutcome(decision: .ask, reason: "Escalated by Relay")
        case .passthrough:
            return ApprovalOutcome(decision: .passthrough, reason: "")
        }
    }

    /// Parks the request until the user resolves it or the timeout fires.
    private func park(_ approval: PendingApproval) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            continuations[approval.id] = continuation
            pending.append(approval)
            sessions.setPendingApproval(approval)
            notifier?.showApproval(approval)

            // Timeout → pass through (fail-open).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.waitTimeout ?? 270) * 1_000_000_000))
                if self?.continuations[approval.id] != nil {
                    Log.info("approval \(approval.id.prefix(8)) timed out → passthrough")
                    self?.resolve(id: approval.id, decision: .passthrough)
                }
            }
        }
    }

    // MARK: - Resolution (called from notification actions / menu buttons / debug)

    func resolve(id: String, decision: ApprovalDecision) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if let approval = pending.first(where: { $0.id == id }) {
            sessions.clearPendingApproval(sessionId: approval.sessionId)
            notifier?.dismiss(id: id)
            Log.info("approval \(id.prefix(8)) resolved → \(decision.rawValue)")
        }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: decision)
    }

    func approval(id: String) -> PendingApproval? {
        pending.first { $0.id == id }
    }
}
