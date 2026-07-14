import SwiftUI

/// Relay — a dispatcher for Claude Code sessions, living in the menu bar.
///
/// Runs as an agent app (`LSUIElement`), so there is no Dock icon and no main
/// window; the only UI surface is the `MenuBarExtra`.
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(daemon: appDelegate.daemon, updater: appDelegate.updater)
        } label: {
            // Usage readout (or chevron glyph when there's no data yet).
            MenuBarLabel(daemon: appDelegate.daemon, rateLimits: appDelegate.daemon.rateLimits)
        }
        .menuBarExtraStyle(.window)

        Window(Localization.shared.settingsWindowTitle, id: "settings") {
            SettingsView(daemon: appDelegate.daemon, updater: appDelegate.updater)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Owns app-lifetime objects (the daemon) and starts them once the app finishes
/// launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemon = Daemon()
    let updater = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        daemon.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon.stop()
    }
}
