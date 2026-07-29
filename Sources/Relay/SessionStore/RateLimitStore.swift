import Foundation
import Combine

/// A parsed snapshot of the account's usage limits.
///
/// The numbers come from Claude Code's **status line**: when Relay's status-line script
/// is installed, Claude Code pipes it a JSON blob that includes `rate_limits.five_hour`
/// / `rate_limits.seven_day` (`used_percentage` + `resets_at`), and the script forwards
/// those to the daemon. Each window may be independently absent (they only appear for
/// Claude.ai Pro/Max after the first API response in a session), so every field is
/// optional and the UI simply omits what it doesn't have.
///
/// A third window — Fable's own weekly allowance — exists on plans that meter that model
/// separately. It is *not* reported alongside the other two: only a response from Fable
/// itself carries `anthropic-ratelimit-unified-7d_oi-*` (Haiku and even Opus responses
/// omit it), so it refreshes on its own, slower schedule. See `UsagePinger`.
struct RateLimitSnapshot: Equatable, Codable {
    /// Fraction 0…1 of the 5-hour window consumed.
    var fiveHourFraction: Double?
    /// Fraction 0…1 of the weekly (7-day) window consumed.
    var weeklyFraction: Double?
    /// Fraction 0…1 of Fable's separate weekly window, when the plan meters one.
    var fableWeeklyFraction: Double?
    /// When the 5-hour window resets.
    var fiveHourResetAt: Date?
    /// When the weekly window resets.
    var weeklyResetAt: Date?
    /// When Fable's weekly window resets.
    var fableWeeklyResetAt: Date?
    /// When this snapshot was last updated.
    var capturedAt: Date

    init(fiveHourFraction: Double? = nil, weeklyFraction: Double? = nil,
         fableWeeklyFraction: Double? = nil,
         fiveHourResetAt: Date? = nil, weeklyResetAt: Date? = nil,
         fableWeeklyResetAt: Date? = nil, capturedAt: Date) {
        self.fiveHourFraction = fiveHourFraction
        self.weeklyFraction = weeklyFraction
        self.fableWeeklyFraction = fableWeeklyFraction
        self.fiveHourResetAt = fiveHourResetAt
        self.weeklyResetAt = weeklyResetAt
        self.fableWeeklyResetAt = fableWeeklyResetAt
        self.capturedAt = capturedAt
    }

    var fiveHourPercent: Int? { fiveHourFraction.map { Int(($0 * 100).rounded()) } }
    var weeklyPercent: Int? { weeklyFraction.map { Int(($0 * 100).rounded()) } }
    var fableWeeklyPercent: Int? { fableWeeklyFraction.map { Int(($0 * 100).rounded()) } }

    // MARK: - Reading a window
    //
    // Every window is read three ways, and the difference matters:
    //
    //   `…Fresh`    — the value only while its window is genuinely still open. `nil` once
    //                 the reset has passed. This is the "is there a live window" question,
    //                 and history/charts must use it: a rolled-over window is over.
    //   `…Display`  — what to *show*. Same as fresh while open, then `0`, because a window
    //                 that reset is empty rather than unknown. Blanking it made the
    //                 menu-bar label silently drop one of its numbers, which reads as a
    //                 broken app rather than as a reset. Still `nil` when we have never had
    //                 a reading at all — there is nothing to be empty.
    //   `…RolledOver` — the value shown belongs to a new window and the stored reset time
    //                 is in the past, so a countdown to it would be nonsense.
    //
    // The zero is the best available reading, not a measured one: if nothing has refreshed
    // the snapshot since the rollover (a dead usage feed), real usage may already have
    // climbed. It self-corrects on the next update.

    /// The fraction only while its window is still open; `nil` once `reset` has passed.
    private static func fresh(_ fraction: Double?, _ reset: Date?) -> Double? {
        guard let fraction else { return nil }
        if let reset, reset <= Date() { return nil }
        return fraction
    }

    /// The fraction to show: live value, `0` after a rollover, `nil` if never read.
    private static func display(_ fraction: Double?, _ reset: Date?) -> Double? {
        fraction == nil ? nil : (fresh(fraction, reset) ?? 0)
    }

    var fiveHourFractionFresh: Double? { Self.fresh(fiveHourFraction, fiveHourResetAt) }
    var weeklyFractionFresh: Double? { Self.fresh(weeklyFraction, weeklyResetAt) }
    var fableWeeklyFractionFresh: Double? { Self.fresh(fableWeeklyFraction, fableWeeklyResetAt) }

    var fiveHourFractionDisplay: Double? { Self.display(fiveHourFraction, fiveHourResetAt) }
    var weeklyFractionDisplay: Double? { Self.display(weeklyFraction, weeklyResetAt) }
    var fableWeeklyFractionDisplay: Double? { Self.display(fableWeeklyFraction, fableWeeklyResetAt) }

    var fiveHourRolledOver: Bool { fiveHourFraction != nil && fiveHourFractionFresh == nil }
    var weeklyRolledOver: Bool { weeklyFraction != nil && weeklyFractionFresh == nil }
    var fableWeeklyRolledOver: Bool { fableWeeklyFraction != nil && fableWeeklyFractionFresh == nil }

}

