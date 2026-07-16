import Foundation
import Combine

/// Exact token usage for a single assistant message, tagged with the model that produced
/// it. Unlike the account-wide usage *percentages* (which can't be split per response),
/// these come straight from Claude Code's transcript and are precise and per-model.
struct TokenRecord: Equatable, Codable {
    var at: Date
    var model: String
    var input: Int
    var output: Int
    var cacheCreation: Int
    var cacheRead: Int
    /// The project (`basename(cwd)`) this turn ran in, tagged at ingest from the owning
    /// session. Optional so records written before per-project tagging still decode — they
    /// land in the "unknown" bucket until they age out.
    var project: String? = nil
    /// The session this turn belongs to, tagged at ingest. Turns only count as "later" for
    /// a tool result within its own session, so pricing a result needs this. Optional for
    /// the same back-compat reason as `project`.
    var session: String? = nil

    /// All tokens the message processed. Cache reads dominate for long contexts, so the
    /// UI leans on this as "throughput" rather than a billing figure.
    var total: Int { input + output + cacheCreation + cacheRead }
}

/// One project's token throughput over a window.
struct ProjectUsage: Equatable {
    var project: String
    var total: Int
}

/// How a project's token profile reads over a window. `warn`/`critical` mean it's burning
/// tokens the way a bloated context does — a heavy cache-read every turn for little output,
/// usually big files pulled in or dead-end constructions worth pruning or restarting.
enum ProjectHealth: Int, Comparable {
    case ok, warn, critical
    static func < (lhs: ProjectHealth, rhs: ProjectHealth) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Accumulates per-message token records parsed from session transcripts, so the history
/// UI can show a precise "tokens by model" breakdown. Fed on each `Stop` hook; a per-
/// session byte cursor means each transcript is only ever read forward from where we
/// left off (transcripts are append-only), so nothing is counted twice.
@MainActor
final class TokenUsageStore: ObservableObject {
    @Published private(set) var records: [TokenRecord] = []
    /// Heavy tool results, kept alongside `records` to power the per-project culprit
    /// breakdown. Only results at or above `minToolEventBytes` are stored — tiny ones are
    /// noise and would bloat the file without ever ranking.
    @Published private(set) var toolEvents: [ToolEvent] = []

    /// Per-session byte offset into the transcript we've already consumed.
    private var cursors: [String: UInt64] = [:]
    /// Spill-file path → the tool that produced it, accumulated across ingests. Lets a `Read`
    /// of a persisted-output file be credited to its origin call even when the spill and the
    /// read land in different chunks. Keyed by absolute path, which is unique per session.
    private var spills: [String: SpillOrigin] = [:]

    private static let recordMaxAge: TimeInterval = 14 * 24 * 3600
    /// Below this, a tool result is too small to ever be a culprit — dropped at ingest.
    static let minToolEventBytes = 2_000

    private let directory: URL
    private var recordsURL: URL { directory.appendingPathComponent("token-records.json", isDirectory: false) }
    private var cursorsURL: URL { directory.appendingPathComponent("token-cursors.json", isDirectory: false) }
    private var toolEventsURL: URL { directory.appendingPathComponent("tool-events.json", isDirectory: false) }
    private var spillsURL: URL { directory.appendingPathComponent("tool-spills.json", isDirectory: false) }

    init(directory: URL = ConfigStore.directory) {
        self.directory = directory
        if let data = try? Data(contentsOf: recordsURL),
           let saved = try? JSONDecoder().decode([TokenRecord].self, from: data) {
            records = saved
        }
        if let data = try? Data(contentsOf: cursorsURL),
           let saved = try? JSONDecoder().decode([String: UInt64].self, from: data) {
            cursors = saved
        }
        if let data = try? Data(contentsOf: toolEventsURL),
           let saved = try? JSONDecoder().decode([ToolEvent].self, from: data) {
            toolEvents = saved
        }
        if let data = try? Data(contentsOf: spillsURL),
           let saved = try? JSONDecoder().decode([String: SpillOrigin].self, from: data) {
            spills = saved
        }
    }

    // MARK: Ingest

