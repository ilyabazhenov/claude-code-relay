import XCTest
@testable import Relay

@MainActor
final class RateLimitStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRolloverClosesWindowWithPeakAndHitLimit() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let reset1 = base.addingTimeInterval(3 * 3600)
        let reset2 = base.addingTimeInterval(6 * 3600)   // later reset ⇒ rollover

        // Climb within one window …
        store.ingestStatusline(fiveHourPercent: 40, fiveHourReset: reset1, weeklyPercent: nil, weeklyReset: nil)
        store.ingestStatusline(fiveHourPercent: 60, fiveHourReset: reset1, weeklyPercent: nil, weeklyReset: nil)
        store.ingestStatusline(fiveHourPercent: 99, fiveHourReset: reset1, weeklyPercent: nil, weeklyReset: nil)
        XCTAssertTrue(store.history.windows.isEmpty, "window should stay open until it resets")

        // … then the window resets.
        store.ingestStatusline(fiveHourPercent: 5, fiveHourReset: reset2, weeklyPercent: nil, weeklyReset: nil)

        XCTAssertEqual(store.history.windows.count, 1)
        let window = store.history.windows[0]
        XCTAssertEqual(window.kind, .fiveHour)
        XCTAssertEqual(window.peakFraction, 0.99, accuracy: 0.0001)
        XCTAssertTrue(window.hitLimit)
        XCTAssertEqual(window.startedAt, reset1.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(window.endedAt, reset1)
    }

    func testFractionDropWithoutResetChangeStillRollsOver() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = base.addingTimeInterval(3 * 3600)

        store.ingestStatusline(fiveHourPercent: 70, fiveHourReset: reset, weeklyPercent: nil, weeklyReset: nil)
        // Same reset echoed but fraction collapsed ⇒ treated as a rollover.
        store.ingestStatusline(fiveHourPercent: 4, fiveHourReset: reset, weeklyPercent: nil, weeklyReset: nil)

        XCTAssertEqual(store.history.windows.count, 1)
        XCTAssertEqual(store.history.windows[0].peakFraction, 0.70, accuracy: 0.0001)
        XCTAssertFalse(store.history.windows[0].hitLimit)
    }

    /// Regression: the weekly reset creeps forward a few hours between readings (the proxy
    /// headers encode it as seconds-from-now, so it drifts every ping). That jitter must NOT
    /// be read as a reset — doing so used to spawn overlapping back-dated weekly windows.
    func testWeeklyResetCreepDoesNotRollOver() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let weekReset = base.addingTimeInterval(7 * 24 * 3600)

        store.ingestStatusline(fiveHourPercent: nil, fiveHourReset: nil, weeklyPercent: 20, weeklyReset: weekReset)
        store.ingestStatusline(fiveHourPercent: nil, fiveHourReset: nil, weeklyPercent: 21,
                               weeklyReset: weekReset.addingTimeInterval(3 * 3600))
        store.ingestStatusline(fiveHourPercent: nil, fiveHourReset: nil, weeklyPercent: 22,
                               weeklyReset: weekReset.addingTimeInterval(6 * 3600))

        XCTAssertTrue(store.history.windows.filter { $0.kind == .weekly }.isEmpty,
                      "reset creep must not close (and overlap) the weekly window")
    }

    /// A genuine weekly reset jumps the reset ~7 days forward and collapses usage. It should
    /// close exactly one window that tiles edge-to-edge with the next (no overlap): the
    /// closed window ends where the new one starts.
    func testWeeklyRealResetRollsOverWithoutOverlap() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let week = 7.0 * 24 * 3600
        let weekReset1 = base.addingTimeInterval(2 * 24 * 3600)
        let weekReset2 = weekReset1.addingTimeInterval(week)

        store.ingestStatusline(fiveHourPercent: nil, fiveHourReset: nil, weeklyPercent: 60, weeklyReset: weekReset1)
        store.ingestStatusline(fiveHourPercent: nil, fiveHourReset: nil, weeklyPercent: 3, weeklyReset: weekReset2)

        let weekly = store.history.windows.filter { $0.kind == .weekly }
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly[0].peakFraction, 0.60, accuracy: 0.0001)
        XCTAssertEqual(weekly[0].endedAt, weekReset1)
        XCTAssertEqual(weekly[0].startedAt, weekReset1.addingTimeInterval(-week))
    }

    /// A mid-range wobble in the fraction (noise, or two sources disagreeing) with the reset
    /// time unchanged must NOT close the window — the reset is authoritative, and only a
    /// collapse to near-zero counts as a reset. This used to spuriously roll over.
    func testMidRangeFractionDipWithStableResetDoesNotRollOver() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = base.addingTimeInterval(3 * 3600)

        store.ingestStatusline(fiveHourPercent: 60, fiveHourReset: reset, weeklyPercent: nil, weeklyReset: nil)
        store.ingestStatusline(fiveHourPercent: 28, fiveHourReset: reset, weeklyPercent: nil, weeklyReset: nil)

        XCTAssertTrue(store.history.windows.isEmpty,
                      "a half-drop with an unchanged reset is noise, not a reset")
    }

    func testWeeklyAndFiveHourTrackedIndependently() {
        let dir = tempDir()
        let store = RateLimitStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveReset1 = base.addingTimeInterval(3 * 3600)
        let fiveReset2 = base.addingTimeInterval(6 * 3600)
        let weekReset = base.addingTimeInterval(5 * 24 * 3600)

        store.ingestStatusline(fiveHourPercent: 50, fiveHourReset: fiveReset1, weeklyPercent: 20, weeklyReset: weekReset)
        // Five-hour rolls over; weekly keeps climbing on the same reset.
        store.ingestStatusline(fiveHourPercent: 10, fiveHourReset: fiveReset2, weeklyPercent: 25, weeklyReset: weekReset)

        let fiveWindows = store.history.windows.filter { $0.kind == .fiveHour }
        let weekWindows = store.history.windows.filter { $0.kind == .weekly }
        XCTAssertEqual(fiveWindows.count, 1, "only the 5h window closed")
        XCTAssertTrue(weekWindows.isEmpty, "weekly window is still open")
    }

    // MARK: - Display values

    /// A window whose reset has passed is empty, not unknown: the freshness guard still
    /// reports `nil` (nothing to feed history with), but the display value falls to `0` so
    /// the menu-bar label keeps both of its numbers instead of losing one.
    func testExpiredWindowDisplaysZeroRatherThanNothing() {
        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3 * 24 * 3600)
        let snap = RateLimitSnapshot(fiveHourFraction: 0.28, weeklyFraction: 0.42,
                                     fiveHourResetAt: past, weeklyResetAt: future,
                                     capturedAt: Date().addingTimeInterval(-4 * 3600))

        XCTAssertNil(snap.fiveHourFractionFresh)
        XCTAssertEqual(snap.fiveHourFractionDisplay, 0)
        XCTAssertTrue(snap.fiveHourRolledOver)

        XCTAssertEqual(snap.weeklyFractionDisplay ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertFalse(snap.weeklyRolledOver)
    }

    /// A window we have never had a reading for stays absent — there is nothing to be
    /// empty, and inventing a `0%` for it would be a made-up number.
    func testNeverSeenWindowHasNoDisplayValue() {
        let snap = RateLimitSnapshot(fiveHourFraction: nil, weeklyFraction: 0.42,
                                     fiveHourResetAt: nil,
                                     weeklyResetAt: Date().addingTimeInterval(3 * 24 * 3600),
                                     capturedAt: Date())

        XCTAssertNil(snap.fiveHourFractionDisplay)
        XCTAssertFalse(snap.fiveHourRolledOver)
        XCTAssertEqual(snap.weeklyFractionDisplay ?? -1, 0.42, accuracy: 0.0001)
    }

    // MARK: - Fable's separate weekly window

    /// `7d_oi` is Fable's own weekly allowance, and it arrives only on a Fable response.
    func testFableWeeklyParsedFromHeaders() {
        let store = RateLimitStore(directory: tempDir())
        let reset = String(Int(Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970))

        store.ingestHeaders([
            "anthropic-ratelimit-unified-5h-utilization": "0.08",
            "anthropic-ratelimit-unified-5h-reset": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            "anthropic-ratelimit-unified-7d-utilization": "0.49",
            "anthropic-ratelimit-unified-7d-reset": reset,
            "anthropic-ratelimit-unified-7d_oi-utilization": "0.64",
            "anthropic-ratelimit-unified-7d_oi-reset": reset
        ])

        XCTAssertEqual(store.snapshot?.fableWeeklyPercent, 64)
        XCTAssertEqual(store.snapshot?.weeklyPercent, 49)
    }

    /// The `7d` prefix is a prefix of `7d_oi`. Parsing must not confuse the two, or the
    /// overall weekly window would pick up Fable's number (or vice versa).
    func testPlainWeeklyIsNotConfusedWithFableWindow() {
        let store = RateLimitStore(directory: tempDir())
        store.ingestHeaders([
            "anthropic-ratelimit-unified-7d-utilization": "0.49",
            "anthropic-ratelimit-unified-7d_oi-utilization": "0.64"
        ])

        XCTAssertEqual(store.snapshot?.weeklyPercent, 49)
        XCTAssertEqual(store.snapshot?.fableWeeklyPercent, 64)
    }

    /// Haiku pings carry no `7d_oi` header at all. Those far more frequent ingests must
    /// leave the last Fable reading alone rather than blanking it between Fable pings.
    func testHaikuPingKeepsLastFableReading() {
        let store = RateLimitStore(directory: tempDir())
        let reset = String(Int(Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970))

        store.ingestHeaders([
            "anthropic-ratelimit-unified-7d-utilization": "0.49",
            "anthropic-ratelimit-unified-7d-reset": reset,
            "anthropic-ratelimit-unified-7d_oi-utilization": "0.64",
            "anthropic-ratelimit-unified-7d_oi-reset": reset
        ])
        // …a later Haiku ping: same two windows, no Fable header.
        store.ingestHeaders([
            "anthropic-ratelimit-unified-7d-utilization": "0.51",
            "anthropic-ratelimit-unified-7d-reset": reset
        ])

        XCTAssertEqual(store.snapshot?.weeklyPercent, 51, "the overall window moved")
        XCTAssertEqual(store.snapshot?.fableWeeklyPercent, 64, "Fable's held its last reading")
    }

    /// The menu bar has room for one weekly number, so it shows whichever window binds.
    func testMenuBarWeeklyUsesTheFullerWindow() {
        let future = Date().addingTimeInterval(3 * 24 * 3600)
        let snap = RateLimitSnapshot(weeklyFraction: 0.49, fableWeeklyFraction: 0.64,
                                     weeklyResetAt: future, fableWeeklyResetAt: future,
                                     capturedAt: Date())
        XCTAssertEqual(snap.weeklyBindingFractionDisplay ?? -1, 0.64, accuracy: 0.0001)

        // …and the other way round, when the overall allowance is the tighter one.
        let flipped = RateLimitSnapshot(weeklyFraction: 0.80, fableWeeklyFraction: 0.30,
                                        weeklyResetAt: future, fableWeeklyResetAt: future,
                                        capturedAt: Date())
        XCTAssertEqual(flipped.weeklyBindingFractionDisplay ?? -1, 0.80, accuracy: 0.0001)
    }

    /// On a plan without a separate Fable allowance the binding value is just the weekly one
    /// — the menu bar must not lose its number for everyone who never sees `7d_oi`.
    func testMenuBarWeeklyWorksWithoutAFableWindow() {
        let snap = RateLimitSnapshot(weeklyFraction: 0.42,
                                     weeklyResetAt: Date().addingTimeInterval(3 * 24 * 3600),
                                     capturedAt: Date())
        XCTAssertEqual(snap.weeklyBindingFractionDisplay ?? -1, 0.42, accuracy: 0.0001)
    }

    /// A reading with no reset time at all can't expire, so it displays as-is.
    func testReadingWithoutResetDisplaysItsValue() {
        let snap = RateLimitSnapshot(fiveHourFraction: 0.5, weeklyFraction: nil,
                                     fiveHourResetAt: nil, weeklyResetAt: nil,
                                     capturedAt: Date())

        XCTAssertEqual(snap.fiveHourFractionDisplay ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertFalse(snap.fiveHourRolledOver)
    }
}
