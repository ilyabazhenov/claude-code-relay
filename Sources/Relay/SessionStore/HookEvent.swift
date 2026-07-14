import Foundation

/// The subset of Claude Code hook events Relay tracks as lifecycle transitions.
/// (Approvals arrive via a separate blocking endpoint — see Approvals, M2.)
enum HookEventName: String, Codable {
    case sessionStart     = "SessionStart"
    case sessionEnd       = "SessionEnd"
    case stop             = "Stop"
    case notification     = "Notification"
    /// The user submitted a prompt (answered directly in the terminal, or Relay
    /// injected a reply). Either way the session is no longer waiting on us.
    case userPromptSubmit = "UserPromptSubmit"
}

/// A normalized lifecycle event as posted by a hook script to `POST /event`.
///
/// The hook script flattens Claude Code's stdin JSON (plus the `TMUX_PANE`
/// environment variable) into this shape.
struct HookEvent {
    let name: HookEventName
    let sessionId: String
    let cwd: String
    let tmuxPane: String?
    let transcriptPath: String?
    let lastAssistantMessage: String?   // Stop
    let message: String?                // Notification
    let source: String?                 // SessionStart
    let reason: String?                 // SessionEnd
    let prompt: String?                 // UserPromptSubmit

    /// Builds a `HookEvent` from a decoded JSON object, or nil if it's not a
    /// recognized lifecycle event / is missing required fields.
    init?(json: [String: Any]) {
        guard
            let rawEvent = (json["event"] as? String) ?? (json["hook_event_name"] as? String),
            let name = HookEventName(rawValue: rawEvent)
        else { return nil }

        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else { return nil }

        self.name = name
        self.sessionId = sessionId
        self.cwd = (json["cwd"] as? String) ?? ""
        self.tmuxPane = (json["tmux_pane"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.transcriptPath = json["transcript_path"] as? String
        self.lastAssistantMessage = json["last_assistant_message"] as? String
        self.message = json["message"] as? String
        self.source = json["source"] as? String
        self.reason = json["reason"] as? String
        self.prompt = json["prompt"] as? String
    }
}
