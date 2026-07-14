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

    /// All tokens the message processed. Cache reads dominate for long contexts, so the
    /// UI leans on this as "throughput" rather than a billing figure.
    var total: Int { input + output + cacheCreation + cacheRead }
}

/// Accumulates per-message token records parsed from session transcripts, so the history
/// UI can show a precise "tokens by model" breakdown. Fed on each `Stop` hook; a per-
/// session byte cursor means each transcript is only ever read forward from where we
/// left off (transcripts are append-only), so nothing is counted twice.
@MainActor
final class TokenUsageStore: ObservableObject {
    @Published private(set) var records: [TokenRecord] = []

    /// Per-session byte offset into the transcript we've already consumed.
    private var cursors: [String: UInt64] = [:]

    private static let recordMaxAge: TimeInterval = 14 * 24 * 3600

    private let directory: URL
    private var recordsURL: URL { directory.appendingPathComponent("token-records.json", isDirectory: false) }
    private var cursorsURL: URL { directory.appendingPathComponent("token-cursors.json", isDirectory: false) }

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
    }

    // MARK: Ingest

    /// Parse any new assistant messages appended to `transcriptPath` since we last read it
    /// for this session, and fold their token usage into the record series.
    func ingest(sessionId: String, transcriptPath: String?) {
        guard let path = transcriptPath, !path.isEmpty else { return }
        let parsed = TranscriptTokens.parse(path: path, fromOffset: cursors[sessionId] ?? 0)
        guard let parsed else { return }
        cursors[sessionId] = parsed.newOffset
        persistCursors()
        guard !parsed.records.isEmpty else { return }
        add(parsed.records)
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

    // MARK: Persistence (best-effort)

    private func persistRecords() { write(records, to: recordsURL) }
    private func persistCursors() { write(cursors, to: cursorsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Pure transcript reader: pulls token records out of the newly-appended tail of a
/// JSONL transcript. Kept free of actor isolation and app state so it's easy to test.
enum TranscriptTokens {
    struct Result {
        let records: [TokenRecord]
        /// Byte offset to resume from next time — advanced only past complete lines, so a
        /// half-flushed final line is re-read (not skipped) on the next call.
        let newOffset: UInt64
    }

    static func parse(path: String, fromOffset: UInt64) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // A shrunken file means it rotated/compacted — start over rather than trust a stale
        // offset that now points into the middle of a different line.
        var start = fromOffset
        if start > size { start = 0 }
        guard start < size else { return Result(records: [], newOffset: size) }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return Result(records: [], newOffset: size)
        }

        // Only consume up to the last newline; leave any trailing partial line for later.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Result(records: [], newOffset: start)
        }
        let consumed = data[data.startIndex...lastNewline]
        let newOffset = start + UInt64(consumed.count)

        // Build the ISO parsers once per call (they aren't Sendable, so no shared statics).
        let isoFractional = ISO8601DateFormatter(); isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let timestamp: (String) -> Date? = { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) }

        var records: [TokenRecord] = []
        for line in consumed.split(separator: 0x0A) where !line.isEmpty {
            if let record = record(from: Data(line), timestamp: timestamp) { records.append(record) }
        }
        return Result(records: records, newOffset: newOffset)
    }

    private static func record(from line: Data, timestamp: (String) -> Date?) -> TokenRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any] else { return nil }

        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let at = (object["timestamp"] as? String).flatMap(timestamp) ?? Date()

        return TokenRecord(
            at: at,
            model: model,
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )
    }
}
