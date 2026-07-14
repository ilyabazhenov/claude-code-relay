import Foundation

/// Pure derivations over the usage history. Everything here is a static function of its
/// inputs (the caller passes `now`), so the logic — projection, patterns — is unit
/// testable without a clock or the filesystem.
enum UsageAnalytics {
    /// Only samples within this recent span feed the projection slope; older points
    /// describe a part of the window that no longer reflects the current pace.
    static let projectionLookback: TimeInterval = 30 * 60
    /// Ignore slopes gentler than this (fraction per hour) — below it we'd be
    /// extrapolating noise into a scary ETA.
    static let minProjectionSlopePerHour = 0.02
    /// Require at least this goodness-of-fit before trusting the trend.
    static let minProjectionFit = 0.5

    // MARK: Projection

    /// Project when `kind`'s window will reach 100%, from the slope of recent samples.
    ///
    /// Returns `nil` unless usage is rising steadily (positive slope above the noise
    /// floor, with a decent fit) **and** the projected moment lands before the window
    /// resets — there's no point warning about an exhaustion the reset will pre-empt.
    static func projectedExhaustion(samples: [UsageSample], kind: UsageWindowKind,
                                    reset: Date?, now: Date) -> Date? {
        let cutoff = now.addingTimeInterval(-projectionLookback)
        let recent: [(x: Double, y: Double)] = samples.compactMap { sample in
            guard sample.at >= cutoff, let y = fraction(sample, kind) else { return nil }
            return (x: sample.at.timeIntervalSince1970, y: y)
        }
        guard recent.count >= 3, let last = recent.last, last.y < 1 else {
            // Already at the cap counts as "exhausted now".
            if let last = recent.last, last.y >= 1 { return now }
            return nil
        }

        // Fit against seconds-since-first-sample to keep the numbers well-conditioned.
        let x0 = recent[0].x
        guard let fit = linearFit(recent.map { (x: $0.x - x0, y: $0.y) }) else { return nil }
        guard fit.slope > 0, fit.rSquared >= minProjectionFit else { return nil }
        guard fit.slope * 3600 >= minProjectionSlopePerHour else { return nil }

        let xHit = (1 - fit.intercept) / fit.slope         // seconds-since-first where y = 1
        guard xHit.isFinite else { return nil }
        let eta = Date(timeIntervalSince1970: x0 + xHit)
        guard eta > now else { return nil }
        if let reset, eta > reset { return nil }           // reset pre-empts the exhaustion
        return eta
    }

    // MARK: Helpers

    private static func fraction(_ sample: UsageSample, _ kind: UsageWindowKind) -> Double? {
        switch kind {
        case .fiveHour: return sample.fiveHour
        case .weekly:   return sample.weekly
        }
    }

    /// Ordinary least-squares fit of `y = slope·x + intercept`, plus R². Returns `nil`
    /// when the points are degenerate (fewer than two, or no spread in x).
    static func linearFit(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double, rSquared: Double)? {
        let n = Double(points.count)
        guard points.count >= 2 else { return nil }
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXX = points.reduce(0) { $0 + $1.x * $1.x }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        let meanY = sumY / n
        var ssTot = 0.0, ssRes = 0.0
        for point in points {
            let predicted = slope * point.x + intercept
            ssTot += (point.y - meanY) * (point.y - meanY)
            ssRes += (point.y - predicted) * (point.y - predicted)
        }
        let rSquared = ssTot == 0 ? 1 : 1 - ssRes / ssTot
        return (slope, intercept, rSquared)
    }
}
