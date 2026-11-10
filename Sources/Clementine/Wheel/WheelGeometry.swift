import CoreGraphics
import Foundation

/// Ring layout shared by drawing and hit-testing. Angles are degrees, clockwise from +x in a y-down space.
enum WheelGeometry {
    static let size: CGFloat = 330
    static let outer: CGFloat = 156
    static let inner: CGFloat = 56
    static let gapDegrees: Double = 1.6
    static let labelRadius: CGFloat = 108

    static func step(_ count: Int) -> Double { 360.0 / Double(max(count, 1)) }
    static func origin(_ count: Int) -> Double { -90 - step(count) / 2 }

    static func angles(index: Int, count: Int) -> (start: Double, end: Double) {
        let s = step(count)
        let start = origin(count) + Double(index) * s
        return (start + gapDegrees / 2, start + s - gapDegrees / 2)
    }

    static func labelCenter(index: Int, count: Int, in rect: CGRect) -> CGPoint {
        let (a, b) = angles(index: index, count: count)
        let mid = (a + b) / 2 * .pi / 180
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY + sin(mid) * labelRadius)
    }

    static func index(forPoint p: CGPoint, in rect: CGRect, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = p.x - rect.midX, dy = p.y - rect.midY
        let d = hypot(dx, dy)
        guard d >= inner, d <= outer + 10 else { return nil }
        let deg = atan2(dy, dx) * 180 / .pi
        var rel = (deg - origin(count)).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        return Int(rel / step(count)) % count
    }
}