    /// Parse any new assistant messages appended to `transcriptPath` since we last read it
    /// for this session, and fold their token usage into the record series. Each new record
    /// is tagged with `project` (the owning session's `basename(cwd)`) so the breakdown can
    /// group by project — the parser doesn't know the project, so we stamp it here.
    func ingest(sessionId: String, transcriptPath: String?, project: String?) {
        guard let path = transcriptPath, !path.isEmpty else { return }
        let parsed = TranscriptTokens.parse(path: path, fromOffset: cursors[sessionId] ?? 0, knownSpills: spills)
        guard let parsed else { return }
        cursors[sessionId] = parsed.newOffset
        persistCursors()
        updateSpills(parsed.spills)

        if !parsed.records.isEmpty {
            add(parsed.records.map { record in
                var copy = record; copy.project = project; copy.session = sessionId; return copy
            })
        }
        let culprits = parsed.toolEvents
            .filter { $0.bytes >= Self.minToolEventBytes }
            .map { event -> ToolEvent in
                var copy = event; copy.project = project; copy.session = sessionId; return copy
            }
        if !culprits.isEmpty { addToolEvents(culprits) }
    }

    /// Adopt the parser's merged spill map, dropping entries older than the record window so
    /// a long-lived store doesn't accumulate dead spill paths. Persists only on a change.
    private func updateSpills(_ merged: [String: SpillOrigin]) {
        let cutoff = Date().addingTimeInterval(-Self.recordMaxAge)
        let pruned = merged.filter { $0.value.at >= cutoff }
        guard pruned != spills else { return }
        spills = pruned
        persistSpills()
    }

    /// Append records, prune the old, and persist. Shared by ingest and the preview seed.
    func add(_ newRecords: [TokenRecord]) {
        records.append(contentsOf: newRecords)
        let cutoff = Date().addingTimeInterval(-Self.recordMaxAge)
        if let first = records.first, first.at < cutoff {
            records.removeAll { $0.at < cutoff }
        }
        persistRecords()
    }

    /// Append tool events, prune the old, and persist. Mirrors `add(_:)` for `records`.
    func addToolEvents(_ newEvents: [ToolEvent]) {
        toolEvents.append(contentsOf: newEvents)
        let cutoff = Date().addingTimeInterval(-Self.recordMaxAge)
        if let first = toolEvents.first, first.at < cutoff {
            toolEvents.removeAll { $0.at < cutoff }
        }
        persistToolEvents()
    }

    // MARK: Reset

    /// Drop the whole accumulated history so the breakdown starts over from the next turn.
    /// Cursors deliberately survive: they mark how far into each transcript we've already
    /// read, and keeping them is what stops the cleared history from being re-ingested on
    /// the next `Stop` hook.
    func resetAll() {
        guard !records.isEmpty || !toolEvents.isEmpty else { return }
        records.removeAll()
        toolEvents.removeAll()
        persistRecords()
        persistToolEvents()
    }

    /// Drop one project's history, leaving the others intact. `project` is matched the way
    /// the breakdown groups, so the untagged bucket is addressed by `unknownProject`.
    func reset(project: String) {
        let before = (records.count, toolEvents.count)
        records.removeAll { ($0.project ?? Self.unknownProject) == project }
        toolEvents.removeAll { ($0.project ?? Self.unknownProject) == project }
        guard before != (records.count, toolEvents.count) else { return }
        persistRecords()
        persistToolEvents()
    }

    // MARK: Aggregation

