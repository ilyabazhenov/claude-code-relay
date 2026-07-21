import SwiftUI
import AppKit

/// The menu-bar label. A `MenuBarExtra` label only reliably renders a **single** view —
/// give it two siblings and the trailing one is silently dropped. So the whole label —
/// the usage readout `6% | 36%` (five-hour and weekly, split by a hairline) — is composed
/// in SwiftUI and then **baked into one `NSImage`** with `ImageRenderer`. Each number is
/// colored by its own level. When there's no usage data yet, the Relay chevron (`»`)
/// stands in so the menu-bar item stays visible and clickable.
///
/// **Rendering the image (theme-baked, not template):** the label is always emitted as a
/// **colored** (non-template) image. In the calm state it's baked in the primary label
/// color for the current theme — near-black in light, near-white in dark. We do this
/// instead of a template glyph so the item stays vibrant on an **inactive display**:
/// macOS dims template glyphs (and menu-bar text) on unfocused screens, but leaves
/// full-color images alone. When a usage window crosses 75% we bake orange/red instead.
///
/// The tradeoff: a baked color follows the *app's* `colorScheme`, not the menu bar's
/// actual appearance. With a translucent menu bar (transparency on) over a wallpaper that
/// fights the theme — e.g. light theme, dark wallpaper — contrast can suffer. With
/// "Reduce transparency" on, the bar always matches the theme and this is a non-issue. We
/// also give up the template's automatic white inversion when the menu is open.
struct MenuBarLabel: View {
    @ObservedObject var daemon: Daemon
    @ObservedObject var rateLimits: RateLimitStore
    @Environment(\.colorScheme) private var scheme

    /// Which usage windows to show, per the user's setting.
    private var displayMode: MenuBarUsageDisplay { daemon.config.effectiveMenuBarUsageDisplay }

    var body: some View {
        Image(nsImage: labelImage)
    }

    /// The whole label, baked to one image at screen scale. Always a colored (non-template)
    /// image so it stays visible on inactive displays; primary label color when calm,
    /// warning tints when a window needs to stand out.
    @MainActor private var labelImage: NSImage {
        let renderer = ImageRenderer(content: composite(colored: needsColor).environment(\.colorScheme, scheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = false
        return image
    }

    /// True when the label must carry color: a usage window has crossed the warning
    /// threshold. Otherwise the label stays monochrome (template).
    private var needsColor: Bool {
        guard let snap = rateLimits.snapshot else { return false }
        let five = displayMode.showsFiveHour ? (snap.fiveHourFractionFresh ?? 0) : 0
        let weekly = displayMode.showsWeekly ? (snap.weeklyFractionFresh ?? 0) : 0
        return five >= 0.75 || weekly >= 0.75
    }

    /// The live SwiftUI composition that gets flattened into `labelImage`. When not
    /// `colored`, everything is drawn opaque in the primary color so the template mask is
    /// clean; `.secondary`/level tints are used only in the colored variant.
    private func composite(colored: Bool) -> some View {
        Group {
            if let snap = rateLimits.snapshot, hasUsage(snap) {
                usageRow(snap, colored: colored)
            } else {
                Image(nsImage: RelayGlyph.menuBar)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Usage (one line: `6% | 36%`)

    private func usageRow(_ snap: RateLimitSnapshot, colored: Bool) -> some View {
        let five = displayMode.showsFiveHour ? snap.fiveHourFractionFresh : nil
        let weekly = displayMode.showsWeekly ? snap.weeklyFractionFresh : nil
        return HStack(spacing: 4) {
            if let five { usageValue(five, colored: colored) }
            if five != nil && weekly != nil { divider }
            if let weekly { usageValue(weekly, colored: colored) }
        }
    }

    /// The hairline between the two numbers, drawn in the primary color so it reads as a
    /// separator in both the template (calm) and colored variants.
    private var divider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.primary)
            .frame(width: 1, height: 11)
    }

    private func usageValue(_ fraction: Double, colored: Bool) -> some View {
        let percent = Int((fraction * 100).rounded())
        return Text(daemon.config.effectiveMenuBarShowPercent ? "\(percent)%" : "\(percent)")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(colored ? level(fraction) : Color.primary)
    }

    private func hasUsage(_ snap: RateLimitSnapshot) -> Bool {
        (displayMode.showsFiveHour && snap.fiveHourFractionFresh != nil)
        || (displayMode.showsWeekly && snap.weeklyFractionFresh != nil)
    }

    /// Neutral until three-quarters gone, then warn (orange) and, near the cap, alarm.
    private func level(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .secondary
    }
}
