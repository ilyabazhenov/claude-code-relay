import AppKit

/// Toggles the app's Dock icon on demand.
///
/// Relay is an agent app (`LSUIElement` → `.accessory` activation policy), so it has no
/// Dock icon by default. While a real window is on screen (Settings, Usage History) we
/// flip to `.regular` so the app shows in the Dock and Cmd-Tab and its window can take
/// focus normally. A reference count keeps the icon up as long as *any* such window is
/// open, and drops it back to accessory once the last one closes.
@MainActor
enum DockPresence {
    private static var count = 0

    /// A window that wants a Dock presence has appeared.
    static func acquire() {
        count += 1
        if count == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A window that wanted a Dock presence has closed.
    static func release() {
        count = max(0, count - 1)
        if count == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