    /// Total tokens per model since `since`, largest first. Pure so it can be unit tested.
    nonisolated static func tokensByModel(_ records: [TokenRecord], since: Date) -> [(model: String, total: Int)] {
        var totals: [String: Int] = [:]
        for record in records where record.at >= since {
            totals[record.model, default: 0] += record.total
        }
        return totals.map { (model: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Placeholder bucket for records written before per-project tagging (project == nil).
    nonisolated static let unknownProject = ""

    /// Total tokens per project since `since`, largest first. Pre-tagging records fold into
    /// `unknownProject`. Pure so it can be unit tested.
    nonisolated static func tokensByProject(_ records: [TokenRecord], since: Date) -> [ProjectUsage] {
        var totals: [String: Int] = [:]
        for record in records where record.at >= since {
            totals[record.project ?? unknownProject, default: 0] += record.total
        }
        return totals.map { ProjectUsage(project: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    // MARK: Project health

    /// Cache-read-per-turn floors — the "safety net" signal. A bloated context re-reads
    /// nearly everything each turn, so a high sustained cache-read is the clearest sign a
    /// project has gone bad (big files pulled in, dead-end constructions) regardless of
    /// history. Opus tops out near 200K, so ~180K/turn means an almost-full window every turn.
    nonisolated static let cacheReadWarn = 100_000
    nonisolated static let cacheReadCritical = 180_000
    /// Baseline-deviation signal: how much heavier the recent turns run than the project's
    /// own early turns before it reads as degrading. Gated by `trendFloor` so a project that
    /// merely doubled from tiny-to-small doesn't trip.
    nonisolated static let trendWarn = 1.6
    nonisolated static let trendCritical = 2.5
    nonisolated static let trendFloor = 45_000
    /// Too few turns to trust an average or a trend — stay silent rather than flag noise.
    nonisolated static let minTurnsForHealth = 4
    /// Need this many turns before splitting into thirds for a trend read.
    nonisolated static let minTurnsForTrend = 6

    /// One project's token vitals over a window — the inputs behind its `health`, surfaced
    /// in the row tooltip so a flag is explainable rather than a mystery dot.
    struct ProjectVitals: Equatable {
        var project: String
        var turns: Int
        /// Average cache-read tokens per assistant turn — the bloated-context fingerprint.
        var avgCacheRead: Int
        /// Last-third vs first-third average cache-read across the window's turns (the
        /// project's own baseline), or nil when there are too few turns to judge a trend.
        var trend: Double?
        var health: ProjectHealth
    }

    /// Per-project health over `since`, worst first. Combines both signals the way the
    /// design calls for: an absolute cache-read floor (catches objectively-heavy projects
    /// even before a trend exists) OR an upward deviation from the project's own baseline.
    /// The untagged bucket is excluded — it mixes many projects, so its average is noise.
    /// Pure so it can be unit tested.
    nonisolated static func projectVitals(_ records: [TokenRecord], since: Date) -> [ProjectVitals] {
        var byProject: [String: [TokenRecord]] = [:]
        for record in records where record.at >= since {
            let key = record.project ?? unknownProject
            guard key != unknownProject else { continue }
            byProject[key, default: []].append(record)
        }
        return byProject.map { project, recs -> ProjectVitals in
            let sorted = recs.sorted { $0.at < $1.at }
            let turns = sorted.count
            let avg = turns > 0 ? sorted.reduce(0) { $0 + $1.cacheRead } / turns : 0
            let trend = cacheReadTrend(sorted)
            return ProjectVitals(project: project, turns: turns, avgCacheRead: avg,
                                 trend: trend, health: health(avgCacheRead: avg, trend: trend, turns: turns))
        }
        .sorted { $0.health > $1.health }
    }

    /// Ratio of the last third's average cache-read to the first third's, or nil when there
    /// aren't enough turns or the early baseline is empty.
    nonisolated private static func cacheReadTrend(_ sorted: [TokenRecord]) -> Double? {
        guard sorted.count >= minTurnsForTrend else { return nil }
        let third = sorted.count / 3
        let firstAvg = averageCacheRead(sorted.prefix(third))
        let lastAvg = averageCacheRead(sorted.suffix(third))
        guard firstAvg > 0 else { return nil }
        return Double(lastAvg) / Double(firstAvg)
    }

    nonisolated private static func averageCacheRead<S: Sequence>(_ recs: S) -> Int where S.Element == TokenRecord {
        var sum = 0, count = 0
        for record in recs { sum += record.cacheRead; count += 1 }
        return count > 0 ? sum / count : 0
    }

    nonisolated static func health(avgCacheRead: Int, trend: Double?, turns: Int) -> ProjectHealth {
        guard turns >= minTurnsForHealth else { return .ok }
        let t = trend ?? 0
        if avgCacheRead >= cacheReadCritical || (t >= trendCritical && avgCacheRead >= trendFloor) { return .critical }
        if avgCacheRead >= cacheReadWarn || (t >= trendWarn && avgCacheRead >= trendFloor) { return .warn }
        return .ok
    }

    // MARK: Culprit breakdown

    /// Rough bytes-per-token for tool output. Only ever used to turn a result's size into a
    /// token count for pricing and display, so a coarse constant is honest enough.
    nonisolated static let bytesPerToken = 4
    /// A turn whose cache-read collapses to a fraction of the previous turn's is a context
    /// reset — a compaction or a `/clear`. Everything read before it is gone from the window,
    /// so it stops being charged from there on.
    nonisolated static let resetDropRatio = 0.5
    /// Below this, a turn's cache-read is too small and too jumpy for a drop to mean anything
    /// — early-session noise would otherwise read as a reset on every other turn.
    nonisolated static let resetFloor = 50_000

    /// A project's costliest tool targets since `since`, dearest first. Repeat reads of the
    /// same target fold into one row carrying the summed bytes, the repeat count, and the
    /// summed cost. Pure so it can be unit tested.
    ///
    /// Cost, not size, is what ranks: a result's tokens are re-read on every later turn of
    /// its session, so what it truly cost is `tokens × turns resident`. Size alone points at
    /// the wrong row — it can't tell a 50KB read at the end of a session (paid once) from a
    /// 12KB read at the start (paid two hundred times over).
    nonisolated static func topCulprits(_ events: [ToolEvent], records: [TokenRecord],
                                        project: String, since: Date, limit: Int = 5) -> [Culprit] {
        let turnsBySession = sessionTurns(records, project: project, since: since)
        var byTarget: [String: Culprit] = [:]
        for event in events where event.at >= since && (event.project ?? unknownProject) == project {
            let key = event.tool + "\u{0}" + event.target
            var culprit = byTarget[key] ?? Culprit(tool: event.tool, target: event.target,
                                                   bytes: 0, count: 0, cost: 0, turns: 0)
            // An event predating session tagging can't be priced — nothing says which turns
            // followed it — so it's charged once. That ranks it by size, as before, until it
            // ages out of the window.
            let resident = event.session
                .flatMap { turnsBySession[$0] }
                .map { residence($0, after: event.at) } ?? 1
            culprit.bytes += event.bytes
            culprit.count += 1
            culprit.turns += resident
            culprit.cost += (event.bytes / bytesPerToken) * resident
            byTarget[key] = culprit
        }
        return byTarget.values.sorted { $0.cost > $1.cost }.prefix(limit).map { $0 }
    }

    /// One session's turns within the window: when each happened, ascending, and when its
    /// context was reset (which evicts everything read before that point).
    struct SessionTurns: Equatable {
        var times: [Date] = []
        var resets: [Date] = []
    }

    /// Turn times and reset points per session, for the given project's window. Records
    /// predating session tagging are skipped rather than pooled — pooling separate sessions
    /// would credit one session's turns to another's reads and inflate every price.
    nonisolated static func sessionTurns(_ records: [TokenRecord], project: String,
                                         since: Date) -> [String: SessionTurns] {
        var bySession: [String: [TokenRecord]] = [:]
        for record in records where record.at >= since && (record.project ?? unknownProject) == project {
            guard let session = record.session else { continue }
            bySession[session, default: []].append(record)
        }
        return bySession.mapValues { recs in
            let sorted = recs.sorted { $0.at < $1.at }
            var turns = SessionTurns(times: sorted.map(\.at))
            for (prev, next) in zip(sorted, sorted.dropFirst())
            where prev.cacheRead >= resetFloor
                && Double(next.cacheRead) < Double(prev.cacheRead) * resetDropRatio {
                turns.resets.append(next.at)
            }
            return turns
        }
    }

    /// How many turns a result read at `at` stayed in the context: every later turn of its
    /// session, up to the first reset that dropped it.
    nonisolated static func residence(_ turns: SessionTurns, after at: Date) -> Int {
        let evicted = turns.resets.first { $0 > at } ?? .distantFuture
        return turns.times.reduce(into: 0) { count, time in
            if time > at && time < evicted { count += 1 }
        }
    }

    // MARK: Persistence (best-effort)

    private func persistRecords() { write(records, to: recordsURL) }
    private func persistCursors() { write(cursors, to: cursorsURL) }
    private func persistToolEvents() { write(toolEvents, to: toolEventsURL) }
    private func persistSpills() { write(spills, to: spillsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// One tool call and how much its result weighed — the raw material for the per-project
/// "culprit" breakdown. `bytes` is the size of the `tool_result` content that landed back
/// in the context (Claude Code truncates very large results, so this is what actually
/// bloated the window, not the file's size on disk). `target` is the file path for
/// file tools or the command for `Bash`, so repeat reads of the same thing fold together.
struct ToolEvent: Equatable, Codable {
    var at: Date
    var tool: String
    var target: String
    var bytes: Int
    /// The project this ran in, tagged at ingest just like `TokenRecord.project`.
    var project: String? = nil
    /// The session this ran in, tagged at ingest. Pricing counts the turns that followed
    /// this result *in its own session*, so events without it can only be charged once.
    var session: String? = nil
}

/// Which tool produced an oversized result that Claude Code persisted to a spill file under
/// `…/tool-results/`. Used to re-credit later `Read`s of that file to the origin call, so a
/// `git diff` whose output spilled to disk and was read back shows up as `git diff` rather
/// than an opaque random filename. Keyed in the store by the spill file's absolute path.
struct SpillOrigin: Equatable, Codable {
    var tool: String
    var target: String
    /// When the spilling call ran — used only to age the map out, mirroring record pruning.
    var at: Date
}

/// One project's costliest tool target over a window: what its results weighed, how many
/// times it was pulled in, and what that actually cost in re-read tokens.
struct Culprit: Equatable {
    var tool: String
    var target: String
    var bytes: Int
    var count: Int
    /// Tokens re-read on account of this target: its size in tokens times the turns it stayed
    /// in the context, summed over every time it was pulled in. This is what ranks the row —
    /// see `TokenUsageStore.topCulprits`.
    var cost: Int
    /// Turns this target stayed resident, summed over its reads. Carried so the row can say
    /// where its cost came from ("12 KB × 190 turns") rather than assert a bare number.
    var turns: Int
}

/// Pure transcript reader: pulls token records and tool-call weights out of the newly-
/// appended tail of a JSONL transcript, in a single pass. Kept free of actor isolation and
/// app state so it's easy to test.
enum TranscriptTokens {
    struct Result {
        let records: [TokenRecord]
        let toolEvents: [ToolEvent]
        /// Byte offset to resume from next time — advanced only past complete lines, so a
        /// half-flushed final line is re-read (not skipped) on the next call.
        let newOffset: UInt64
        /// Spill-file path → the tool that produced it, seeded from `knownSpills` and grown
        /// with any new mappings this pass found. Claude Code writes a tool's oversized
        /// output to `…/tool-results/<random>.txt` and leaves a `<persisted-output>` stub in
        /// the result; later `Read`s of that file are the origin tool's output coming back
        /// in. Carrying the map forward lets those reads be credited to the origin even when
        /// they land in a later ingest chunk than the call that spilled.
        let spills: [String: SpillOrigin]
    }

    /// Longest a stored `target` is kept — a runaway Bash command shouldn't bloat the store.
    static let maxTargetLength = 400

    /// - Parameter knownSpills: spill→origin mappings discovered on prior calls, so a read of
    ///   a file spilled in an earlier chunk still resolves to its origin tool.
    static func parse(path: String, fromOffset: UInt64, knownSpills: [String: SpillOrigin] = [:]) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // A shrunken file means it rotated/compacted — start over rather than trust a stale
        // offset that now points into the middle of a different line.
        var start = fromOffset
        if start > size { start = 0 }
        guard start < size else { return Result(records: [], toolEvents: [], newOffset: size, spills: knownSpills) }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return Result(records: [], toolEvents: [], newOffset: size, spills: knownSpills)
        }

        // Only consume up to the last newline; leave any trailing partial line for later.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Result(records: [], toolEvents: [], newOffset: start, spills: knownSpills)
        }
        let consumed = data[data.startIndex...lastNewline]
        let newOffset = start + UInt64(consumed.count)

        // Build the ISO parsers once per call (they aren't Sendable, so no shared statics).
        let isoFractional = ISO8601DateFormatter(); isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let timestamp: (String) -> Date? = { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) }

        var records: [TokenRecord] = []
        var toolEvents: [ToolEvent] = []
        // A tool_use (assistant) always precedes its tool_result (user) within a turn, and
        // the Stop hook fires at turn end, so both sit in the same consumed chunk — an
        // in-pass map is enough to stitch them without persisting pending calls.
        var pending: [String: (tool: String, target: String, at: Date)] = [:]
        // Seeded with mappings from earlier chunks so a read whose spill happened before this
        // pass still resolves; grown as new `<persisted-output>` stubs are seen here.
        var spills = knownSpills

        for line in consumed.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            let at = (object["timestamp"] as? String).flatMap(timestamp) ?? Date()

            if type == "assistant", let message = object["message"] as? [String: Any] {
                if let record = tokenRecord(message: message, at: at) { records.append(record) }
                for block in toolUseBlocks(message["content"]) {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    pending[id] = (name, toolTarget(tool: name, input: input), at)
                }
            } else if type == "user", let message = object["message"] as? [String: Any] {
                for block in toolResultBlocks(message["content"]) {
                    guard let id = block["tool_use_id"] as? String, let use = pending[id] else { continue }
                    let content = block["content"]
                    // This call spilled its oversized output to disk — remember which tool
                    // produced that file so later reads of it credit back to the origin.
                    if let spillPath = persistedOutputPath(content) {
                        spills[spillPath] = SpillOrigin(tool: use.tool, target: use.target, at: use.at)
                    }
                    // A read whose target is a known spill file is the origin tool's output
                    // coming back in — relabel it so the two fold into one culprit row.
                    let origin = spills[use.target]
                    toolEvents.append(ToolEvent(at: use.at,
                                                tool: origin?.tool ?? use.tool,
                                                target: origin?.target ?? use.target,
                                                bytes: resultBytes(content)))
                    pending.removeValue(forKey: id)
                }
            }
        }
        return Result(records: records, toolEvents: toolEvents, newOffset: newOffset, spills: spills)
    }

    private static func tokenRecord(message: [String: Any], at: Date) -> TokenRecord? {
        guard let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TokenRecord(
            at: at,
            model: model,
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )
    }

    /// The blocks of a message's `content` (an array of typed blocks, or nothing for a
    /// plain-string user message), filtered to `tool_use` / `tool_result` respectively.
    private static func toolUseBlocks(_ content: Any?) -> [[String: Any]] {
        (content as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "tool_use" }
    }
    private static func toolResultBlocks(_ content: Any?) -> [[String: Any]] {
        (content as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "tool_result" }
    }

    /// What a tool call acted on: the file for file tools, the command for `Bash`, else the
    /// tool name. Capped so a giant command can't bloat the store.
    private static func toolTarget(tool: String, input: [String: Any]) -> String {
        let raw: String
        switch tool {
        case "Read", "Edit", "Write", "MultiEdit":
            raw = (input["file_path"] as? String) ?? tool
        case "NotebookEdit":
            raw = (input["notebook_path"] as? String) ?? tool
        case "Bash":
            let command = (input["command"] as? String) ?? ""
            raw = command.isEmpty ? tool : command
        default:
            raw = tool
        }
        return raw.count > maxTargetLength ? String(raw.prefix(maxTargetLength)) + "…" : raw
    }

    /// Bytes a `tool_result`'s content contributed to the context: a plain string's UTF-8
    /// length, or the summed length of the text blocks in a block array (images carry no
    /// text, so they don't count toward the read weight).
    private static func resultBytes(_ content: Any?) -> Int {
        if let string = content as? String { return string.utf8.count }
        if let blocks = content as? [[String: Any]] {
            return blocks.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }
        }
        return 0
    }

    /// The text of a `tool_result`'s content — a plain string as-is, or the text blocks of a
    /// block array joined — so the spill detector can scan it regardless of content shape.
    private static func resultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// If a `tool_result` is a `<persisted-output>` stub (Claude Code's marker for a result
    /// too large to inline), the absolute path it saved the full output to; else nil. The
    /// stub reads `Full output saved to: <path>` on its own line, so we take up to the
    /// newline and trim.
    private static func persistedOutputPath(_ content: Any?) -> String? {
        let text = resultText(content)
        guard let range = text.range(of: "Full output saved to: ") else { return nil }
        let path = text[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}
