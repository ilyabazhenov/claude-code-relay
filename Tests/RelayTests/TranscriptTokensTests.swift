import XCTest
@testable import Relay

final class TranscriptTokensTests: XCTestCase {
    private func writeTemp(_ text: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func assistantLine(model: String, output: Int, ts: String = "2026-07-12T10:00:00.000Z") -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"\(model)","usage":{"input_tokens":100,"output_tokens":\(output),"cache_creation_input_tokens":10,"cache_read_input_tokens":1000}}}
        """
    }

    func testParsesAssistantUsageAndSkipsOthers() {
        let text = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            assistantLine(model: "claude-opus-4-8", output: 200),
            #"{"type":"system","subtype":"x"}"#,
            assistantLine(model: "claude-haiku-4-5-20251001", output: 50)
        ].joined(separator: "\n") + "\n"
        let path = writeTemp(text)

        let result = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.records.count, 2)
        XCTAssertEqual(result?.records[0].model, "claude-opus-4-8")
        XCTAssertEqual(result?.records[0].output, 200)
        XCTAssertEqual(result?.records[0].total, 100 + 200 + 10 + 1000)
        XCTAssertEqual(result?.records[1].model, "claude-haiku-4-5-20251001")
    }

    func testCursorAdvancesAndAvoidsRecount() {
        let first = assistantLine(model: "claude-opus-4-8", output: 200) + "\n"
        let path = writeTemp(first)
        let r1 = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(r1?.records.count, 1)
        let offset = r1!.newOffset

        // Re-parsing from the saved offset with no new content yields nothing.
        let r2 = TranscriptTokens.parse(path: path, fromOffset: offset)
        XCTAssertEqual(r2?.records.count, 0)
        XCTAssertEqual(r2?.newOffset, offset)

        // Append another turn; only the new one is returned.
        let appended = first + assistantLine(model: "claude-haiku-4-5", output: 30) + "\n"
        try? appended.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        let r3 = TranscriptTokens.parse(path: path, fromOffset: offset)
        XCTAssertEqual(r3?.records.count, 1)
        XCTAssertEqual(r3?.records.first?.model, "claude-haiku-4-5")
    }

    func testPartialTrailingLineIsNotConsumed() {
        // A complete line followed by a half-flushed line (no trailing newline).
        let text = assistantLine(model: "claude-opus-4-8", output: 200) + "\n" + #"{"type":"assist"#
        let path = writeTemp(text)
        let result = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(result?.records.count, 1)
        // Offset stops at the last newline, so the partial line is re-read next time.
        let full = (try? Data(contentsOf: URL(fileURLWithPath: path)))?.count ?? 0
        XCTAssertLessThan(Int(result!.newOffset), full)
    }

    func testTokensByModelAggregatesAndSorts() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            TokenRecord(at: base, model: "claude-opus-4-8", input: 100, output: 100, cacheCreation: 0, cacheRead: 0),
            TokenRecord(at: base.addingTimeInterval(60), model: "claude-haiku-4-5", input: 10, output: 10, cacheCreation: 0, cacheRead: 0),
            TokenRecord(at: base.addingTimeInterval(120), model: "claude-opus-4-8", input: 50, output: 50, cacheCreation: 0, cacheRead: 0),
            TokenRecord(at: base.addingTimeInterval(-600), model: "claude-opus-4-8", input: 999, output: 999, cacheCreation: 0, cacheRead: 0)
        ]
        let rows = TokenUsageStore.tokensByModel(records, since: base)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "claude-opus-4-8")   // 300 total, largest first
        XCTAssertEqual(rows[0].total, 300)
        XCTAssertEqual(rows[1].total, 20)                  // pre-`since` record excluded
    }

    func testTokensByProjectAggregatesAndSorts() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            TokenRecord(at: base, model: "claude-opus-4-8", input: 100, output: 100, cacheCreation: 0, cacheRead: 0, project: "relay"),
            TokenRecord(at: base.addingTimeInterval(60), model: "claude-sonnet-5", input: 20, output: 20, cacheCreation: 0, cacheRead: 0, project: "relay"),
            TokenRecord(at: base.addingTimeInterval(120), model: "claude-haiku-4-5", input: 5, output: 5, cacheCreation: 0, cacheRead: 0, project: "docs"),
            TokenRecord(at: base.addingTimeInterval(-600), model: "claude-opus-4-8", input: 999, output: 999, cacheCreation: 0, cacheRead: 0, project: "relay")
        ]
        let rows = TokenUsageStore.tokensByProject(records, since: base)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].project, "relay")           // 240 total, largest first
        XCTAssertEqual(rows[0].total, 240)                 // pre-`since` record excluded
        XCTAssertEqual(rows[1].project, "docs")
        XCTAssertEqual(rows[1].total, 10)
    }

    func testTokensByProjectBucketsUntaggedRecords() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            TokenRecord(at: base, model: "claude-opus-4-8", input: 50, output: 50, cacheCreation: 0, cacheRead: 0),
            TokenRecord(at: base.addingTimeInterval(60), model: "claude-opus-4-8", input: 10, output: 10, cacheCreation: 0, cacheRead: 0, project: "relay")
        ]
        let rows = TokenUsageStore.tokensByProject(records, since: base)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].project, TokenUsageStore.unknownProject) // untagged folds into the placeholder bucket
        XCTAssertEqual(rows[0].total, 100)
    }

    // MARK: - Project health

    /// Build `count` records for `project`, each with a fixed `cacheRead`, one minute apart.
    private func turns(_ project: String, cacheRead: Int, count: Int, from base: Date) -> [TokenRecord] {
        (0..<count).map { i in
            TokenRecord(at: base.addingTimeInterval(Double(i) * 60), model: "claude-opus-4-8",
                        input: 100, output: 200, cacheCreation: 0, cacheRead: cacheRead, project: project)
        }
    }

    func testHealthOkForLightProject() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns("relay", cacheRead: 5_000, count: 8, from: base)
        let v = TokenUsageStore.projectVitals(records, since: base)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].health, .ok)
        XCTAssertEqual(v[0].avgCacheRead, 5_000)
    }

    func testHealthCriticalOnAbsoluteFloor() {
        // Flat but objectively heavy — no trend, tripped by the absolute cache-read floor.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns("relay", cacheRead: 190_000, count: 5, from: base)
        let v = TokenUsageStore.projectVitals(records, since: base)
        XCTAssertEqual(v[0].health, .critical)
    }

    func testHealthWarnOnRisingTrend() {
        // Below the absolute warn floor throughout, but the recent turns run well above the
        // project's own early baseline — flagged by the deviation signal.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let low = turns("relay", cacheRead: 50_000, count: 3, from: base)
        let high = turns("relay", cacheRead: 95_000, count: 3, from: base.addingTimeInterval(3 * 60))
        let v = TokenUsageStore.projectVitals(low + high, since: base)
        XCTAssertEqual(v[0].health, .warn)
        XCTAssertNotNil(v[0].trend)
    }

    func testHealthOkBelowMinTurns() {
        // Heavy, but too few turns to trust — stays silent rather than flag noise.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns("relay", cacheRead: 200_000, count: 2, from: base)
        let v = TokenUsageStore.projectVitals(records, since: base)
        XCTAssertEqual(v[0].health, .ok)
    }

    func testHealthExcludesUntaggedBucket() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let untagged = (0..<6).map { i in
            TokenRecord(at: base.addingTimeInterval(Double(i) * 60), model: "claude-opus-4-8",
                        input: 100, output: 200, cacheCreation: 0, cacheRead: 200_000)
        }
        let v = TokenUsageStore.projectVitals(untagged, since: base)
        XCTAssertTrue(v.isEmpty) // the mixed "unknown" bucket is never health-scored
    }

    func testHealthSortsWorstFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns("calm", cacheRead: 3_000, count: 6, from: base)
            + turns("hot", cacheRead: 190_000, count: 6, from: base)
        let v = TokenUsageStore.projectVitals(records, since: base)
        XCTAssertEqual(v.first?.project, "hot")
        XCTAssertEqual(v.first?.health, .critical)
    }

    // MARK: - Tool events (culprits)

    private func toolUseLine(id: String, name: String, inputJSON: String) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-12T10:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"\(id)","name":"\(name)","input":\(inputJSON)}]}}
        """
    }

    func testParsesToolEventsStitchedByID() {
        let use = toolUseLine(id: "toolu_1", name: "Read", inputJSON: #"{"file_path":"/repo/big.json"}"#)
        // content string is exactly 10 bytes.
        let result = #"{"type":"user","timestamp":"2026-07-12T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"HELLOHELLO"}]}}"#
        let path = writeTemp(use + "\n" + result + "\n")

        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(parsed?.records.count, 1)               // the assistant turn's usage
        XCTAssertEqual(parsed?.toolEvents.count, 1)
        XCTAssertEqual(parsed?.toolEvents.first?.tool, "Read")
        XCTAssertEqual(parsed?.toolEvents.first?.target, "/repo/big.json")
        XCTAssertEqual(parsed?.toolEvents.first?.bytes, 10)
    }

    func testToolResultBlockArraySumsTextBytesOnly() {
        let use = toolUseLine(id: "toolu_2", name: "Bash", inputJSON: #"{"command":"npm test"}"#)
        // 5 bytes of text plus an image block that carries no text weight.
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"ABCDE"},{"type":"image"}]}]}}"#
        let path = writeTemp(use + "\n" + result + "\n")

        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(parsed?.toolEvents.first?.tool, "Bash")
        XCTAssertEqual(parsed?.toolEvents.first?.target, "npm test")   // command is the target
        XCTAssertEqual(parsed?.toolEvents.first?.bytes, 5)
    }

    func testToolResultWithoutMatchingUseIsSkipped() {
        let orphan = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"missing","content":"data"}]}}"#
        let path = writeTemp(orphan + "\n")
        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(parsed?.toolEvents.count, 0)
    }

    func testTopCulpritsFoldsRepeatsSortsAndFilters() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            ToolEvent(at: base, tool: "Read", target: "/a/big.json", bytes: 300_000, project: "relay"),
            ToolEvent(at: base.addingTimeInterval(60), tool: "Read", target: "/a/big.json", bytes: 300_000, project: "relay"),
            ToolEvent(at: base.addingTimeInterval(120), tool: "Bash", target: "npm test", bytes: 100_000, project: "relay"),
            ToolEvent(at: base.addingTimeInterval(180), tool: "Read", target: "/a/big.json", bytes: 500_000, project: "docs"),
            ToolEvent(at: base.addingTimeInterval(-600), tool: "Read", target: "/a/old.json", bytes: 999_999, project: "relay")
        ]
        let culprits = TokenUsageStore.topCulprits(events, records: [], project: "relay", since: base)
        XCTAssertEqual(culprits.count, 2)                       // docs excluded; pre-since excluded
        XCTAssertEqual(culprits[0].target, "/a/big.json")       // 600K total, dearest first
        XCTAssertEqual(culprits[0].bytes, 600_000)
        XCTAssertEqual(culprits[0].count, 2)                    // two reads folded
        XCTAssertEqual(culprits[1].target, "npm test")
        XCTAssertFalse(culprits.contains { $0.target == "/a/old.json" })
    }

    // MARK: - Culprit pricing (tokens × turns resident)

    /// Turn records for one session, `count` of them a minute apart, each holding a context
    /// of `cacheRead` — enough for the pricing pass to count residence and spot resets.
    private func turns(session: String, project: String = "relay", from: Date, count: Int,
                       cacheRead: Int = 100_000) -> [TokenRecord] {
        (0..<count).map { i in
            TokenRecord(at: from.addingTimeInterval(Double(i) * 60), model: "opus",
                        input: 0, output: 0, cacheCreation: 0, cacheRead: cacheRead,
                        project: project, session: session)
        }
    }

    func testCostRanksSmallEarlyReadOverBigLateOne() {
        // The finding that motivated pricing: a modest file read at the start of a long
        // session outweighs a far bigger one read at the end, because it is re-read all the
        // way through. Ranking by bytes puts these in exactly the wrong order.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns(session: "s1", from: base, count: 100)
        let events = [
            ToolEvent(at: base.addingTimeInterval(60), tool: "Read", target: "/small-early.swift",
                      bytes: 12_000, project: "relay", session: "s1"),
            ToolEvent(at: base.addingTimeInterval(98 * 60), tool: "Read", target: "/big-late.swift",
                      bytes: 50_000, project: "relay", session: "s1")
        ]
        let culprits = TokenUsageStore.topCulprits(events, records: records, project: "relay", since: base)
        XCTAssertEqual(culprits[0].target, "/small-early.swift")     // dearest despite being 4× smaller
        XCTAssertEqual(culprits[0].turns, 98)                        // resident to the end
        XCTAssertEqual(culprits[0].cost, 3_000 * 98)
        XCTAssertEqual(culprits[1].target, "/big-late.swift")
        XCTAssertEqual(culprits[1].turns, 1)                         // one turn left to pay for
        XCTAssertLessThan(culprits[1].cost, culprits[0].cost)
    }

    func testCostStopsAtContextReset() {
        // A compaction evicts everything read before it, so the charge stops there rather
        // than running to the end of the session.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Ten full turns, then the context collapses — a compaction — and ten small ones.
        let before = turns(session: "s1", from: base, count: 10, cacheRead: 150_000)
        let after = turns(session: "s1", from: base.addingTimeInterval(10 * 60), count: 10, cacheRead: 20_000)
        let events = [ToolEvent(at: base, tool: "Read", target: "/f.swift",
                                bytes: 40_000, project: "relay", session: "s1")]
        let culprits = TokenUsageStore.topCulprits(events, records: before + after,
                                                   project: "relay", since: base)
        XCTAssertEqual(culprits[0].turns, 9)                         // the 9 later turns before the reset
        XCTAssertEqual(culprits[0].cost, 10_000 * 9)
    }

    func testCostCountsOnlyItsOwnSessionsTurns() {
        // Two sessions running side by side in one project: a read in one must not be
        // charged for turns taken in the other.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns(session: "s1", from: base, count: 5) + turns(session: "s2", from: base, count: 50)
        let events = [ToolEvent(at: base, tool: "Read", target: "/f.swift",
                                bytes: 40_000, project: "relay", session: "s1")]
        let culprits = TokenUsageStore.topCulprits(events, records: records, project: "relay", since: base)
        XCTAssertEqual(culprits[0].turns, 4)                         // s1's later turns only, not s2's 50
    }

    func testUntaggedEventIsChargedOnce() {
        // Events written before session tagging can't be priced — they fall back to a single
        // charge, which ranks them by size as before until they age out.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = turns(session: "s1", from: base, count: 100)
        let events = [ToolEvent(at: base, tool: "Read", target: "/legacy.swift",
                                bytes: 40_000, project: "relay", session: nil)]
        let culprits = TokenUsageStore.topCulprits(events, records: records, project: "relay", since: base)
        XCTAssertEqual(culprits[0].turns, 1)
        XCTAssertEqual(culprits[0].cost, 10_000)
    }

    // MARK: - Spill files (persisted tool output)

    func testSpillReadsCreditedToOriginWithinOnePass() {
        // A `git diff` whose output was too large: Claude Code persists it and leaves a
        // `<persisted-output>` stub, then reads the spill file back in.
        let spill = "/proj/tool-results/bvfozlfxs.txt"
        let bashUse = toolUseLine(id: "toolu_a", name: "Bash", inputJSON: #"{"command":"git diff"}"#)
        let bashResult = #"{"type":"user","timestamp":"2026-07-12T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"<persisted-output>\nOutput too large. Full output saved to: /proj/tool-results/bvfozlfxs.txt\n\nPreview: diff --git"}]}}"#
        let readUse = toolUseLine(id: "toolu_b", name: "Read", inputJSON: #"{"file_path":"/proj/tool-results/bvfozlfxs.txt"}"#)
        let readResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_b","content":"AAAAAAAAAA"}]}}"#
        let path = writeTemp([bashUse, bashResult, readUse, readResult].joined(separator: "\n") + "\n")

        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(parsed?.toolEvents.count, 2)
        // Both the stub call and the read fold onto the origin command, not the spill path.
        XCTAssertTrue(parsed!.toolEvents.allSatisfy { $0.tool == "Bash" && $0.target == "git diff" })
        XCTAssertEqual(parsed?.spills[spill]?.target, "git diff")

        // Tagged and aggregated, they collapse into a single culprit row.
        let tagged = parsed!.toolEvents.map { e -> ToolEvent in var c = e; c.project = "p"; return c }
        let culprits = TokenUsageStore.topCulprits(tagged, records: [], project: "p",
                                                   since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(culprits.count, 1)
        XCTAssertEqual(culprits[0].target, "git diff")
        XCTAssertEqual(culprits[0].count, 2)
    }

    func testSpillReadCreditedAcrossChunksViaKnownSpills() {
        // The spilling call happened in an earlier ingest; only the read is in this chunk.
        let spill = "/proj/tool-results/x.txt"
        let known = [spill: SpillOrigin(tool: "Bash", target: "git diff",
                                        at: Date(timeIntervalSince1970: 1_700_000_000))]
        let readUse = toolUseLine(id: "toolu_c", name: "Read", inputJSON: #"{"file_path":"/proj/tool-results/x.txt"}"#)
        let readResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_c","content":"DATA"}]}}"#
        let path = writeTemp(readUse + "\n" + readResult + "\n")

        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0, knownSpills: known)
        XCTAssertEqual(parsed?.toolEvents.first?.tool, "Bash")
        XCTAssertEqual(parsed?.toolEvents.first?.target, "git diff")
        XCTAssertEqual(parsed?.spills[spill]?.target, "git diff")   // carried forward for next time
    }

    func testNonSpillReadKeepsItsOwnTarget() {
        // A normal read of a file that was never spilled is unaffected.
        let readUse = toolUseLine(id: "toolu_d", name: "Read", inputJSON: #"{"file_path":"/repo/normal.txt"}"#)
        let readResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d","content":"HELLO"}]}}"#
        let path = writeTemp(readUse + "\n" + readResult + "\n")

        let parsed = TranscriptTokens.parse(path: path, fromOffset: 0)
        XCTAssertEqual(parsed?.toolEvents.first?.target, "/repo/normal.txt")
        XCTAssertTrue(parsed!.spills.isEmpty)
    }

    func testTopCulpritsRespectsLimit() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<8).map { i in
            ToolEvent(at: base.addingTimeInterval(Double(i)), tool: "Read",
                      target: "/f\(i)", bytes: 10_000 * (i + 1), project: "relay")
        }
        let culprits = TokenUsageStore.topCulprits(events, records: [], project: "relay",
                                                   since: base, limit: 3)
        XCTAssertEqual(culprits.count, 3)
        XCTAssertEqual(culprits[0].target, "/f7")               // dearest first
    }

    // MARK: - Reset

    /// A store rooted in a throwaway directory, seeded with one turn per project so the
    /// reset paths can be exercised against real persistence.
    @MainActor private func seededStore(projects: [String?]) -> TokenUsageStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString)", isDirectory: true)
        let store = TokenUsageStore(directory: directory)
        let base = Date()
        store.add(projects.enumerated().map { i, project in
            TokenRecord(at: base.addingTimeInterval(Double(i)), model: "claude-opus-4-8",
                        input: 10, output: 10, cacheCreation: 0, cacheRead: 0, project: project)
        })
        store.addToolEvents(projects.enumerated().map { i, project in
            ToolEvent(at: base.addingTimeInterval(Double(i)), tool: "Read",
                      target: "/f\(i)", bytes: 50_000, project: project)
        })
        return store
    }

    @MainActor func testResetAllClearsRecordsAndToolEvents() {
        let store = seededStore(projects: ["relay", "docs"])
        store.resetAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.toolEvents.isEmpty)
    }

    @MainActor func testResetAllSurvivesReload() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString)", isDirectory: true)
        let store = TokenUsageStore(directory: directory)
        store.add([TokenRecord(at: Date(), model: "claude-opus-4-8", input: 10, output: 10,
                               cacheCreation: 0, cacheRead: 0, project: "relay")])
        store.resetAll()
        // The cleared state has to be written through, or the next launch resurrects it.
        XCTAssertTrue(TokenUsageStore(directory: directory).records.isEmpty)
    }

    @MainActor func testResetProjectLeavesOtherProjectsIntact() {
        let store = seededStore(projects: ["relay", "docs"])
        store.reset(project: "relay")
        XCTAssertEqual(store.records.map(\.project), ["docs"])
        XCTAssertEqual(store.toolEvents.map(\.project), ["docs"])
    }

    @MainActor func testResetProjectClearsUntaggedBucket() {
        let store = seededStore(projects: [nil, "relay"])
        store.reset(project: TokenUsageStore.unknownProject)
        XCTAssertEqual(store.records.map(\.project), ["relay"])
        XCTAssertEqual(store.toolEvents.map(\.project), ["relay"])
    }
}
