import SwiftUI

/// The island's silhouette: rounded at the bottom, and curving *outward* into
/// the menu bar at the top.
///
/// Those top curves are the difference between an island that looks carved out
/// of the bezel and one that looks stuck onto it. A plain rounded rectangle
/// meets the menu bar at a hard 90° join, which reads as a sticker; real notch
/// UI flares outward so the black flows into the bar around it.
///
/// The shape's rect is wider than the island body by `concaveRadius` on each
/// side — the flares live in that margin, so the body keeps its intended width.
///
/// The flare stays on when collapsed. The resting island carries a small leading
/// wing with the microphone glyph in it, so there is already a visible black
/// shape, and the flare is what makes that wing read as attached to the notch
/// rather than stuck beside it. Both radii are animatable — a shape that can
/// only be set once cannot be animated later without rediscovering why.
@Animatable
struct NotchIslandShape: Shape {
    var bottomRadius: CGFloat
    var concaveRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Clamp so an over-large radius on a short strip cannot invert the path
        // into a self-intersecting mess.
        let concave = max(0, min(concaveRadius, rect.width / 2, rect.height))
        let bottom = max(0, min(bottomRadius, (rect.width - concave * 2) / 2, rect.height - 0.01))

        let left = rect.minX + concave      // body's left edge
        let right = rect.maxX - concave     // body's right edge
        let top = rect.minY
        let bot = rect.maxY

        var p = Path()

        // Top-left: start out in the menu bar and curve down into the body,
        // centre of the arc sitting above-left so the curve is concave.
        p.move(to: CGPoint(x: rect.minX, y: top))
        p.addArc(
            center: CGPoint(x: rect.minX, y: top + concave),
            radius: concave,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Down the left edge, into the rounded bottom-left corner.
        p.addLine(to: CGPoint(x: left, y: bot - bottom))
        p.addArc(
            center: CGPoint(x: left + bottom, y: bot - bottom),
            radius: bottom,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Across the bottom and up through the bottom-right corner.
        p.addLine(to: CGPoint(x: right - bottom, y: bot))
        p.addArc(
            center: CGPoint(x: right - bottom, y: bot - bottom),
            radius: bottom,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Up the right edge, then flare back out into the menu bar.
        p.addLine(to: CGPoint(x: right, y: top + concave))
        p.addArc(
            center: CGPoint(x: rect.maxX, y: top + concave),
            radius: concave,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        p.closeSubpath()
        return p
    }
}
