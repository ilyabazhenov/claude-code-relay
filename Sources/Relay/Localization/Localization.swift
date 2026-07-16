import Foundation
import Combine

/// The language the user picked in Settings. `.system` means "follow the OS", which
/// resolves to a concrete `Lang` via `Localization.detectSystem()`.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case en
    case ru

    var id: String { rawValue }
}

/// A concrete, resolved UI language. Every string accessor branches on this.
enum Lang: String {
    case en
    case ru
}

/// The single source of truth for UI language.
///
/// Views observe `Localization.shared` (via `@ObservedObject`) so that changing the
/// language in Settings redraws the whole UI live. String accessors are plain methods
/// on this object — no `.strings`/`.lproj` bundles, which keeps the hand-assembled
/// `.app` (see `scripts/build_app.sh`) free of extra resource plumbing.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    /// The user's stored preference (system / en / ru).
    @Published private(set) var preference: AppLanguage = .system

    /// The resolved language actually used for rendering.
    @Published private(set) var lang: Lang = Localization.detectSystem()

    private init() {}

    /// Apply a preference, resolving `.system` against the OS languages. No-op if the
    /// effective language doesn't actually change, to avoid needless redraws.
    func apply(_ preference: AppLanguage) {
        self.preference = preference
        let resolved: Lang
        switch preference {
        case .system: resolved = Localization.detectSystem()
        case .en:     resolved = .en
        case .ru:     resolved = .ru
        }
        if resolved != lang { lang = resolved }
    }

    /// Pick a language from the user's ordered OS preferences: the first that is Russian
    /// or English wins; anything else falls back to English.
    static func detectSystem() -> Lang {
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
                ?? String(identifier.prefix(2)).lowercased()
            if code == "ru" { return .ru }
            if code == "en" { return .en }
        }
        return .en
    }

    // MARK: - String selection helpers

    /// Pick the string for the current language.
    private func s(_ en: String, _ ru: String) -> String { lang == .ru ? ru : en }

    /// Russian plural picker: `one` (1, 21…), `few` (2–4, 22–24…), `many` (0, 5–20…).
    private func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = abs(n) % 100
        let mod10 = abs(n) % 10
        if mod100 >= 11 && mod100 <= 14 { return many }
        if mod10 == 1 { return one }
        if mod10 >= 2 && mod10 <= 4 { return few }
        return many
    }

    // MARK: - Session state labels

    var stateWorking: String { s("working", "работает") }
    var stateWaitingText: String { s("waiting for reply", "ждёт ответа") }
    var stateWaitingApproval: String { s("waiting for approval", "ждёт подтверждения") }
    var stateEnded: String { s("ended", "завершено") }

    // MARK: - Menu content

    var noActiveSessions: String { s("No active sessions", "Нет активных сессий") }

    func activeSessionsTitle(_ n: Int) -> String {
        switch lang {
        case .en: return "\(n) active \(n == 1 ? "session" : "sessions")"
        case .ru: return "\(n) \(pluralRu(n, "активная сессия", "активные сессии", "активных сессий"))"
        }
    }

    func recentlyEndedTitle(_ n: Int) -> String {
        switch lang {
        case .en: return "\(n) recently ended"
        case .ru: return "\(n) \(pluralRu(n, "недавно завершена", "недавно завершены", "недавно завершено"))"
        }
    }

    var refreshUsageNow: String { s("Refresh usage limits now", "Обновить лимиты сейчас") }
    func lastSync(_ value: String) -> String { s("Updated \(value)", "Обновлено \(value)") }
    var syncJustNow: String { s("just now", "только что") }
    func minutesAgo(_ n: Int) -> String { s("\(n)m ago", "\(n) мин назад") }
    var usageTrackingOff: String { s("Usage tracking is off (enable it in Settings)",
                                      "Отслеживание выключено (включите в Настройках)") }
    var hooksInstalled: String { s("Hooks installed", "Хуки установлены") }
    var hooksNotInstalled: String { s("Hooks not installed", "Хуки не установлены") }
    var installHooks: String { s("Install hooks", "Установить хуки") }
    var settingsMenu: String { s("Settings…", "Настройки…") }
    var checkForUpdates: String { s("Check for Updates…", "Проверить обновления…") }
    var quit: String { s("Quit", "Выйти") }

    var hooksRemovedNote: String { s("Hooks removed from settings.json",
                                     "Хуки удалены из settings.json") }
    var hooksInstalledNote: String { s("Hooks installed — run Claude via ./cc",
                                       "Хуки установлены — запускайте Claude через ./cc") }
    func failedNote(_ error: String) -> String { s("Failed: \(error)", "Ошибка: \(error)") }

    // MARK: - Compact row

    var focusTerminal: String { s("Focus this session's terminal",
                                  "Показать терминал этой сессии") }
    var openInDesktopApp: String { s("Open this conversation in the Claude desktop app",
                                     "Открыть этот диалог в приложении Claude") }

    // MARK: - Window titles

    var settingsWindowTitle: String { s("Relay Settings", "Настройки Relay") }

    // MARK: - Settings

    var sectionDaemon: String { s("Daemon", "Демон") }
    var boundPort: String { s("Bound address", "Адрес") }
    var notRunning: String { s("not running", "не запущен") }
    var preferredPort: String { s("Preferred port", "Предпочтительный порт") }
    var portChangeHint: String { s("0 = pick a free port automatically. A change applies the next time Relay launches.",
                                   "0 = выбрать свободный порт автоматически. Изменение применится при следующем запуске Relay.") }

    var sectionLanguage: String { s("Language", "Язык") }
    var languageSystem: String { s("System", "Системный") }
    var languageChangeHint: String { s("Applies immediately across the app.",
                                       "Применяется сразу во всём приложении.") }

    var sectionGeneral: String { s("General", "Общие") }
    var launchAtLogin: String { s("Launch Relay at login", "Запускать Relay при входе") }
    var launchAtLoginHint: String { s("Starts Relay automatically when you log in to your Mac.",
                                      "Relay будет автоматически запускаться при входе в систему.") }
    var launchAtLoginNeedsApproval: String {
        s("Enable Relay in System Settings ▸ General ▸ Login Items to finish.",
          "Включите Relay в Системных настройках ▸ Основные ▸ Объекты входа, чтобы завершить.")
    }
    var launchAtLoginUnavailable: String {
        s("Available only for the installed Relay.app (not when run from Xcode/CLI).",
          "Доступно только для установленного Relay.app (не при запуске из Xcode/CLI).")
    }

    var sectionApprovals: String { s("Approvals", "Подтверждения") }
    var approvalsEnabled: String { s("Intercept commands for approval",
                                     "Перехватывать команды для подтверждения") }
    var approvalsEnabledHint: String { s("When off, Relay never intercepts commands — every call goes straight to Claude Code's own permission flow, and the approval hook is removed (no per-command overhead). Takes effect immediately for running sessions.",
                                         "Когда выключено, Relay не перехватывает команды — все вызовы идут напрямую через обычный запрос разрешения Claude Code, а хук подтверждения удаляется (без накладных расходов). Для активных сессий применяется сразу.") }
    var autoApproveSafe: String { s("Auto-approve safe commands",
                                    "Автоматически одобрять безопасные команды") }
    var autoApproveSafeHint: String { s("When off, non-dangerous commands use Claude Code's normal permission prompt.",
                                        "Когда выключено, безопасные команды используют обычный запрос разрешения Claude Code.") }

    var sectionDangerRules: String { s("Dangerous command rules (one per line)",
                                       "Правила опасных команд (по одному на строку)") }
    var dangerRulesHint: String { s("Clearing this field keeps your current rules — turn off approvals above to disable the gate.",
                                    "Очистка поля сохраняет текущие правила — чтобы отключить перехват, выключите подтверждения выше.") }
    var sectionQuickReplies: String { s("Quick replies (one per line)",
                                        "Быстрые ответы (по одному на строку)") }

    var sectionNotifications: String { s("Notifications", "Уведомления") }
    var approvalNotifications: String { s("Approval notifications", "Уведомления о подтверждениях") }
    var replyNotifications: String { s("Reply notifications", "Уведомления об ответах") }

    var sectionUsageLimits: String { s("Usage limits", "Лимиты использования") }
    var usageTracking: String { s("Track usage limits", "Отслеживать лимиты") }
    var usageTrackingHint: String { s("Relay fires a tiny throwaway ping through a loopback proxy to read your rate-limit windows. Off means no pings and no usage figures.",
                                      "Relay отправляет крошечный служебный пинг через локальный прокси, чтобы читать окна лимитов. Выключено — пингов и данных об использовании не будет.") }
    var usageLimitsHint: String { s("Relay reads your 5-hour and weekly usage from Claude Code's status line — installed together with the hooks. Figures appear for Claude.ai Pro/Max after the first response in a session (run Claude via ./cc).",
                                    "Relay читает 5-часовое и недельное использование из статус-строки Claude Code — устанавливается вместе с хуками. Данные появляются для Claude.ai Pro/Max после первого ответа в сессии (запускайте Claude через ./cc).") }
    var menuBarShows: String { s("Menu bar shows", "В строке меню") }
    var usageShowBoth: String { s("5-hour and weekly", "5 часов и неделя") }
    var usageShowFiveHour: String { s("5-hour only", "Только 5 часов") }
    var usageShowWeekly: String { s("Weekly only", "Только неделя") }
    var showPercentSign: String { s("Show percent sign", "Показывать знак процента") }

    var sectionHooks: String { s("Hooks", "Хуки") }
    var status: String { s("Status", "Статус") }
    var installed: String { s("Installed", "Установлены") }
    var notInstalled: String { s("Not installed", "Не установлены") }
    var uninstallHooks: String { s("Uninstall hooks", "Удалить хуки") }
    var hooksHint: String { s("Hooks let Claude Code report sessions and usage to Relay. Written to ~/.claude/settings.json; the daemon must be running to install.",
                              "Хуки позволяют Claude Code сообщать Relay о сессиях и использовании. Записываются в ~/.claude/settings.json; для установки демон должен быть запущен.") }

    var saved: String { s("Saved", "Сохранено") }
    var revert: String { s("Revert", "Отменить") }
    var save: String { s("Save", "Сохранить") }

    // MARK: - Updates

    var sectionUpdates: String { s("Updates", "Обновления") }
    var autoCheckUpdates: String { s("Check for updates automatically",
                                     "Проверять обновления автоматически") }
    var autoCheckUpdatesHint: String { s("Relay checks daily in the background and notifies you when a new version is available; nothing installs without your click.",
                                         "Relay ежедневно проверяет обновления в фоне и уведомляет о новой версии; ничего не устанавливается без вашего подтверждения.") }
    var currentVersionLabel: String { s("Current version", "Текущая версия") }
    var lastCheckedLabel: String { s("Last checked", "Последняя проверка") }
    var neverChecked: String { s("never", "никогда") }
    var checkNow: String { s("Check now", "Проверить сейчас") }

    // MARK: - Usage dashboard

    var cardFiveHour: String { s("5-hour", "5 часов") }
    var cardWeekly: String { s("Weekly", "Неделя") }
    var cardPeak7d: String { s("Peak · 7d", "Пик · 7д") }
    var noData: String { s("no data", "нет данных") }
    var collecting: String { s("collecting…", "сбор данных…") }
    func resetsCaption(_ relative: String) -> String { s("resets \(relative)", "сброс \(relative)") }

    var peaks: String { s("Peaks", "Пики") }
    var segFiveHourShort: String { s("5h", "5ч") }
    var segWeekShort: String { s("Week", "Нед") }
    var waitingFirstReading: String { s("Waiting for the first usage reading…",
                                        "Ожидание первых данных…") }

    func peaksCaption(windows n: Int, avgPercent: Int) -> String {
        switch lang {
        case .en: return "\(n) window\(n == 1 ? "" : "s") · avg \(avgPercent)%"
        case .ru: return "\(n) \(pluralRu(n, "окно", "окна", "окон")) · сред. \(avgPercent)%"
        }
    }

    var now: String { s("now", "сейчас") }
    var today: String { s("today", "сегодня") }
    var yesterdayShort: String { s("yest", "вчера") }
    var todayShort: String { s("today", "сегодня") }
    var hitLimitShort: String { s("hit limit", "лимит") }
    func avgReferenceLabel(_ percent: Int) -> String { s("avg \(percent)%", "сред. \(percent)%") }

    // MARK: - Usage projection & tokens

    var projected100: String { s("projected 100%", "прогноз 100%") }
    var thisFiveHourWindow: String { s("this 5h window", "это 5-часовое окно") }
    var tokenUsage: String { s("Token usage", "Токены") }
    var groupByModel: String { s("By model", "По моделям") }
    var groupByProject: String { s("By project", "По проектам") }
    var periodFiveHour: String { s("5h", "5ч") }
    var periodSevenDay: String { s("7d", "7д") }
    var unknownProject: String { s("—", "—") }
    var noTokenActivity: String { s("No activity in this window yet",
                                    "Пока нет активности в этом окне") }

    // MARK: - Resetting the token breakdown

    var resetTokensHint: String {
        s("Reset the token breakdown — clears every model and project figure so tracking starts fresh from the next response.",
          "Сбросить статистику токенов — очищает данные по всем моделям и проектам, отсчёт начнётся заново со следующего ответа.")
    }
    var resetProjectStats: String { s("Reset this project's stats", "Сбросить статистику проекта") }
    var resetProjectHint: String {
        s("Clears only this project's token history — other projects keep theirs.",
          "Очищает историю токенов только этого проекта — остальные сохранятся.")
    }
    /// Second half of the two-click confirm: the armed button says this until clicked again.
    var resetConfirm: String { s("Reset?", "Сбросить?") }
    var resetConfirmHint: String { s("Click again to clear. This can't be undone.",
                                     "Нажмите ещё раз, чтобы очистить. Отменить нельзя.") }

    // MARK: - Project health

    var healthWarn: String { s("Heavy context — burning tokens",
                               "Тяжёлый контекст — жрёт токены") }
    var healthCritical: String { s("Very heavy context — likely bloated",
                                   "Очень тяжёлый контекст — вероятно раздут") }
    /// Tooltip for a flagged project row: its average cache-read per turn, and — when there
    /// were enough turns to judge — how much the recent turns rose over the project's baseline.
    func healthTooltip(avgCacheRead: String, trend: String?) -> String {
        let base = s("avg \(avgCacheRead) cache-read/turn", "в среднем \(avgCacheRead) cache-read/тёрн")
        guard let trend else { return base }
        return base + s(" · rising \(trend)", " · рост \(trend)")
    }

    var noHeavyReads: String { s("No heavy tool output in this window",
                                 "Нет тяжёлых чтений в этом окне") }
    /// Culprit-row tooltip: where the row's headline cost came from — the result's size, that
    /// size as tokens, and the turns it sat in the context being re-read.
    func culpritTooltip(size: String, tokens: String, turns: Int) -> String {
        let base = s("\(size) ≈\(tokens) tokens (estimated from size)",
                     "\(size) ≈\(tokens) токенов (оценка по размеру)")
        guard turns > 0 else { return base }
        return base + s(", re-read over \(turns) \(turns == 1 ? "turn" : "turns")",
                        ", перечитано за \(turns) \(pluralRu(turns, "тёрн", "тёрна", "тёрнов"))")
    }

    // MARK: - Relative time ("in 2h 10m" / "in 3d" / "now")

    func relativeFuture(minutes: Int) -> String {
        if minutes < 60 { return s("in \(minutes)m", "через \(minutes)м") }
        let hours = minutes / 60
        if hours < 48 { return s("in \(hours)h \(minutes % 60)m", "через \(hours)ч \(minutes % 60)м") }
        return s("in \(hours / 24)d", "через \(hours / 24)д")
    }

    // MARK: - Notifications

    var notifApprove: String { s("Approve", "Одобрить") }
    var notifDeny: String { s("Deny", "Отклонить") }
    var notifReply: String { s("Reply…", "Ответить…") }
    var notifSend: String { s("Send", "Отправить") }
    var notifReplyPlaceholder: String { s("Type your reply to Claude…",
                                          "Введите ответ для Claude…") }
    var notifApproveTitle: String { s("Approve command?", "Одобрить команду?") }
    func notifMatchesRule(_ rule: String, command: String) -> String {
        s("⚠️ matches \"\(rule)\"\n\(command)", "⚠️ совпадает с «\(rule)»\n\(command)")
    }
    var notifClaudeWaiting: String { s("Claude is waiting", "Claude ожидает") }
}
