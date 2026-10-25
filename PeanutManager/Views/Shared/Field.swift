import SwiftUI
import LineupKit

/// Little League infield proportions in feet (60-ft bases, 46-ft mound), home plate at the origin and +y toward
/// center field. The outfield is drawn shallower than a real 200-ft fence so the infield has room.
nonisolated enum FieldGeometry {
    static let bases = 60.0, mound = 46.0, fence = 120.0
    static let size = CGSize(width: 336, height: 262)

    /// Points per foot: the 90° wedge's width at the fence fills the view.
    static let scale: Double = (size.width - 24) / (2 * fence * sin(.pi / 4))
    static var home: CGPoint { CGPoint(x: size.width / 2, y: size.height - 26) }

    static func point(_ feet: (Double, Double)) -> CGPoint {
        CGPoint(x: home.x + feet.0 * scale, y: home.y - feet.1 * scale)
    }

    static func polar(_ degrees: Double, _ distance: Double) -> (Double, Double) {
        let r = degrees * .pi / 180
        return (distance * sin(r), distance * cos(r))
    }

    static let fielder: [Position: (Double, Double)] = {
        let b = bases / 2.0.squareRoot()
        return [
            .p: (0, b), .c: (0, 0),  // pitcher level with 1B and 3B
            // Corner infielders on their bags; middle infielders on the baselines, halfway to second.
            .first: (b, b), .third: (-b, b), .second: (b / 2, 1.5 * b), .ss: (-b / 2, 1.5 * b),
            .lf: polar(-30, fence * 0.8), .cf: polar(0, fence * 0.82), .rf: polar(30, fence * 0.8),
        ]
    }()
}

/// Straight foul lines, the fence, a square diamond and the mound: lines only.
struct FieldDrawing: View {
    /// Draw larger than `FieldGeometry.size` without thickening the lines.
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            let w = 1 / scale
            let g = FieldGeometry.self
            let home = g.home
            let b = g.bases / 2.0.squareRoot()
            let line = Color.primary.opacity(0.28)

            func arc(_ feet: Double) -> Path {
                var path = Path()
                path.addArc(center: home, radius: feet * g.scale, startAngle: .degrees(-135), endAngle: .degrees(-45), clockwise: false)
                return path
            }

            // Foul lines run straight from home plate to the fence.
            var foul = Path()
            foul.move(to: home); foul.addLine(to: g.point(g.polar(-45, g.fence)))
            foul.move(to: home); foul.addLine(to: g.point(g.polar(45, g.fence)))
            context.stroke(foul, with: .color(line), lineWidth: 1.5 * w)
            context.stroke(arc(g.fence), with: .color(line), lineWidth: 1.5 * w)

            let first = g.point((b, b)), second = g.point((0, 2 * b)), third = g.point((-b, b))
            var diamond = Path()
            diamond.move(to: home); diamond.addLine(to: first); diamond.addLine(to: second); diamond.addLine(to: third); diamond.closeSubpath()
            context.stroke(diamond, with: .color(line), lineWidth: 1.5 * w)

            let mound = g.point((0, g.mound))
            context.stroke(Path(ellipseIn: CGRect(x: mound.x - 7, y: mound.y - 7, width: 14, height: 14)), with: .color(Color.primary.opacity(0.18)), lineWidth: w)
        }
    }
}
