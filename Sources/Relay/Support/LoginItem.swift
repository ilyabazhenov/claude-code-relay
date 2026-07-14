import Foundation
import ServiceManagement

/// Launch-at-login control, backed by `SMAppService.mainApp` (macOS 13+).
///
/// The *system* is the source of truth here — `SMAppService` records the login-item
/// state in the user's login-item database, not in Relay's own config. We still mirror
/// the user's intent into `Config.launchAtLogin` so the settings screen can render a
/// sensible value even before the first status query, but `currentlyEnabled` always
/// reflects what the OS will actually do at the next login.
///
/// Registration only works for a real `.app` bundle (see `scripts/build_app.sh`); a
/// bare `swift run` executable reports `.notFound`.
enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var currentlyEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The raw system status, useful for surfacing the "needs approval in System
    /// Settings" case to the user.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// True when macOS has the login item on file but the user disabled it in
    /// System Settings ▸ General ▸ Login Items. In that state `register()` won't
    /// re-enable it — only the user can, from that pane.
    static var requiresUserApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the main app as a login item. No-op if the current
    /// system state already matches `enabled`, so repeated Saves are cheap and quiet.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            // `.notRegistered`/`.notFound` mean there's nothing to remove.
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
