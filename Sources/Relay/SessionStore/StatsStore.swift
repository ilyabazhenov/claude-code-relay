import Foundation
import Combine

/// Persistent tally of how many Claude Code sessions have finished ("chats that
/// completed their work"). The in-memory `SessionStore` prunes an `ended` session ~30s
/// after it finishes, so without this the count would evaporate; here we keep a running
/// total plus a per-day count that rolls over at local midnight.
///
/// Fed from `SessionStore`'s transition into `ended` (deduped there, so a session that
/// ends once is counted once), and observed by the menu's statistics section.
@MainActor
final class StatsStore: ObservableObject {
    /// The stored figures, persisted verbatim.
    private struct Stats: Codable {
        var total: Int = 0
        /// Local `yyyy-MM-dd` the `today` count belongs to.
        var day: String = ""
        var today: Int = 0
    }

    @Published private(set) var completedTotal: Int = 0
    /// Sessions finished on the current local day. Recomputed against "today" on read so a
    /// stale count from yesterday never shows.
    @Published private(set) var completedToday: Int = 0

    private var stats = Stats()

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("stats.json", isDirectory: false) }

    init(directory: URL = ConfigStore.directory) {
        self.directory = directory
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = saved
        }
        rollDayIfNeeded()
        publish()
    }

    /// Record one finished session. Rolls the day first so the first completion after
    /// midnight starts a fresh daily count.
    func recordCompletion() {
        rollDayIfNeeded()
        stats.total += 1
        stats.today += 1
        persist()
        publish()
    }

    /// If the stored day isn't today, reset the daily count (keeping the total). Called on
    /// launch, before each completion, and can be called from the UI so an idle app still
    /// flips to 0 at midnight.
    func rollDayIfNeeded() {
        let today = Self.dayStamp()
        if stats.day != today {
            stats.day = today
            stats.today = 0
            persist()
            publish()
        }
    }

    private func publish() {
        completedTotal = stats.total
        completedToday = stats.day == Self.dayStamp() ? stats.today : 0
    }

    private static func dayStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
