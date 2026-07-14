import Foundation
import AppKit

/// Best-effort "bring me to the session" (M4).
///
/// Two paths depending on where the session lives:
///   • tmux/terminal session (started via `cc`) — tmux sessions live inside whatever
///     terminal emulator the user launched them in, and macOS gives us no reliable
///     pane→window mapping across every terminal app, so we (1) ask tmux to select the
///     target pane/window and (2) activate a running terminal app to the front.
///   • desktop-app session (no tmux pane) — open the conversation directly in the
///     Claude desktop app via its `claude://resume?session=<id>` deep link (the same
///     mechanism Claude Code's own `/desktop` handoff uses).
enum TerminalFocuser {
    /// Terminal apps we try to bring forward, in priority order.
    private static let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm"
    ]

    static func focus(session: Session) {
        if session.hasTmux {
            focusTerminal(pane: session.tmuxPane)
        } else {
            openInDesktop(sessionId: session.id)
        }
    }

    private static func focusTerminal(pane: String?) {
        if let pane, !pane.isEmpty, let tmux = TmuxInjector.tmuxPath() {
            selectPane(tmux: tmux, pane: pane)
        }
        activateTerminalApp()
    }

    /// Bundle path of the Claude desktop app.
    private static let claudeDesktopPath = "/Applications/Claude.app"

    /// Bring the Claude desktop app to the front for a desktop session. We deliberately
    /// do *not* deep-link to the specific conversation: the desktop app (v1.20186) has
    /// no working external route to focus an existing Code session by its hook id —
    ///   • `claude://resume?session=<uuid>` imports the CLI session as a NEW one (dup);
    ///   • `claude://code/<uuid>` is rejected ("unrecognized code path");
    ///   • `claude://code/cse_<id>` is the real route but sits behind a feature gate
    ///     (`2143883161`) that is currently off, and needs the app's internal `cse_`
    ///     id, which the hook payload (a plain UUID) doesn't carry.
    /// So we just activate the app; the user picks the session from the sidebar. When
    /// that gate ships, this can become a `claude://code/<cse_id>` navigation.
    ///
    /// Focus-only regardless: Relay can't inject a reply into a desktop session, so its
    /// approvals and text replies still happen from the menu card, not the app window.
    private static func openInDesktop(sessionId: String) {
        let url = URL(fileURLWithPath: claudeDesktopPath)
        Log.info("focus: activating Claude desktop app for \(sessionId.prefix(8))")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func selectPane(tmux: String, pane: String) {
        // Select the window that owns the pane, then the pane itself. Errors are fine.
        run(tmux, ["select-window", "-t", pane])
        run(tmux, ["select-pane", "-t", pane])
    }

    private static func activateTerminalApp() {
        let running = NSWorkspace.shared.runningApplications
        for bundleID in terminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
