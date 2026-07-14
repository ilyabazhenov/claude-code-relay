import Foundation

/// A tool call awaiting the user's approve/deny decision (M2). The daemon parks the
/// hook's HTTP request until `decision` is set, then wakes it.
struct PendingApproval: Identifiable {
    let id: String            // unique request id
    let sessionId: String
    let toolName: String
    let command: String       // human-readable summary of what will run
    let matchedRule: String?  // which danger rule triggered the prompt (nil = generic)
    let createdAt: Date
    var cwd: String = ""

    /// `basename(cwd)` for display.
    var sessionProject: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? (cwd.isEmpty ? "session" : cwd) : name
    }
}
