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
}
