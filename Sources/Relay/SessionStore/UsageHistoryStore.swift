import Foundation
import Combine

/// The two independent usage limits Claude Code reports.
enum UsageWindowKind: String, Codable {
    case fiveHour
    case weekly
}

/// A single point-in-time reading of the account's usage limits. Fed by the same
/// status-line updates that drive `RateLimitStore`, but retained as a series so the
/// history UI can draw the curve inside the current window and derive projections.
///
/// Either fraction may be absent — Claude Code reports the two windows independently
/// (see `RateLimitSnapshot`), so a sample can carry just one of them.
struct UsageSample: Equatable, Codable {
    var at: Date
    /// Fraction 0…1 of the 5-hour window consumed at `at`, if known.
    var fiveHour: Double?
    /// Fraction 0…1 of the weekly window consumed at `at`, if known.
    var weekly: Double?
}

/// A completed usage window, closed out when its reset time rolls over. `peakFraction`
/// is the highest fraction observed while the window was open; `hitLimit` records
/// whether it effectively reached the cap (the status line rarely reports a clean 100%).
struct UsageWindow: Equatable, Codable, Identifiable {
    var id: UUID
    var kind: UsageWindowKind
    var startedAt: Date
    var endedAt: Date
    var peakFraction: Double
    var hitLimit: Bool

    init(id: UUID = UUID(), kind: UsageWindowKind, startedAt: Date, endedAt: Date,
         peakFraction: Double, hitLimit: Bool) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.peakFraction = peakFraction
        self.hitLimit = hitLimit
    }
}

/// Accumulates the usage series and the roll-up of completed windows, persisting both
/// so the history survives relaunch. All mutation is funneled onto the main actor,
/// mirroring `RateLimitStore`; `RateLimitStore` owns the "which window are we in"
/// bookkeeping and calls into here (see Phase 1).
@MainActor
final class UsageHistoryStore: ObservableObject {
    /// Raw usage series, oldest first, pruned to `sampleMaxAge`.
    @Published private(set) var samples: [UsageSample] = []
    /// Completed windows, oldest first, capped at `windowCap`.
    @Published private(set) var windows: [UsageWindow] = []

    // MARK: Tuning

    /// Drop samples older than this so the series file stays bounded.
    private static let sampleMaxAge: TimeInterval = 14 * 24 * 3600   // 14 days
    /// Keep at most this many completed windows (they are small; months fit).
    private static let windowCap = 200
    /// A new sample is only recorded when a fraction moved at least this much …
    private static let minFractionDelta = 0.01
    /// … or at least this long has passed since the last sample. Together these throttle
    /// the status line, which can fire many times a minute.
    private static let minSampleInterval: TimeInterval = 5 * 60
    /// Peak at or above this counts as having hit the limit.
    static let hitLimitThreshold = 0.98

    // MARK: Persistence locations

    /// Directory the two JSON files live in. Injectable so tests stay off the real
    /// `~/.claude/relay`.
    private let directory: URL
    private var samplesURL: URL { directory.appendingPathComponent("usage-samples.json", isDirectory: false) }
    private var windowsURL: URL { directory.appendingPathComponent("usage-windows.json", isDirectory: false) }

    init(directory: URL = ConfigStore.directory) {
        self.directory = directory
        if let data = try? Data(contentsOf: samplesURL),
           let saved = try? JSONDecoder().decode([UsageSample].self, from: data) {
            samples = saved
        }
        if let data = try? Data(contentsOf: windowsURL),
           let saved = try? JSONDecoder().decode([UsageWindow].self, from: data) {
            let cleaned = Self.sanitized(saved)
            windows = cleaned
            // Rewrite once if we dropped overlaps left by the old rollover logic, so the
            // fix is durable rather than re-applied on every launch.
            if cleaned.count != saved.count { persistWindows() }
        }
    }

    /// Collapse impossible overlaps between same-kind windows — you can't be in two 5-hour
    /// (or two weekly) windows at once, so an overlap is corrupt data (from the old
    /// rollover heuristic spuriously opening a window while one was still running). Within a
    /// cluster of overlapping windows we keep the one with the highest peak (the most likely
    /// "real" one) and drop the rest. Legitimate gaps between windows are preserved.
    static func sanitized(_ windows: [UsageWindow]) -> [UsageWindow] {
        var kept: [UsageWindow] = []
        for kind in [UsageWindowKind.fiveHour, .weekly] {
            let ordered = windows.filter { $0.kind == kind }.sorted { $0.startedAt < $1.startedAt }
            var acc: [UsageWindow] = []
            for window in ordered {
                if let last = acc.last, window.startedAt < last.endedAt {
                    // Overlaps the one we're holding — keep whichever peaked higher.
                    if window.peakFraction > last.peakFraction { acc[acc.count - 1] = window }
                } else {
                    acc.append(window)
                }
            }
            kept.append(contentsOf: acc)
        }
        return kept.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Mutation

    /// Append a usage reading, subject to throttling. Returns whether a sample was
    /// actually stored (useful for tests). Old samples are pruned relative to `at`.
    @discardableResult
    func recordSample(fiveHour: Double?, weekly: Double?, at: Date) -> Bool {
        guard fiveHour != nil || weekly != nil else { return false }
        if let last = samples.last, !Self.shouldRecord(previous: last, fiveHour: fiveHour, weekly: weekly, at: at) {
            return false
        }
        samples.append(UsageSample(at: at, fiveHour: fiveHour, weekly: weekly))
        prune(now: at)
        persistSamples()
        return true
    }

    /// Record a window that has just closed. Kept oldest-first and capped.
    func recordWindow(_ window: UsageWindow) {
        windows.append(window)
        if windows.count > Self.windowCap {
            windows.removeFirst(windows.count - Self.windowCap)
        }
        persistWindows()
    }

    // MARK: Throttling / pruning

    /// Record when a fraction moved enough, or enough time elapsed. A brand-new window
    /// (fraction dropped vs. the previous sample) always passes so the reset shows up.
    private static func shouldRecord(previous: UsageSample, fiveHour: Double?, weekly: Double?, at: Date) -> Bool {
        if at.timeIntervalSince(previous.at) >= minSampleInterval { return true }
        let fiveDelta = delta(previous.fiveHour, fiveHour)
        let weekDelta = delta(previous.weekly, weekly)
        return fiveDelta >= minFractionDelta || weekDelta >= minFractionDelta
    }

    /// Absolute change between two optional fractions; `0` when either is missing.
    private static func delta(_ a: Double?, _ b: Double?) -> Double {
        guard let a, let b else { return 0 }
        return abs(a - b)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.sampleMaxAge)
        if let first = samples.first, first.at < cutoff {
            samples.removeAll { $0.at < cutoff }
        }
    }

    // MARK: Persistence (best-effort; failures are non-fatal)

    private func persistSamples() { write(samples, to: samplesURL) }
    private func persistWindows() { write(windows, to: windowsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
