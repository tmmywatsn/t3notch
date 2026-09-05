import SwiftUI

/// A panel that reads as the notch itself growing: the top corners flare
/// outwards into the menu bar, the bottom corners are rounded normally.
struct NotchShape: Shape {
    var topRadius: CGFloat = 9
    var bottomRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 2)
        let bottom = min(bottomRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + top),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + top, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
