import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter`: requests permission, registers the action
/// categories, posts approval/reply notifications, and routes the user's button /
/// text-field responses back to the coordinators.
///
/// Requires a properly bundled, (ad-hoc) signed `.app` — see `scripts/build_app.sh`.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    weak var approvals: ApprovalCoordinator?
    weak var replies: ReplyCoordinator?

    // Category + action identifiers.
    static let approvalCategory = "RELAY_APPROVAL"
    static let approveAction = "RELAY_APPROVE"
    static let denyAction = "RELAY_DENY"

    static let replyCategory = "RELAY_REPLY"
    static let replyAction = "RELAY_REPLY_TEXT"
    static let quickReplyPrefix = "RELAY_QR_"

    private var authorized = false

    // Live preferences, pushed from config (M4).
    var quickReplies: [String] = Config.defaultQuickReplies
    var notifyApprovals = true
    var notifyReplies = true

    /// Sets up the delegate, registers categories, and asks for permission. Safe to
    /// call once at launch; call `reconfigureCategories()` after prefs change.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        reconfigureCategories()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error {
                    Log.error("notification auth error: \(error.localizedDescription)")
                } else {
                    Log.info("notification authorization granted=\(granted)")
                }
            }
        }
    }

    /// Rebuilds the notification categories, including the current quick-reply actions.
    func reconfigureCategories() {
        let loc = Localization.shared
        let approve = UNNotificationAction(
            identifier: Self.approveAction,
            title: loc.notifApprove,
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.denyAction,
            title: loc.notifDeny,
            options: [.destructive]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategory,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )

        // Quick-reply buttons (capped so the banner stays usable) + a free-text field.
        var replyActions: [UNNotificationAction] = quickReplies.prefix(3).enumerated().map { index, title in
            UNNotificationAction(identifier: "\(Self.quickReplyPrefix)\(index)", title: title, options: [])
        }
        replyActions.append(UNTextInputNotificationAction(
            identifier: Self.replyAction,
            title: loc.notifReply,
            options: [],
            textInputButtonTitle: loc.notifSend,
            textInputPlaceholder: loc.notifReplyPlaceholder
        ))
        let replyCategory = UNNotificationCategory(
            identifier: Self.replyCategory,
            actions: replyActions,
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([approvalCategory, replyCategory])
    }

    // MARK: - Posting

    func showApproval(_ approval: PendingApproval) {
        guard notifyApprovals else { return }
        let content = UNMutableNotificationContent()
        content.title = Localization.shared.notifApproveTitle
        content.subtitle = approval.sessionProject
        if let rule = approval.matchedRule {
            content.body = Localization.shared.notifMatchesRule(rule, command: approval.command)
        } else {
            content.body = approval.command
        }
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["request_id": approval.id, "kind": "approval"]
        content.sound = .default

        deliver(id: approval.id, content: content)
    }

    func showReply(_ prompt: ReplyPrompt) {
        guard notifyReplies else { return }
        let content = UNMutableNotificationContent()
        content.title = Localization.shared.notifClaudeWaiting
        content.subtitle = prompt.project
        content.body = prompt.question
        content.categoryIdentifier = Self.replyCategory
        content.userInfo = ["session_id": prompt.sessionId, "kind": "reply"]
        content.sound = .default

        deliver(id: "reply-" + prompt.sessionId, content: content)
    }

    private func deliver(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    func dismiss(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func dismissReply(sessionId: String) {
        dismiss(id: "reply-" + sessionId)
    }

    // MARK: - UNUserNotificationCenterDelegate
    //
    // The delegate methods are `nonisolated` (the framework calls them off the main
    // actor with non-Sendable arguments). We pull out only Sendable primitives, then
    // hop back to the main actor to mutate state.

    /// Show banners even though we're an agent app in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        let requestId = info["request_id"] as? String
        let sessionId = info["session_id"] as? String
        let userText = (response as? UNTextInputNotificationResponse)?.userText

        await MainActor.run {
            self.handleAction(actionId: actionId, requestId: requestId,
                              sessionId: sessionId, userText: userText)
        }
    }

    private func handleAction(actionId: String, requestId: String?,
                              sessionId: String?, userText: String?) {
        switch actionId {
        case Self.approveAction:
            if let requestId { approvals?.resolve(id: requestId, decision: .allow) }
        case Self.denyAction:
            if let requestId { approvals?.resolve(id: requestId, decision: .deny) }
        case Self.replyAction:
            if let sessionId, let userText { replies?.submit(sessionId: sessionId, text: userText) }
        case let action where action.hasPrefix(Self.quickReplyPrefix):
            if let sessionId,
               let index = Int(action.dropFirst(Self.quickReplyPrefix.count)),
               index < quickReplies.count {
                replies?.submit(sessionId: sessionId, text: quickReplies[index])
            }
        default:
            // Tapping the banner body: focus the session's terminal.
            if let sessionId { replies?.focusSession(sessionId) }
        }
    }
}
