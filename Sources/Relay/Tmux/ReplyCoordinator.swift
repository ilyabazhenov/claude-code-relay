import Foundation
import Combine

/// A pending text question from Claude that the user can answer (M3).
struct ReplyPrompt {
    let sessionId: String
    let project: String
    let question: String
}

/// The result of attempting to submit a reply.
enum ReplyResult: Equatable {
    case injected
    case notWaiting     // session isn't in a waiting state (already answered / working)
    case alreadyAnswering
    case failed(String)
}

/// Handles submitting a user's text reply back into a waiting session by injecting it
/// into the session's tmux pane.
///
/// Guards:
///  - Only injects while the session is in a `waiting_*` state (never into a working
///    session — that would corrupt it).
///  - A per-session in-flight lock plus the state flip to `working` prevents
///    double-answering from banner + menu (+ terminal).
@MainActor
final class ReplyCoordinator: ObservableObject {
    private let sessions: SessionStore
    private let injector = TmuxInjector()
    weak var notifier: NotificationManager?

    /// Sessions currently being answered, to reject a concurrent second submit.
    private var inFlight: Set<String> = []

    init(sessions: SessionStore) {
        self.sessions = sessions
    }

    /// Bring the session to the front (M4): its terminal/tmux pane, or — for a
    /// desktop-app session — the conversation in the Claude desktop app.
    func focusSession(_ sessionId: String) {
        guard let session = sessions.session(id: sessionId) else { return }
        TerminalFocuser.focus(session: session)
    }

    @discardableResult
    func submit(sessionId: String, text: String) -> ReplyResult {
        guard let session = sessions.session(id: sessionId) else {
            return .notWaiting
        }
        // Only inject while waiting; this is also the double-answer lock (the first
        // successful reply flips state to `working`, so a later one is rejected here).
        guard session.state.isWaiting else {
            Log.info("reply ignored for \(sessionId.prefix(8)): state=\(session.state.rawValue)")
            return .notWaiting
        }
        guard !inFlight.contains(sessionId) else {
            return .alreadyAnswering
        }
        guard let pane = session.tmuxPane, !pane.isEmpty else {
            Log.error("reply for \(sessionId.prefix(8)): no tmux pane (was Claude started via `cc`?)")
            return .failed("no tmux pane")
        }

        inFlight.insert(sessionId)
        defer { inFlight.remove(sessionId) }

        do {
            try injector.send(text: text, toPane: pane)
            sessions.markAnswered(sessionId: sessionId)
            notifier?.dismissReply(sessionId: sessionId)
            Log.info("reply injected into \(sessionId.prefix(8)) pane \(pane)")
            return .injected
        } catch {
            Log.error("reply injection failed for \(sessionId.prefix(8)): \(error)")
            return .failed("\(error)")
        }
    }
}
