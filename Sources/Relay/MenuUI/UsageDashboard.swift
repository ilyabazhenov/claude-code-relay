import SwiftUI

/// The usage dashboard shown in the menu-bar window: the two current limits and the
/// recent 7-day peak as metric cards, an exhaustion-projection strip, a fixed-slot bar
/// chart of 5-hour peaks (with limit and average reference lines), and a collapsible
/// token breakdown groupable by model or project over a 5-hour or 7-day window. Reads the
/// live snapshot from `RateLimitStore`, completed windows and samples from its
/// `UsageHistoryStore`, and exact token throughput from `TokenUsageStore`.
struct UsageDashboard: View {
    @ObservedObject var rateLimits: RateLimitStore
    @ObservedObject var history: UsageHistoryStore
    @ObservedObject var tokens: TokenUsageStore
    @ObservedObject private var loc = Localization.shared

    /// How far back the "peak" card looks (always over 5-hour windows).
    private static let peaksLookback: TimeInterval = 7 * 24 * 3600
    /// Total slots the chart always draws, so its shape stays stable from first launch
    /// instead of a single stretched bar.
    private static let chartSlots = 12

    /// Which window the peaks chart is showing — 5-hour or weekly. The metric cards above
    /// stay fixed; only the chart below the toggle switches.
    @State private var peaksKind: UsageWindowKind = .fiveHour
    /// Whether the token breakdown is expanded. Collapsed by default so the popover stays
    /// short until the user asks for the detail.
    @State private var showTokens = false
    /// How the token breakdown groups its rows — by model or by project.
    @State private var tokenGrouping: TokenGrouping = .byModel
    /// The window the token breakdown aggregates over — the current 5-hour window or the
    /// last 7 days. Account-wide limit percentages can't be split per project, so this
    /// breakdown works off exact per-message token throughput instead.
    @State private var tokenPeriod: TokenPeriod = .fiveHour

