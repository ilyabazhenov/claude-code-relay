import SwiftUI

/// The content shown when the menu-bar item is opened: the usage readout, then running
/// sessions and recently-ended sessions each in their own collapsed group, plus
/// install/settings/quit controls. Relay is a monitor — it observes sessions and collects
/// usage stats; it does not surface reply/approval cards.
struct MenuContentView: View {
    @ObservedObject var daemon: Daemon
    @ObservedObject var updater: UpdateController
    @ObservedObject var sessions: SessionStore
    @ObservedObject var rateLimits: RateLimitStore
    @ObservedObject var history: UsageHistoryStore
    @ObservedObject var tokens: TokenUsageStore
    @ObservedObject private var loc = Localization.shared
    @Environment(\.openWindow) private var openWindow

    @State private var hooksInstalled = false
    @State private var hookStatusNote: String?
    @State private var showBackground = false
    @State private var showEnded = false
    /// True while a forced usage refresh is in flight — drives the spinning icon. Cleared
    /// when a fresh snapshot lands (`capturedAt` changes) or by a timeout fallback.
    @State private var refreshingUsage = false

    init(daemon: Daemon, updater: UpdateController) {
        self.daemon = daemon
        self.updater = updater
        self.sessions = daemon.sessions
        self.rateLimits = daemon.rateLimits
        self.history = daemon.rateLimits.history
        self.tokens = daemon.tokens
    }

    /// Running in the background — not finished. Waiting sessions are folded in here too:
    /// Relay only monitors them, it no longer prompts you to reply or approve.
    private var background: [Session] { sessions.ordered.filter { $0.state != .ended } }
    /// Just finished; lingers ~30s before the store prunes it. Kept separate so its count
    /// never inflates "background".
    private var ended: [Session] { sessions.ordered.filter { $0.state == .ended } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if dashboardVisible {
                UsageDashboard(rateLimits: rateLimits, history: history, tokens: tokens)
            }
            Divider()
            sessionList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { hooksInstalled = HooksInstaller.isInstalled() }
    }

    @ViewBuilder private var sessionList: some View {
        if background.isEmpty && ended.isEmpty {
            Text(loc.noActiveSessions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 6) {
                if !background.isEmpty {
                    disclosure(
                        title: loc.activeSessionsTitle(background.count),
                        rows: background,
                        expanded: $showBackground
                    )
                }
                if !ended.isEmpty {
                    disclosure(
                        title: loc.recentlyEndedTitle(ended.count),
                        rows: ended,
                        expanded: $showEnded
                    )
                }
            }
        }
    }

    /// A collapsible group of compact session rows, used for both the background (running)
    /// and recently-ended lists so each keeps its own honest count.
    private func disclosure(title: String, rows: [Session], expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(title)
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                ForEach(rows) { session in
                    CompactRow(session: session) { daemon.replies.focusSession(session.id) }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Whether to show the usage dashboard: once there's a current reading or any
    /// accumulated history. Before the first status-line update (fresh install, no session
    /// run yet) it stays hidden so the window isn't a block of empty cards.
    private var dashboardVisible: Bool {
        rateLimits.snapshot != nil || !history.windows.isEmpty
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(daemon.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text("Relay")
                .font(.headline)
            Spacer()
            if let captured = rateLimits.snapshot?.capturedAt {
                // Re-render every 30s so the "N min ago" caption stays current while the
                // window is open; falls back to an absolute clock time once it ages out.
                TimelineView(.periodic(from: captured, by: 30)) { ctx in
                    Text(loc.lastSync(syncValue(captured, now: ctx.date)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            refreshButton
        }
    }

    /// The value shown after "Updated": "just now" and "N min ago" for a recent sync,
    /// otherwise the wall-clock time it was captured.
    private func syncValue(_ captured: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(captured))
        if elapsed < 60 { return loc.syncJustNow }
        if elapsed < 3600 { return loc.minutesAgo(Int(elapsed / 60)) }
        return Self.clockFormatter.string(from: captured)
    }

    /// Wall-clock formatter for the "last sync" caption. 24-hour HH:mm, matching the
    /// dashboard's hour labels.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Forces a fresh usage reading: fires an immediate ping through the proxy (bypassing
    /// the activity gate) and spins until a new snapshot lands. Disabled when usage
    /// tracking is off, since there'd be nothing to refresh.
    @ViewBuilder private var refreshButton: some View {
        let enabled = daemon.config.effectiveUsageProxyEnabled && daemon.isRunning
        Button {
            refreshUsage()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
                .rotationEffect(.degrees(refreshingUsage ? 360 : 0))
                .animation(refreshingUsage
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default, value: refreshingUsage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled || refreshingUsage)
        .help(enabled ? loc.refreshUsageNow : loc.usageTrackingOff)
        .onChange(of: rateLimits.snapshot?.capturedAt) { _, _ in
            refreshingUsage = false
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = hookStatusNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: hooksInstalled ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                    Text(hooksInstalled ? loc.hooksInstalled : loc.hooksNotInstalled)
                        .foregroundStyle(.secondary)
                    if daemon.isRunning {
                        Text("· 127.0.0.1:\(String(daemon.boundPort))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
            }

            HStack {
                // Install is a first-run call to action; uninstall lives in Settings.
                if !hooksInstalled {
                    Button(loc.installHooks) { toggleHooks() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button(loc.settingsMenu) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(loc.checkForUpdates) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                Button(loc.quit) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
    }

    // MARK: - Actions

    /// Kick off a forced usage refresh. The spinner is cleared either when a fresh
    /// snapshot arrives (see `refreshButton`'s `onChange`) or by this timeout fallback, so
    /// it never spins forever if the ping brings back no new headers.
    private func refreshUsage() {
        guard daemon.refreshUsageNow() else { return }
        refreshingUsage = true
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s safety net
            refreshingUsage = false
        }
    }

    private func toggleHooks() {
        do {
            if hooksInstalled {
                try HooksInstaller.uninstall()
                hooksInstalled = false
                flashNote(loc.hooksRemovedNote)
            } else {
                try HooksInstaller.install(port: Int(daemon.boundPort), secret: daemon.config.secret,
                                           approvalsEnabled: daemon.config.effectiveApprovalsEnabled)
                hooksInstalled = true
                flashNote(loc.hooksInstalledNote)
            }
        } catch {
            Log.error("hook toggle failed: \(error.localizedDescription)")
            flashNote(loc.failedNote(error.localizedDescription))
        }
    }

    private func flashNote(_ text: String) {
        hookStatusNote = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            hookStatusNote = nil
        }
    }
}
