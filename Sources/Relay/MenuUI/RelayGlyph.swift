import AppKit

/// The Relay menu-bar logo — the double chevron (`»`) — rendered as a **template**
/// `NSImage`. Template images are drawn in black and recolored by AppKit to match the
/// menu bar (light/dark, highlighted). Drawing the glyph as an image (rather than a
/// SwiftUI `Shape`) is the reliable way to get a crisp, correctly-sized mark in a
/// `MenuBarExtra` label.
///
/// Geometry mirrors ``ChevronMark`` / the `.app` icon so the whole identity is one mark.
enum RelayGlyph {
    /// Cached glyph sized for the menu bar. Appearance-adapting, so one instance is enough.
    static let menuBar: NSImage = chevron(height: 14)

    static func chevron(height h: CGFloat) -> NSImage {
        let arm = h * 0.46          // horizontal reach of each chevron
        let step = h * 0.34         // spacing between the two tips
        let inset = h * 0.12
        let lineWidth = max(1.8, h * 0.14)
        let width = ceil(inset + lineWidth + step + arm + lineWidth / 2)

        let image = NSImage(size: NSSize(width: width, height: h))
        image.lockFocus()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let top = h - inset         // NSImage is bottom-up; the chevron is vertically
        let bottom = inset          // symmetric, so orientation does not matter.
        let mid = h / 2
        for i in 0..<2 {
            let x = inset + lineWidth / 2 + CGFloat(i) * step
            path.move(to: NSPoint(x: x, y: top))
            path.line(to: NSPoint(x: x + arm, y: mid))
            path.line(to: NSPoint(x: x, y: bottom))
        }
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
