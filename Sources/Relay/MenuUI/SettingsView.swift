import SwiftUI
import AppKit

/// The settings window (M4): port, danger rules, quick replies, approval behavior,
/// and notification toggles. Edits are staged locally and applied on Save.
struct SettingsView: View {
    @ObservedObject var daemon: Daemon
    @ObservedObject private var loc = Localization.shared

    @State private var launchAtLogin = false
    @State private var approvalsEnabled = false
    @State private var autoAllowSafe = true
    @State private var notifyApprovals = true
    @State private var notifyReplies = true
    @State private var portText = ""
    @State private var dangerRulesText = ""
    @State private var quickRepliesText = ""
    @State private var language: AppLanguage = .system
    @State private var menuBarDisplay: MenuBarUsageDisplay = .both
    @State private var menuBarShowPercent = true
    @State private var savedNote = false
    @State private var hooksInstalled = false
    @State private var hookNote: String?
    @State private var launchNote: String?
    /// Guards against a double `DockPresence.acquire()` if `onAppear` re-fires (e.g. when
    /// the activation-policy switch re-hosts the window) without a matching `onDisappear`.
    @State private var dockHeld = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(loc.launchAtLogin, isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            applyLaunchAtLogin(newValue)
                        }
                } header: {
                    Text(loc.sectionGeneral)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.launchAtLoginHint)
                        if let launchNote { Text(launchNote) }
                    }
                }

                Section {
                    Picker(loc.sectionLanguage, selection: $language) {
                        Text(loc.languageSystem).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.en)
                        Text("Русский").tag(AppLanguage.ru)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: language) { _, newValue in
                        Localization.shared.apply(newValue)
                    }
                } header: {
                    Text(loc.sectionLanguage)
                } footer: {
                    Text(loc.languageChangeHint)
                }

                Section {
                    LabeledContent(loc.boundPort) {
                        Text(daemon.isRunning ? "127.0.0.1:\(String(daemon.boundPort))" : loc.notRunning)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                    LabeledContent(loc.preferredPort) {
                        TextField(loc.preferredPort, text: $portText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 72)
                            .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    Text(loc.sectionDaemon)
                } footer: {
                    Text(loc.portChangeHint)
                }

                Section {
                    Toggle(loc.approvalsEnabled, isOn: $approvalsEnabled)
                    hint(loc.approvalsEnabledHint)
                    Divider()
                    Toggle(loc.autoApproveSafe, isOn: $autoAllowSafe)
                        .disabled(!approvalsEnabled)
                    hint(loc.autoApproveSafeHint)
                        .opacity(approvalsEnabled ? 1 : 0.5)
                } header: {
                    Text(loc.sectionApprovals)
                }

                Section {
                    editorField(text: $dangerRulesText, height: 120, enabled: approvalsEnabled)
                } header: {
                    Text(loc.sectionDangerRules)
                }

                Section {
                    editorField(text: $quickRepliesText, height: 80, enabled: true)
                } header: {
                    Text(loc.sectionQuickReplies)
                }

                Section {
                    Toggle(loc.approvalNotifications, isOn: $notifyApprovals)
                    Toggle(loc.replyNotifications, isOn: $notifyReplies)
                } header: {
                    Text(loc.sectionNotifications)
                }

                Section {
                    Picker(loc.menuBarShows, selection: $menuBarDisplay) {
                        Text(loc.usageShowBoth).tag(MenuBarUsageDisplay.both)
                        Text(loc.usageShowFiveHour).tag(MenuBarUsageDisplay.fiveHour)
                        Text(loc.usageShowWeekly).tag(MenuBarUsageDisplay.weekly)
                    }
                    Toggle(loc.showPercentSign, isOn: $menuBarShowPercent)
                } header: {
                    Text(loc.sectionUsageLimits)
                } footer: {
                    Text(loc.usageLimitsHint)
                }

                Section {
                    LabeledContent(loc.status) {
                        Label(hooksInstalled ? loc.installed : loc.notInstalled,
                              systemImage: hooksInstalled ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(hooksInstalled ? .green : .secondary)
                    }
                    HStack {
                        Button(hooksInstalled ? loc.uninstallHooks : loc.installHooks) { toggleHooks() }
                            .tint(hooksInstalled ? .red : nil)
                        if let hookNote {
                            Text(hookNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(loc.sectionHooks)
                } footer: {
                    Text(loc.hooksHint)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if savedNote {
                    Label(loc.saved, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .transition(.opacity)
                }
                Spacer()
                Button(loc.revert) { load() }
                Button(loc.save) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, idealWidth: 480, maxWidth: .infinity,
               minHeight: 500, idealHeight: 660, maxHeight: .infinity)
        .onAppear {
            load()
            if !dockHeld { dockHeld = true; DockPresence.acquire() }
        }
        .onDisappear {
            if dockHeld { dockHeld = false; DockPresence.release() }
        }
    }

    /// A secondary caption used for inline hints inside multi-control sections (where a
    /// single section footer can't sit next to the right control).
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A monospaced multi-line editor styled to read as a proper input field, with a
    /// rounded border and dimming when disabled.
    private func editorField(text: Binding<String>, height: CGFloat, enabled: Bool) -> some View {
        TextEditor(text: text)
            .font(.system(.caption, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
    }

    private func load() {
        let c = daemon.config
        approvalsEnabled = c.effectiveApprovalsEnabled
        autoAllowSafe = c.effectiveAutoAllowSafe
        notifyApprovals = c.effectiveNotifyApprovals
        notifyReplies = c.effectiveNotifyReplies
        portText = String(c.port)
        dangerRulesText = c.dangerRules.joined(separator: "\n")
        quickRepliesText = c.effectiveQuickReplies.joined(separator: "\n")
        language = c.effectiveLanguage
        menuBarDisplay = c.effectiveMenuBarUsageDisplay
        menuBarShowPercent = c.effectiveMenuBarShowPercent
        Localization.shared.apply(language)
        savedNote = false
        hooksInstalled = HooksInstaller.isInstalled()
        // The system login-item database is the source of truth — read from it rather
        // than from config so the toggle always reflects reality.
        launchAtLogin = LoginItem.currentlyEnabled
        launchNote = LoginItem.requiresUserApproval ? loc.launchAtLoginNeedsApproval : nil
    }

    /// Register/unregister the login item immediately when the user flips the toggle,
    /// and mirror the intent into config so it survives relaunches. Any failure is
    /// surfaced inline and the toggle is snapped back to the real system state.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            daemon.updateConfig { $0.launchAtLogin = enabled }
            launchNote = LoginItem.requiresUserApproval ? loc.launchAtLoginNeedsApproval : nil
        } catch {
            Log.error("launch-at-login toggle failed: \(error.localizedDescription)")
            // Snap the toggle back to what the system actually reports.
            launchAtLogin = LoginItem.currentlyEnabled
            flashLaunch(loc.launchAtLoginUnavailable)
        }
    }

    private func flashLaunch(_ text: String) {
        launchNote = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            launchNote = LoginItem.requiresUserApproval ? loc.launchAtLoginNeedsApproval : nil
        }
    }

    private func toggleHooks() {
        do {
            if hooksInstalled {
                try HooksInstaller.uninstall()
                hooksInstalled = false
                flashHook(loc.hooksRemovedNote)
            } else {
                try HooksInstaller.install(port: Int(daemon.boundPort), secret: daemon.config.secret,
                                           approvalsEnabled: daemon.config.effectiveApprovalsEnabled)
                hooksInstalled = true
                flashHook(loc.hooksInstalledNote)
            }
        } catch {
            Log.error("hook toggle failed: \(error.localizedDescription)")
            flashHook(loc.failedNote(error.localizedDescription))
        }
    }

    private func flashHook(_ text: String) {
        hookNote = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            hookNote = nil
        }
    }

    private func save() {
        let rules = linesFrom(dangerRulesText)
        let quicks = linesFrom(quickRepliesText)
        let port = Int(portText.trimmingCharacters(in: .whitespaces))

        daemon.updateConfig { c in
            c.launchAtLogin = launchAtLogin
            c.approvalsEnabled = approvalsEnabled
            c.autoAllowSafe = autoAllowSafe
            c.notifyApprovals = notifyApprovals
            c.notifyReplies = notifyReplies
            c.dangerRules = rules.isEmpty ? c.dangerRules : rules
            c.quickReplies = quicks
            c.language = language.rawValue
            c.menuBarUsageDisplay = menuBarDisplay.rawValue
            c.menuBarShowPercent = menuBarShowPercent
            if let port { c.port = port }
        }
        savedNote = true
    }

    private func linesFrom(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
