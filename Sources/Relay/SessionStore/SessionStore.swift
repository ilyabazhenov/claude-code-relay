import Foundation
import Combine

/// In-memory registry of all known Claude Code sessions, keyed by `session_id`.
/// Owned by the daemon and observed by the menu UI.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// Invoked once each time a session transitions into `ended` (deduped: a session that
    /// is already ended won't fire it again). The daemon wires this to `StatsStore` so the
    /// "chats finished" tally survives the 30s pruning of ended sessions.
    var onSessionCompleted: (() -> Void)?

    /// How long an `ended` session lingers in the list before being pruned.
    private let endedRetention: TimeInterval = 30

    // MARK: - Ordered access

    /// Sessions ordered for display: waiting first, then working, then ended;
    /// ties broken by most-recently-updated.
    var ordered: [Session] {
        sessions.sorted { a, b in
            if a.state.sortRank != b.state.sortRank {
                return a.state.sortRank < b.state.sortRank
            }
            return a.lastUpdated > b.lastUpdated
        }
    }

    /// Sessions waiting on you (reply or approval) — the number badged in the menu bar.
    var waitingCount: Int {
        sessions.filter { $0.state.isWaiting }.count
    }

    // MARK: - Lookup / mutation helpers

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Fetches an existing session or creates a fresh one in the `working` state.
    private func upsert(id: String, cwd: String, tmuxPane: String?) -> Int {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if !cwd.isEmpty, sessions[index].cwd != cwd {
                sessions[index].cwd = cwd
                sessions[index].gitBranch = GitInfo.branch(cwd: cwd)
            }
            if let tmuxPane, !tmuxPane.isEmpty { sessions[index].tmuxPane = tmuxPane }
            sessions[index].lastUpdated = Date()
            return index
        }
        let session = Session(
            id: id,
            cwd: cwd,
            tmuxPane: tmuxPane,
            state: .working,
            transcriptPath: nil,
            lastAssistantMessage: nil,
            notificationMessage: nil,
            lastUpdated: Date(),
            waitingSince: nil,
            gitBranch: GitInfo.branch(cwd: cwd),
            pendingApproval: nil,
            taskTitle: nil
        )
        sessions.append(session)
        return sessions.count - 1
    }

    /// Updates a session's state and maintains `waitingSince` (set on entering a
    /// waiting state, cleared otherwise).
    private func setState(_ index: Int, _ newState: SessionState) {
        let wasWaiting = sessions[index].state.isWaiting
        sessions[index].state = newState
        if newState.isWaiting {
            if !wasWaiting || sessions[index].waitingSince == nil {
                sessions[index].waitingSince = Date()
            }
        } else {
            sessions[index].waitingSince = nil
        }
    }

    // MARK: - Event handling

    /// Applies a lifecycle event coming from a hook. Returns the affected session id.
    @discardableResult
    func apply(_ event: HookEvent) -> String {
        let index = upsert(id: event.sessionId, cwd: event.cwd, tmuxPane: event.tmuxPane)

        // The first user prompt captions the session for the rest of its life, so two
        // background sessions in the same folder stay distinguishable.
        if sessions[index].taskTitle == nil,
           let title = Self.taskTitle(from: event.prompt) {
            sessions[index].taskTitle = title
        }

        switch event.name {
        case .sessionStart:
            setState(index, .working)

        case .sessionEnd:
            let wasEnded = sessions[index].state == .ended
            setState(index, .ended)
            sessions[index].pendingApproval = nil
            schedulePrune(id: event.sessionId)
            if !wasEnded { onSessionCompleted?() }

        case .stop:
            // Ball is in the user's court: Claude produced a message and is waiting.
            setState(index, .waitingText)
            if let message = event.lastAssistantMessage, !message.isEmpty {
                sessions[index].lastAssistantMessage = message
            }
            if let transcript = event.transcriptPath {
                sessions[index].transcriptPath = transcript
            }

        case .notification:
            sessions[index].notificationMessage = event.message
            // A Notification means Claude needs attention. If we're not already
            // parked on a specific approval/text wait, surface it as a text wait.
            if sessions[index].state == .working {
                setState(index, .waitingText)
            }

        case .userPromptSubmit:
            // The user answered (in the terminal or via Relay). Clear the wait so the
            // counter/card/notification don't linger. Approvals have their own flow.
            if sessions[index].state == .waitingText {
                setState(index, .working)
                sessions[index].lastAssistantMessage = nil
            }
        }

        Log.info("session \(event.sessionId.prefix(8)) [\(sessions[index].projectName)] -> \(sessions[index].state.rawValue) (\(event.name.rawValue))")
        return event.sessionId
    }

    // MARK: - State transitions used by approvals (M2) / replies (M3)

    /// Ensures a session exists (creating it in `working` state) — used when a
    /// PreToolUse approval arrives before we've seen a SessionStart.
    func ensure(id: String, cwd: String, tmuxPane: String?) {
        _ = upsert(id: id, cwd: cwd, tmuxPane: tmuxPane)
    }

    func setPendingApproval(_ approval: PendingApproval) {
        guard let index = sessions.firstIndex(where: { $0.id == approval.sessionId }) else { return }
        sessions[index].pendingApproval = approval
        setState(index, .waitingApproval)
        sessions[index].lastUpdated = Date()
    }

    func clearPendingApproval(sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].pendingApproval = nil
        // Returning to work; a subsequent Stop/Notification will move us back to waiting.
        if sessions[index].state == .waitingApproval {
            setState(index, .working)
        }
        sessions[index].lastUpdated = Date()
    }

    /// Marks a text wait as answered (M3), so its card is dismissed and we don't
    /// double-answer.
    func markAnswered(sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        setState(index, .working)
        sessions[index].lastAssistantMessage = nil
        sessions[index].lastUpdated = Date()
    }

    // MARK: - Task title

    /// Normalizes a raw user prompt into a compact one-line caption: whitespace and
    /// newlines collapsed, trimmed, and truncated. Returns nil for empty prompts.
    private static let taskTitleMaxLength = 80

    static func taskTitle(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        let collapsed = prompt
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > taskTitleMaxLength {
            return collapsed.prefix(taskTitleMaxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
        }
        return collapsed
    }

    // MARK: - Pruning

    private func schedulePrune(id: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.endedRetention ?? 30) * 1_000_000_000))
            guard let self else { return }
            if let session = self.session(id: id), session.state == .ended {
                self.sessions.removeAll { $0.id == id }
            }
        }
    }
}
