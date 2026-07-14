import Foundation
import Combine
import AppKit
import Sparkle

/// Owns Sparkle's updater and exposes just enough state for the menu and settings to
/// drive it. Configuration (feed URL, EdDSA public key, check interval) lives in
/// `Info.plist`; this type only surfaces the runtime affordances.
///
/// Behaviour is "notify, don't auto-install": Sparkle checks in the background on its
/// schedule and shows its own standard "a new version is available" alert (Install /
/// Later / Skip). `SUAutomaticallyUpdate` is `false` in Info.plist, so nothing is
/// swapped without the user clicking Install.
///
/// Relay is an agent app (`LSUIElement`), so a manual check activates the app first —
/// otherwise Sparkle's window can open behind everything with no way to reach it.
@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// True once Sparkle is ready to check (drives the enabled state of the menu item).
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks for updates automatically in the background. Backed by
    /// Sparkle's own preference (stored in the app's `UserDefaults`), so this is the one
    /// source of truth — we deliberately don't mirror it into `config.json`.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init() {
        // `startingUpdater: true` reads SUFeedURL / SUPublicEDKey from Info.plist and begins
        // the scheduled background checks. A nil delegate keeps the standard UI + behaviour.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // Mirror Sparkle's readiness into a @Published so SwiftUI can bind to it.
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// The last time Sparkle checked (scheduled or manual), or nil if it never has.
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    /// The bundle's marketing version, e.g. "0.1.0".
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// User-initiated check. Brings the agent app forward so Sparkle's alert is reachable,
    /// then asks Sparkle to check (it shows "you're up to date" or the update prompt).
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
