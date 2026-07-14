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
}
