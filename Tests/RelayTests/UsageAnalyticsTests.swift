import XCTest
@testable import Relay

final class UsageAnalyticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ minutes: Double, five: Double? = nil, weekly: Double? = nil) -> UsageSample {
        UsageSample(at: t0.addingTimeInterval(minutes * 60), fiveHour: five, weekly: weekly)
    }

    // MARK: Projection

    func testProjectionExtrapolatesSteadyRise() {
        // 0→30 min climbing 40%→70% (1% per minute) → 100% at ~60 min.
        let samples = (0...6).map { i in sample(Double(i) * 5, five: 0.40 + Double(i) * 0.05) }
        let now = t0.addingTimeInterval(30 * 60)
        let reset = t0.addingTimeInterval(3 * 3600)
        let eta = UsageAnalytics.projectedExhaustion(samples: samples, kind: .fiveHour, reset: reset, now: now)
        let unwrapped = try? XCTUnwrap(eta)
        XCTAssertNotNil(unwrapped)
        if let eta {
            // 40% at t=0, +1%/min ⇒ 100% at 60 min.
            XCTAssertEqual(eta.timeIntervalSince(t0), 60 * 60, accuracy: 120)
        }
    }

    func testNoProjectionWhenFlat() {
        let samples = (0...6).map { i in sample(Double(i) * 5, five: 0.50) }
        let now = t0.addingTimeInterval(30 * 60)
        let eta = UsageAnalytics.projectedExhaustion(samples: samples, kind: .fiveHour,
                                                     reset: t0.addingTimeInterval(3 * 3600), now: now)
        XCTAssertNil(eta)
    }

    func testNoProjectionWhenResetPreemptsExhaustion() {
        // Gentle rise: would hit 100% far in the future, but the window resets in 20 min.
        let samples = (0...6).map { i in sample(Double(i) * 5, five: 0.40 + Double(i) * 0.005) }
        let now = t0.addingTimeInterval(30 * 60)
        let reset = t0.addingTimeInterval(30 * 60 + 20 * 60)
        let eta = UsageAnalytics.projectedExhaustion(samples: samples, kind: .fiveHour, reset: reset, now: now)
        XCTAssertNil(eta)
    }

    func testAlreadyAtCapProjectsNow() {
        let samples = (0...3).map { i in sample(Double(i) * 5, five: 1.0) }
        let now = t0.addingTimeInterval(20 * 60)
        let eta = UsageAnalytics.projectedExhaustion(samples: samples, kind: .fiveHour, reset: nil, now: now)
        XCTAssertEqual(eta, now)
    }
}