/// Holds the most recent rate-limit snapshot and publishes it to the UI. Fed by the
/// status-line script via `POST /usage`; all mutation is funneled onto the main actor.
@MainActor
final class RateLimitStore: ObservableObject {
    @Published private(set) var snapshot: RateLimitSnapshot?

    /// The long-lived history (series + completed windows) this store feeds. Exposed so
    /// the history UI can observe it.
    let history: UsageHistoryStore

    /// The nominal length of each window, used to back-date a window's start from its
    /// reset time so the history shows correct start/end labels.
    private static func duration(_ kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour:            return 5 * 3600
        case .weekly, .fableWeekly: return 7 * 24 * 3600
        }
    }

    /// In-flight tracking of the window currently accumulating for each kind: where it
    /// began, the reset time we last saw for it, and the highest fraction observed.
    private struct OpenWindow {
        var startedAt: Date
        var resetAt: Date?
        var peak: Double
    }
    private var openFive: OpenWindow?
    private var openWeek: OpenWindow?
    private var openFable: OpenWindow?


    /// Where the last snapshot is cached so the menu bar can show figures immediately on
    /// launch, before the status line has fired again. Injectable so tests stay off the
    /// real `~/.claude/relay`.
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("usage.json", isDirectory: false) }

    init(directory: URL = ConfigStore.directory,
         history: UsageHistoryStore? = nil) {
        self.directory = directory
        self.history = history ?? UsageHistoryStore(directory: directory)
        // Restore the last-known snapshot (if any) so a relaunch doesn't blank the usage
        // meters until the next status-line update.
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(RateLimitSnapshot.self, from: data) {
            snapshot = saved
            // Re-open the in-flight windows from the restored snapshot so a relaunch
            // mid-window doesn't drop the peak we'd accumulated.
            openFive = Self.reopen(fraction: saved.fiveHourFractionFresh, reset: saved.fiveHourResetAt, kind: .fiveHour)
            openWeek = Self.reopen(fraction: saved.weeklyFractionFresh, reset: saved.weeklyResetAt, kind: .weekly)
            openFable = Self.reopen(fraction: saved.fableWeeklyFractionFresh,
                                    reset: saved.fableWeeklyResetAt, kind: .fableWeekly)
        }
    }

    /// Rebuild an `OpenWindow` from a restored fraction, back-dating its start from the
    /// reset time when we have one.
    private static func reopen(fraction: Double?, reset: Date?, kind: UsageWindowKind) -> OpenWindow? {
        guard let fraction else { return nil }
        let started = reset.map { $0.addingTimeInterval(-duration(kind)) } ?? Date()
        return OpenWindow(startedAt: started, resetAt: reset, peak: fraction)
    }

    /// Ingest a usage update forwarded by the status-line script. Windows are merged:
    /// a window that isn't present in this update keeps its previous value (Claude Code
    /// may report the windows independently, and Fable's arrives only on the rarer Fable
    /// ping), so we never blank a good figure. Percentages are 0…100.
    func ingestStatusline(fiveHourPercent: Double?, fiveHourReset: Date?,
                          weeklyPercent: Double?, weeklyReset: Date?,
                          fableWeeklyPercent: Double? = nil, fableWeeklyReset: Date? = nil) {
        guard fiveHourPercent != nil || weeklyPercent != nil || fableWeeklyPercent != nil else { return }
        var snap = snapshot ?? RateLimitSnapshot(capturedAt: Date())
        if let five = fiveHourPercent {
            snap.fiveHourFraction = Self.clamp01(five / 100)
            snap.fiveHourResetAt = fiveHourReset
        }
        if let week = weeklyPercent {
            snap.weeklyFraction = Self.clamp01(week / 100)
            snap.weeklyResetAt = weeklyReset
        }
        if let fable = fableWeeklyPercent {
            snap.fableWeeklyFraction = Self.clamp01(fable / 100)
            snap.fableWeeklyResetAt = fableWeeklyReset
        }
        snap.capturedAt = Date()
        snapshot = snap
        persist(snap)

        // Feed the history: advance each window (closing one out on rollover) and append
        // a throttled sample of the current fractions.
        let now = snap.capturedAt
        advance(&openFive, kind: .fiveHour,
                fraction: fiveHourPercent.map { Self.clamp01($0 / 100) }, reset: fiveHourReset, now: now)
        advance(&openWeek, kind: .weekly,
                fraction: weeklyPercent.map { Self.clamp01($0 / 100) }, reset: weeklyReset, now: now)
        // Fable's window only advances on the ingests that actually carry it (a Fable ping);
        // `advance` no-ops on a nil fraction, so the frequent Haiku ingests leave it alone.
        advance(&openFable, kind: .fableWeekly,
                fraction: fableWeeklyPercent.map { Self.clamp01($0 / 100) }, reset: fableWeeklyReset, now: now)
        history.recordSample(fiveHour: snap.fiveHourFraction, weekly: snap.weeklyFraction,
                             fableWeekly: snap.fableWeeklyFraction, at: now)

        Log.info("usage: 5h \(snap.fiveHourPercent.map { "\($0)%" } ?? "—") · "
                 + "7d \(snap.weeklyPercent.map { "\($0)%" } ?? "—")"
                 + (snap.fableWeeklyPercent.map { " · 7d-fable \($0)%" } ?? ""))
    }

    /// Ingest usage from the `anthropic-ratelimit-*` response headers captured by the
    /// usage proxy (off Relay's own periodic ping). The unified `-utilization` value is
    /// already a 0…1 fraction and `-reset` is an epoch; we convert and feed the same path
    /// as the status line, so snapshot, persistence, and history all update together.
    ///
    /// `7d_oi` is Fable's own weekly window. Only a Fable response carries it — a Haiku or
    /// Opus response simply omits the header — so most ingests leave that window untouched
    /// and it keeps its last reading.
    func ingestHeaders(_ headers: [String: String]) {
        func fraction(_ prefix: String) -> Double? {
            guard let raw = headers["\(prefix)-utilization"] else { return nil }
            return Double(raw.trimmingCharacters(in: .whitespaces))
        }
        func reset(_ prefix: String) -> Date? {
            guard let raw = headers["\(prefix)-reset"]?.trimmingCharacters(in: .whitespaces),
                  let seconds = Double(raw), seconds > 0 else { return nil }
            // Large values are absolute epoch seconds; small ones are seconds-from-now.
            return seconds > 1_000_000_000 ? Date(timeIntervalSince1970: seconds)
                                           : Date().addingTimeInterval(seconds)
        }
        let five = fraction("anthropic-ratelimit-unified-5h")
        let week = fraction("anthropic-ratelimit-unified-7d")
        let fable = fraction("anthropic-ratelimit-unified-7d_oi")
        ingestStatusline(
            fiveHourPercent: five.map { $0 * 100 },
            fiveHourReset: reset("anthropic-ratelimit-unified-5h"),
            weeklyPercent: week.map { $0 * 100 },
            weeklyReset: reset("anthropic-ratelimit-unified-7d"),
            fableWeeklyPercent: fable.map { $0 * 100 },
            fableWeeklyReset: reset("anthropic-ratelimit-unified-7d_oi")
        )
    }

    /// Advance one window's in-flight tracking with a fresh reading. When the reading
    /// indicates the window rolled over (its reset moved on, or its fraction dropped),
    /// the previous window is closed out into history and a new one begins; otherwise the
    /// running peak is raised.
    private func advance(_ open: inout OpenWindow?, kind: UsageWindowKind,
                         fraction: Double?, reset: Date?, now: Date) {
        guard let fraction else { return }   // no reading for this window this time
        guard var current = open else {
            open = OpenWindow(startedAt: Self.windowStart(reset: reset, kind: kind, now: now),
                              resetAt: reset, peak: fraction)
            return
        }
        if Self.isRollover(current, kind: kind, fraction: fraction, reset: reset) {
            let window = UsageWindow(
                kind: kind,
                startedAt: current.startedAt,
                endedAt: current.resetAt ?? now,
                peakFraction: current.peak,
                hitLimit: current.peak >= UsageHistoryStore.hitLimitThreshold
            )
            history.recordWindow(window)
            open = OpenWindow(startedAt: Self.windowStart(reset: reset, kind: kind, now: now),
                              resetAt: reset, peak: fraction)
        } else {
            current.peak = max(current.peak, fraction)
            current.resetAt = reset ?? current.resetAt
            open = current
        }
    }

    /// Whether this reading belongs to a *new* window — i.e. the one we're tracking has
    /// reset. The reset time is the source of truth for window boundaries, so it decides:
    ///
    /// A genuine reset jumps the reset time forward by roughly a whole window (a 5-hour
    /// window resets ~5h later, a weekly one ~7d later); a reading whose reset lands more
    /// than half a window past the tracked one therefore belongs to a later window. Smaller
    /// forward movement is jitter — the proxy headers encode the reset as seconds-from-now,
    /// so it drifts between readings and disagrees with the status line's absolute time — and
    /// stays in the same window. Because boundaries are derived from the reset (not from
    /// "now"), a reset detected late still closes/opens windows at the correct times.
    ///
    /// The usage fraction is only a backup, for when the reset can't decide — it's absent,
    /// or lagging behind the collapse: a fall to near-zero from a substantial peak is the
    /// unmistakable signature of a reset. A mid-range dip is not, and is ignored (it used to
    /// close windows spuriously).
    private static func isRollover(_ current: OpenWindow, kind: UsageWindowKind,
                                   fraction: Double, reset: Date?) -> Bool {
        if let known = current.resetAt, let reset,
           reset > known.addingTimeInterval(duration(kind) * 0.5) { return true }
        return current.peak >= 0.5 && fraction < 0.10
    }

    /// Back-date a window's start from its reset when known, else start it now.
    private static func windowStart(reset: Date?, kind: UsageWindowKind, now: Date) -> Date {
        reset.map { $0.addingTimeInterval(-duration(kind)) } ?? now
    }

    /// Cache the snapshot to disk (best-effort; failures are non-fatal).
    private func persist(_ snapshot: RateLimitSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}
