import Foundation
import SwiftUI

/// The lifecycle state of a Claude Code session, as tracked by Relay.
///
/// Transitions (driven by hooks):
///   working ──Stop──────────▶ waitingText
///   working ──PreToolUse────▶ waitingApproval   (M2)
///   waiting* ──answer given─▶ working
///   any ──SessionEnd────────▶ ended
enum SessionState: String, Codable {
    case working
    case waitingText
    case waitingApproval
    case ended

    /// True while Relay is allowed to inject text into the tmux pane (M3). Injecting
    /// while `working` would corrupt the running session.
    var isWaiting: Bool {
        self == .waitingText || self == .waitingApproval
    }

    var sortRank: Int {
        switch self {
        case .waitingApproval: return 0   // most urgent, at the top
        case .waitingText:     return 1
        case .working:         return 2
        case .ended:           return 3
        }
    }

    var dotColor: Color {
        switch self {
        case .working:         return .blue
        case .waitingText:     return .orange
        case .waitingApproval: return .red
        case .ended:           return .gray
        }
    }

    @MainActor
    func label(_ loc: Localization) -> String {
        switch self {
        case .working:         return loc.stateWorking
        case .waitingText:     return loc.stateWaitingText
        case .waitingApproval: return loc.stateWaitingApproval
        case .ended:           return loc.stateEnded
        }
    }
}

/// One tracked Claude Code session.
struct Session: Identifiable {
    let id: String                 // session_id from the hook payload
    var cwd: String
    var tmuxPane: String?          // TMUX_PANE, e.g. "%3" — needed for injection (M3)
    var state: SessionState
    var transcriptPath: String?
    var lastAssistantMessage: String?   // populated on Stop (M3)
    var notificationMessage: String?    // populated on Notification
    var lastUpdated: Date

    /// When the session entered its current waiting state (for "waiting 3m" display).
    var waitingSince: Date?
    /// Current git branch of `cwd`, if any — shown alongside the project name.
    var gitBranch: String?

    /// Pending approval request, if the session is waiting on one (M2).
    var pendingApproval: PendingApproval?

    /// A short caption of what this session is doing, derived from the first user
    /// prompt. Set once (kept stable for the life of the session) so background
    /// sessions in the same folder are still distinguishable.
    var taskTitle: String?

    /// `basename(cwd)` — the project name shown in the menu.
    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Whether Relay can drive this session through tmux (i.e. it was started via the
    /// `cc` wrapper). When false — a desktop-app session, or a terminal not wrapped in
    /// tmux — Relay can't inject replies with `tmux send-keys`; focusing instead opens
    /// (resumes) the conversation in the Claude desktop app via a `claude://` deep link.
    var hasTmux: Bool {
        !(tmuxPane ?? "").isEmpty
    }
}
