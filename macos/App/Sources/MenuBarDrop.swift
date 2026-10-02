import AppKit

/// MenuBarDrop is the menu bar mark's outline: a circular body under a
/// short point whose tip is rounded slightly, so it reads as a drop and not
/// a stretched teardrop, and stays soft at 1x.
enum MenuBarDrop {
    /// widthOverHeight is the drawn path's bounds width over its height.
    static let widthOverHeight: CGFloat = 0.82
    static let tipRadius: CGFloat = 1.0

    /// path is the outline in a rect of the given height, centred on x = 0
    /// horizontally and sitting on y = 0; its bounds are exactly
    /// widthOverHeight * height wide and height tall.
    static func path(height: CGFloat) -> NSBezierPath {
        let r = widthOverHeight * height / 2
        let t = tipRadius
        // d is the distance from the body's centre to the sharp tip that
        // leaves the rounded tip's top exactly `height - r` above it.
        let d = (height - r - t) / (1 - t / r)
        let sinA = r / d
        let alpha = asin(sinA)
        let cosA = cos(alpha)
        let centre = NSPoint(x: 0, y: r)
        let tipCentre = NSPoint(x: 0, y: centre.y + d - t / sinA)
        let degrees = alpha * 180 / .pi

        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x + r * cosA, y: centre.y + r * sinA))
        path.line(to: NSPoint(x: tipCentre.x + t * cosA, y: tipCentre.y + t * sinA))
        path.appendArc(withCenter: tipCentre, radius: t, startAngle: degrees, endAngle: 180 - degrees)
        path.line(to: NSPoint(x: centre.x - r * cosA, y: centre.y + r * sinA))
        path.appendArc(withCenter: centre, radius: r, startAngle: 180 - degrees, endAngle: 360 + degrees)
        path.close()
        return path
    }
}
