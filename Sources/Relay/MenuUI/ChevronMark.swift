import SwiftUI

/// The Relay brand mark: a forward **double chevron** (`»`) — a shell prompt pointing
/// the way a reply travels back into the session. It is the one constant across the
/// whole identity (menu-bar glyph, `.app` icon, wordmark `relay ›`); state is layered
/// on top as a badge, never by changing the mark itself.
///
/// Drawn as an open stroked path so it stays crisp at menu-bar sizes and scales cleanly
/// to any icon dimension. Stroke it with round caps/joins:
///
/// ```
/// ChevronMark().stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
/// ```
///
/// The mark's aspect ratio is ~0.8 (width ≈ 0.8 × height); size the containing frame to
/// match so the round caps are not clipped.
struct ChevronMark: Shape {
    /// How many stacked chevrons to draw. Two is the brand default; one degrades to a
    /// plain `›` if ever needed at extreme small sizes.
    var count: Int = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let h = rect.height
        let arm = h * 0.46          // horizontal reach of each chevron
        let step = h * 0.34         // spacing between successive tips
        let inset = h * 0.07        // keep round caps inside the frame
        let top = rect.minY + inset
        let bottom = rect.maxY - inset
        let midY = rect.midY
        for i in 0..<max(count, 1) {
            let x = rect.minX + CGFloat(i) * step + inset
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + arm, y: midY))
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
        return path
    }
}
