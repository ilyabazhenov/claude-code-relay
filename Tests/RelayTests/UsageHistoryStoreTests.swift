import XCTest
@testable import Relay

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func window(_ kind: UsageWindowKind, start: Double, span: Double, peak: Double) -> UsageWindow {
        UsageWindow(kind: kind, startedAt: at(start), endedAt: at(start + span),
                    peakFraction: peak, hitLimit: peak >= UsageHistoryStore.hitLimitThreshold)
    }

    /// Two 5-hour windows overlapping → the higher-peak one survives, the other is dropped.
    func testSanitizedDropsOverlapKeepingHigherPeak() {
        let input = [
            window(.fiveHour, start: 0, span: 5, peak: 0.41),   // 0–5
            window(.fiveHour, start: 1.4, span: 5, peak: 0.21), // 1.4–6.4, overlaps
            window(.fiveHour, start: 6.4, span: 5, peak: 0.00), // 6.4–11.4, tiles with #2
        ]
        let out = UsageHistoryStore.sanitized(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0.peakFraction }, [0.41, 0.00])
        // No remaining overlap.
        XCTAssertLessThanOrEqual(out[0].endedAt, out[1].startedAt)
    }

    /// Legitimate gaps between non-overlapping windows are preserved.
    func testSanitizedPreservesGaps() {
        let input = [
            window(.fiveHour, start: 0, span: 5, peak: 0.3),
            window(.fiveHour, start: 6, span: 5, peak: 0.5),   // 1h gap after the first
        ]
        let out = UsageHistoryStore.sanitized(input)
        XCTAssertEqual(out.count, 2)
    }

    /// Overlap resolution is per-kind: a weekly window overlapping in wall-clock time with a
    /// 5-hour one is not a conflict.
    func testSanitizedIsPerKind() {
        let input = [
            window(.fiveHour, start: 0, span: 5, peak: 0.4),
            window(.weekly, start: 0, span: 168, peak: 0.2),   // same start, different kind
        ]
        let out = UsageHistoryStore.sanitized(input)
        XCTAssertEqual(out.count, 2)
    }

    /// `sanitized` walks the kinds and keeps only what it walked, so a kind it doesn't know
    /// about is silently erased on load. It must cover every case — this fails the moment a
    /// new window kind is added without being included.
    func testSanitizedCoversEveryWindowKind() {
        let input = UsageWindowKind.allCases.enumerated().map { index, kind in
            window(kind, start: Double(index) * 200, span: 5, peak: 0.3)
        }
        let out = UsageHistoryStore.sanitized(input)
        XCTAssertEqual(Set(out.map { $0.kind.rawValue }),
                       Set(UsageWindowKind.allCases.map { $0.rawValue }),
                       "a window kind was dropped by sanitize — its history would vanish on load")
    }

    /// Fable's weekly window overlaps the overall weekly one by definition: they run over the
    /// same days. That must not be read as corruption and collapsed into one.
    func testFableWeeklyCoexistsWithTheOverallWeeklyWindow() {
        let input = [
            window(.weekly, start: 0, span: 168, peak: 0.49),
            window(.fableWeekly, start: 0, span: 168, peak: 0.64),
        ]
        let out = UsageHistoryStore.sanitized(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map { $0.peakFraction }), [0.49, 0.64])
    }

    /// Samples written before Fable was tracked have no such field. They must still decode
    /// rather than taking the whole persisted series down with them.
    func testLegacySampleWithoutFableFieldStillDecodes() throws {
        let json = Data(#"[{"at":694224000,"fiveHour":0.28,"weekly":0.42}]"#.utf8)
        let decoded = try JSONDecoder().decode([UsageSample].self, from: json)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].fiveHour, 0.28)
        XCTAssertNil(decoded[0].fableWeekly)
    }

    /// A Fable reading moving on its own is enough to record a sample, even when the other
    /// two windows sat still — it refreshes on a slower cadence and would otherwise be
    /// throttled away between the frequent Haiku ingests.
    func testFableMovementAloneRecordsASample() {
        let store = UsageHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-test-\(UUID().uuidString)", isDirectory: true))

        XCTAssertTrue(store.recordSample(fiveHour: 0.10, weekly: 0.49, fableWeekly: 0.64, at: at(0)))
        // One minute later — inside the throttle window, and only Fable moved.
        let recorded = store.recordSample(fiveHour: 0.10, weekly: 0.49, fableWeekly: 0.70,
                                          at: at(0).addingTimeInterval(60))
        XCTAssertTrue(recorded, "a Fable-only move should still be captured")
        XCTAssertEqual(store.samples.last?.fableWeekly, 0.70)
    }
}
