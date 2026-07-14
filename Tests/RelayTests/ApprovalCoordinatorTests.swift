import XCTest
@testable import Relay

@MainActor
final class ApprovalCoordinatorTests: XCTestCase {
    private func makeCoordinator() -> ApprovalCoordinator {
        let coordinator = ApprovalCoordinator(sessions: SessionStore())
        coordinator.dangerRules = Config.defaultDangerRules
        return coordinator
    }

    private func request(_ command: String) -> ApprovalRequest {
        ApprovalRequest(json: [
            "session_id": "s1",
            "cwd": "/tmp",
            "tool_name": "Bash",
            "command": command
        ])!
    }

    /// Approvals are opt-in: a fresh config leaves the master switch off.
    func testApprovalsDisabledByDefault() {
        let config = Config(port: 0, secret: "x", dangerRules: [])
        XCTAssertFalse(config.effectiveApprovalsEnabled)
    }

    /// The master switch off means: never intercept — even a command that matches a
    /// danger rule passes straight through, without parking or prompting.
    func testDisabledPassesThroughDangerousCommand() async {
        let coordinator = makeCoordinator()
        coordinator.approvalsEnabled = false

        let outcome = await coordinator.evaluate(request("rm -rf /"))

        XCTAssertEqual(outcome.decision, .passthrough)
        XCTAssertTrue(coordinator.pending.isEmpty, "disabled approvals must not park anything")
    }

    /// With approvals on, a safe command is auto-allowed when auto-allow is enabled.
    func testEnabledAutoAllowsSafeCommand() async {
        let coordinator = makeCoordinator()
        coordinator.approvalsEnabled = true
        coordinator.autoAllowSafe = true

        let outcome = await coordinator.evaluate(request("ls -la"))

        XCTAssertEqual(outcome.decision, .allow)
    }

    /// With approvals on but auto-allow off, a safe command passes through to Claude's
    /// own permission flow rather than being auto-approved.
    func testEnabledPassthroughWhenAutoAllowOff() async {
        let coordinator = makeCoordinator()
        coordinator.approvalsEnabled = true
        coordinator.autoAllowSafe = false

        let outcome = await coordinator.evaluate(request("ls -la"))

        XCTAssertEqual(outcome.decision, .passthrough)
    }
}