    enum TokenGrouping: Hashable { case byModel, byProject }
    enum TokenPeriod: Hashable { case fiveHour, sevenDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricCards
            projectionStrip
            peaksSection
            tokensSection
        }
    }

    // MARK: Projection

    /// A one-line exhaustion forecast for the current 5-hour window: an amber warning with
    /// the projected time and countdown when usage is rising steadily toward the cap.
    /// Shown only when there's an actual projection — a steady window draws nothing, so
    /// the amber strip reads as a real signal to slow down rather than persistent chrome.
    @ViewBuilder private var projectionStrip: some View {
        let now = Date()
        let reset = rateLimits.snapshot?.fiveHourResetAt
        let eta = UsageAnalytics.projectedExhaustion(
            samples: history.samples, kind: .fiveHour, reset: reset, now: now)

        if let eta {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                Text(loc.projected100).font(.caption).fontWeight(.medium)
                Text("~\(Self.clock(eta)) · \(relative(eta, from: now))")
                    .font(.caption).monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }

    // MARK: Token breakdown

    /// A collapsible token breakdown, groupable by model or by project and over either the
    /// current 5-hour window or the last 7 days. Parsed from session transcripts, so it's
    /// exact per-message throughput — independent of the account-wide percentages above,
    /// which can't be split per project.
    @ViewBuilder private var tokensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTokens.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showTokens ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(loc.tokenUsage).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                if showTokens {
                    Picker("", selection: $tokenPeriod) {
                        Text(loc.periodFiveHour).tag(TokenPeriod.fiveHour)
                        Text(loc.periodSevenDay).tag(TokenPeriod.sevenDay)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .controlSize(.mini)
                } else {
                    Text(loc.thisFiveHourWindow).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if showTokens {
                Picker("", selection: $tokenGrouping) {
                    Text(loc.groupByModel).tag(TokenGrouping.byModel)
                    Text(loc.groupByProject).tag(TokenGrouping.byProject)
                }
                .pickerStyle(.segmented).labelsHidden()

                tokenRows
            }
        }
    }

    @ViewBuilder private var tokenRows: some View {
        switch tokenGrouping {
        case .byModel:
            let rows = TokenUsageStore.tokensByModel(tokens.records, since: tokenSince)
            let grand = rows.reduce(0) { $0 + $1.total }
            if rows.isEmpty || grand == 0 {
                emptyTokens
            } else {
                ForEach(rows, id: \.model) { row in
                    tokenRow(tint: nil, label: Self.modelName(row.model),
                             count: row.total, share: Double(row.total) / Double(grand))
                }
            }
        case .byProject:
            let rows = TokenUsageStore.tokensByProject(tokens.records, since: tokenSince)
            let grand = rows.reduce(0) { $0 + $1.total }
            if rows.isEmpty || grand == 0 {
                emptyTokens
            } else {
                ForEach(rows, id: \.project) { row in
                    tokenRow(tint: Self.projectColor(row.project),
                             label: row.project.isEmpty ? loc.unknownProject : row.project,
                             count: row.total, share: Double(row.total) / Double(grand))
                }
            }
        }
    }

    private var emptyTokens: some View {
        Text(loc.noTokenActivity)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    /// One breakdown row: an optional leading color swatch (project rows only — it doubles
    /// as a legend so short bars stay identifiable), a label, a share bar, and the token
    /// count. When `tint` is set it colors both the swatch and the bar; otherwise the bar
    /// falls back to the accent color (model rows).
    private func tokenRow(tint: Color?, label: String, count: Int, share: Double) -> some View {
        HStack(spacing: 8) {
            if let tint {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(label)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .frame(width: tint == nil ? 70 : 63, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint ?? Color.accentColor).frame(width: max(2, geo.size.width * share))
                }
            }
            .frame(height: 6)
            Text(Self.tokenLabel(count))
                .font(.caption).fontWeight(.medium).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    /// The window the token breakdown aggregates over, per the period toggle.
    private var tokenSince: Date {
        switch tokenPeriod {
        case .fiveHour: return currentFiveHourStart
        case .sevenDay: return Date().addingTimeInterval(-7 * 24 * 3600)
        }
    }

    /// Start of the current 5-hour window, implied by its reset time.
    private var currentFiveHourStart: Date {
        (rateLimits.snapshot?.fiveHourResetAt ?? Date().addingTimeInterval(5 * 3600))
            .addingTimeInterval(-5 * 3600)
    }

    // MARK: Metric cards

    private var metricCards: some View {
        HStack(spacing: 8) {
            metricCard(
                label: loc.cardFiveHour,
                icon: "clock",
                value: rateLimits.snapshot?.fiveHourFractionFresh,
                caption: rateLimits.snapshot?.fiveHourResetAt.map { loc.resetsCaption(relative($0, from: Date())) },
                identity: Self.identityFiveHour
            )
            metricCard(
                label: loc.cardWeekly,
                icon: "calendar",
                value: rateLimits.snapshot?.weeklyFractionFresh,
                caption: rateLimits.snapshot?.weeklyResetAt.map { loc.resetsCaption(relative($0, from: Date())) },
                identity: Self.identityWeekly
            )
            metricCard(
                label: loc.cardPeak7d,
                icon: "flame.fill",
                value: peak7dFiveHour?.peakFraction,
                caption: peak7dFiveHour.map { windowLabel($0) } ?? loc.collecting,
                identity: Self.identityPeak
            )
        }
    }

    /// A compact card: an icon + uppercased label, big percentage, a caption, and a thin
    /// level bar. Hybrid coloring — the card lives in its own `identity` hue (so the three
    /// cards are told apart at a glance), but the number, bar, and a card outline escalate
    /// to warning (amber) then danger (red) as the value nears its limit, so urgency still
    /// reads without looking at the digits.
    private func metricCard(label: String, icon: String, value: Double?, caption: String?, identity: Color) -> some View {
        let state = Self.cardState(value)
        let tint = Self.stateColor(state, identity: identity)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(identity)
                Text(label.uppercased())
                    .font(.system(size: 10)).foregroundStyle(.secondary).tracking(0.4)
            }
            Text(value.map { "\(Self.percent($0))%" } ?? "—")
                .font(.system(size: 22, weight: .medium)).monospacedDigit()
                .foregroundStyle(value != nil ? tint : .primary)
            Text(caption ?? loc.noData)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            levelBar(fraction: value ?? 0, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Self.dangerColor.opacity(state == .danger ? 0.55 : 0), lineWidth: 1)
        )
    }

    private func levelBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .padding(.top, 2)
    }

    // MARK: Peaks chart

    @ViewBuilder private var peaksSection: some View {
        let completed = historyWindows(peaksKind)
        let current = currentFraction(peaksKind)
        let slots = chartSlots(completed: completed, current: current,
                               currentReset: currentReset(peaksKind), kind: peaksKind)
        let avg = average(completed)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(loc.peaks).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $peaksKind) {
                    Text(loc.segFiveHourShort).tag(UsageWindowKind.fiveHour)
                    Text(loc.segWeekShort).tag(UsageWindowKind.weekly)
                }
                .pickerStyle(.segmented).controlSize(.mini).fixedSize()
                Spacer()
                Text(peaksCaption(completed: completed, avg: avg))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if slots.allSatisfy({ $0.fraction == nil }) {
                placeholder(text: loc.waitingFirstReading)
            } else {
                PeaksChart(slots: slots, average: avg)
                    .frame(height: 84)
                HStack {
                    // Only show the left date once the leftmost slot actually carries a
                    // window — otherwise the label would sit under empty slots and imply
                    // data that isn't there.
                    Text(slots.first?.fraction != nil ? (completed.first.map { Self.dayLabel($0.startedAt) } ?? "") : "")
                    Spacer()
                    Text(current != nil ? loc.now
                         : (completed.last.map { Self.isTodayish($0.startedAt) ? loc.today : Self.dayLabel($0.startedAt) } ?? ""))
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func placeholder(text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14).padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(Color.primary.opacity(0.15))
            )
    }

    // MARK: Data shaping

    /// Completed windows of `kind`, oldest first. No age cutoff — the chart caps to its
    /// slot count, and weekly windows are sparse enough that a time window would hide them.
    private func historyWindows(_ kind: UsageWindowKind) -> [UsageWindow] {
        history.windows.filter { $0.kind == kind }
    }

    /// The hottest 5-hour window in the last 7 days, for the (fixed) peak card. Independent
    /// of the chart's 5h/weekly toggle.
    private var peak7dFiveHour: UsageWindow? {
        let cutoff = Date().addingTimeInterval(-Self.peaksLookback)
        return history.windows
            .filter { $0.kind == .fiveHour && $0.startedAt >= cutoff }
            .max { $0.peakFraction < $1.peakFraction }
    }

    /// The live fraction of the still-open window of `kind`, if fresh.
    private func currentFraction(_ kind: UsageWindowKind) -> Double? {
        switch kind {
        case .fiveHour: return rateLimits.snapshot?.fiveHourFractionFresh
        case .weekly:   return rateLimits.snapshot?.weeklyFractionFresh
        }
    }

    /// The reset time of the still-open window of `kind`.
    private func currentReset(_ kind: UsageWindowKind) -> Date? {
        switch kind {
        case .fiveHour: return rateLimits.snapshot?.fiveHourResetAt
        case .weekly:   return rateLimits.snapshot?.weeklyResetAt
        }
    }

    private static func duration(_ kind: UsageWindowKind) -> TimeInterval {
        kind == .fiveHour ? 5 * 3600 : 7 * 24 * 3600
    }

    private func average(_ windows: [UsageWindow]) -> Double {
        guard !windows.isEmpty else { return 0 }
        return windows.reduce(0) { $0 + $1.peakFraction } / Double(windows.count)
    }

    /// Fixed-width chart slots so the chart keeps a stable shape from first launch: a run
    /// of empty (zero) slots, filled from the right by completed windows, with the
    /// still-open current window as the last, filled bar.
    private func chartSlots(completed: [UsageWindow], current: Double?, currentReset: Date?,
                            kind: UsageWindowKind) -> [PeaksChart.Slot] {
        let capacity = current != nil ? Self.chartSlots - 1 : Self.chartSlots
        let recent = Array(completed.suffix(capacity))
        var slots: [PeaksChart.Slot] = []
        for _ in 0..<max(0, capacity - recent.count) {
            slots.append(.init(fraction: nil, isCurrent: false, hitLimit: false))
        }
        for window in recent {
            slots.append(.init(fraction: window.peakFraction, isCurrent: false,
                               hitLimit: window.hitLimit, interval: windowLabel(window)))
        }
        if let current {
            // Back-date the current window's start from its reset so its range reads the
            // same way as a completed one; fall back to a full span ending at the reset.
            let end = currentReset ?? Date().addingTimeInterval(Self.duration(kind))
            let interval = intervalLabel(start: end.addingTimeInterval(-Self.duration(kind)),
                                         end: end, kind: kind)
            slots.append(.init(fraction: current, isCurrent: true,
                               hitLimit: current >= UsageHistoryStore.hitLimitThreshold,
                               interval: interval))
        }
        return slots
    }

    private func peaksCaption(completed: [UsageWindow], avg: Double) -> String {
        guard !completed.isEmpty else { return loc.collecting }
        return loc.peaksCaption(windows: completed.count, avgPercent: Self.percent(avg))
    }

    // MARK: Formatting

    private static func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    // MARK: Card color scheme (hybrid: identity hue + warn/danger escalation)

    /// Per-card identity hues, so the three cards are distinguishable at a glance.
    static let identityFiveHour = Color.accentColor                          // blue
    static let identityWeekly = Color(red: 0.55, green: 0.48, blue: 0.86)    // violet
    static let identityPeak = Color(red: 0.93, green: 0.63, blue: 0.23)      // amber
    /// Escalation colors shared by all cards.
    static let warnColor = Color(red: 0.93, green: 0.63, blue: 0.23)         // amber
    static let dangerColor = Color(red: 0.89, green: 0.31, blue: 0.31)       // red

    /// How close a card's value is to its limit. Empty when there's no reading yet.
    enum CardState { case empty, normal, warn, danger }

    static func cardState(_ value: Double?) -> CardState {
        guard let value else { return .empty }
        if value >= 0.85 { return .danger }
        if value >= 0.70 { return .warn }
        return .normal
    }

    /// The number/bar tint: the card's identity hue until it warms up, then amber, then red.
    static func stateColor(_ state: CardState, identity: Color) -> Color {
        switch state {
        case .empty, .normal: return identity
        case .warn:           return warnColor
        case .danger:         return dangerColor
        }
    }

    private func relative(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return loc.now }
        return loc.relativeFuture(minutes: Int(seconds / 60))
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let dayFormatter = formatter("MMM d")
    private static let hourFormatter = formatter("HH")
    private static let clockFormatter = formatter("HH:mm")

    private static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// Friendly model name from an id like `claude-opus-4-8` → `Opus 4.8`.
    private static func modelName(_ id: String) -> String {
        let known: [(prefix: String, name: String)] = [
            ("claude-opus-4-8", "Opus 4.8"),
            ("claude-sonnet-5", "Sonnet 5"),
            ("claude-haiku-4-5", "Haiku 4.5"),
            ("claude-fable-5", "Fable 5")
        ]
        for entry in known where id.hasPrefix(entry.prefix) { return entry.name }
        return id.replacingOccurrences(of: "claude-", with: "")
    }

    /// A palette of distinct, dark- and light-mode-friendly hues assigned to projects so
    /// each reads as its own color in the breakdown. Spread around the color wheel so
    /// neighbours in the list stay easy to tell apart.
    private static let projectPalette: [Color] = [
        Color(red: 0.00, green: 0.48, blue: 1.00),  // blue
        Color(red: 0.20, green: 0.65, blue: 0.98),  // azure
        Color(red: 0.10, green: 0.78, blue: 0.80),  // teal
        Color(red: 0.20, green: 0.78, blue: 0.35),  // green
        Color(red: 0.60, green: 0.80, blue: 0.20),  // lime
        Color(red: 0.95, green: 0.80, blue: 0.20),  // yellow
        Color(red: 1.00, green: 0.62, blue: 0.04),  // orange
        Color(red: 1.00, green: 0.48, blue: 0.30),  // coral
        Color(red: 1.00, green: 0.30, blue: 0.35),  // red
        Color(red: 1.00, green: 0.30, blue: 0.55),  // pink
        Color(red: 0.92, green: 0.30, blue: 0.80),  // magenta
        Color(red: 0.72, green: 0.38, blue: 0.95),  // purple
        Color(red: 0.55, green: 0.45, blue: 0.98),  // violet
        Color(red: 0.37, green: 0.40, blue: 0.92),  // indigo
        Color(red: 0.35, green: 0.85, blue: 0.62),  // mint
        Color(red: 0.72, green: 0.55, blue: 0.38)   // tan
    ]

    /// A stable color for a project, derived from a deterministic (launch-independent) hash
    /// of its name so a project keeps the same color across sessions. The unknown bucket
    /// ("") is a neutral gray, so the legacy pre-tagging pile doesn't grab a vivid hue.
    private static func projectColor(_ name: String) -> Color {
        guard !name.isEmpty else { return Color(red: 0.55, green: 0.55, blue: 0.53) }
        var hash: UInt64 = 1469598103934665603            // FNV-1a offset basis
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return projectPalette[Int(hash % UInt64(projectPalette.count))]
    }

    /// Compact token count: `1.2M`, `340K`, `512`.
    private static func tokenLabel(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func dayLabel(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func isTodayish(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    /// 5-hour: "today 14–19" / "yest 09–14" / "Jul 3 10–15". Weekly: "Jul 1 – Jul 8".
    func windowLabel(_ window: UsageWindow) -> String {
        intervalLabel(start: window.startedAt, end: window.endedAt, kind: window.kind)
    }

    /// The shared range label used for both completed and current windows: an hour range
    /// for 5-hour windows, a date range for weekly ones.
    func intervalLabel(start: Date, end: Date, kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour:
            let cal = Calendar.current
            let day: String
            if cal.isDateInToday(start) { day = loc.todayShort }
            else if cal.isDateInYesterday(start) { day = loc.yesterdayShort }
            else { day = Self.dayFormatter.string(from: start) }
            return "\(day) \(Self.hourFormatter.string(from: start))–\(Self.hourFormatter.string(from: end))"
        case .weekly:
            return "\(Self.dayFormatter.string(from: start)) – \(Self.dayFormatter.string(from: end))"
        }
    }
}

/// A fixed-slot chart of 5-hour peaks. Each slot shows a faint full-height track so
/// empty (zero) windows stay visible as slots; filled slots draw a bar whose height maps
/// the peak fraction and whose color tracks the level (accent → orange → red). The
/// current, still-open window is drawn as a distinct outlined bar. Dashed reference lines
/// mark the limit (100%) and — once there's history — the running average.
struct PeaksChart: View {
    /// One column of the chart. `fraction == nil` is an empty (not-yet-used) slot.
    /// `interval` is the human-readable hour range the column covers (e.g. "yest 21–02"),
    /// surfaced in the hover tooltip; empty slots carry none.
    struct Slot: Identifiable {
        let id = UUID()
        let fraction: Double?
        let isCurrent: Bool
        let hitLimit: Bool
        var interval: String? = nil
    }

    let slots: [Slot]
    let average: Double
    @ObservedObject private var loc = Localization.shared

    /// Index of the column the pointer is over, driving the hover tooltip + highlight.
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width
            ZStack(alignment: .bottomLeading) {
                referenceLine(at: 1.0, height: height, color: .red.opacity(0.5), label: "100%")
                if average > 0.005 {
                    referenceLine(at: average, height: height, color: .secondary.opacity(0.5),
                                  label: loc.avgReferenceLabel(Int((average * 100).rounded())))
                }

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(slots.indices, id: \.self) { index in
                        slotColumn(slots[index], height: height, highlighted: hovered == index)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = index }
                                else if hovered == index { hovered = nil }
                            }
                    }
                }

                if let index = hovered, index < slots.count, slots[index].interval != nil {
                    tooltip(for: slots[index], index: index, width: width, height: height)
                }
            }
        }
    }

    /// A small floating card centered over the hovered column, just above its bar: the
    /// hour interval the column covers, its peak, and a "now" / "hit limit" note. Clamped
    /// to stay inside the chart and non-interactive so it never steals its own hover.
    @ViewBuilder private func tooltip(for slot: Slot, index: Int, width: CGFloat, height: CGFloat) -> some View {
        let slotWidth = width / CGFloat(max(1, slots.count))
        let centerX = (CGFloat(index) + 0.5) * slotWidth
        let peak = min(1, max(0, slot.fraction ?? 0))
        let barTop = height * (1 - peak)
        let pct = Int((peak * 100).rounded())

        VStack(alignment: .leading, spacing: 2) {
            Text(slot.interval ?? "").font(.system(size: 10, weight: .medium))
            HStack(spacing: 5) {
                Text("\(pct)%").font(.system(size: 10)).monospacedDigit().foregroundStyle(color(peak))
                if slot.isCurrent {
                    Text(loc.now).font(.system(size: 9)).foregroundStyle(.secondary)
                } else if slot.hitLimit {
                    Text(loc.hitLimitShort).font(.system(size: 9)).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
        .allowsHitTesting(false)
        .position(x: min(max(centerX, 52), width - 52), y: max(20, barTop - 20))
    }

    /// A single column: the faint track (brighter while hovered), plus a bar when the slot
    /// carries a value. The interval readout is handled by the hover tooltip, not `.help`.
    @ViewBuilder private func slotColumn(_ slot: Slot, height: CGFloat, highlighted: Bool) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(highlighted ? 0.10 : 0.04))
                .frame(height: height)
            if let fraction = slot.fraction {
                let peak = min(1, max(0, fraction))
                RoundedRectangle(cornerRadius: 2)
                    .fill(slot.isCurrent ? color(peak).opacity(0.55) : color(peak))
                    .frame(height: max(3, height * peak))
                    .overlay {
                        if slot.isCurrent {
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(color(peak), lineWidth: 1.5)
                        }
                    }
            }
        }
    }

    /// A dashed horizontal line at `fraction` of the full height, labelled at the left.
    /// The label normally sits just above the line, but flips to just below it when the
    /// line is near the top edge — otherwise a top line's label would spill into the
    /// section header above the chart.
    private func referenceLine(at fraction: Double, height: CGFloat, color: Color, label: String) -> some View {
        let y = height * (1 - min(1, max(0, fraction)))
        let labelY = y < 14 ? y + 2 : y - 12
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: 4000, y: y))
            }
            .stroke(style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
            .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9)).foregroundStyle(color)
                .offset(x: 0, y: labelY)
        }
    }

    private func color(_ fraction: Double) -> Color {
        fraction >= UsageHistoryStore.hitLimitThreshold ? .red : (fraction >= 0.75 ? .orange : .accentColor)
    }
}
