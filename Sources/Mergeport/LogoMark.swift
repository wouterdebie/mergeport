import AppKit

/// The app icon's anchor as a vector template image, for the menu bar and in-app marks.
enum MergeportLogo {
    /// Logo bounds in AppIcon.svg coordinates (y down), excluding the waves.
    private static let bounds = CGRect(x: 92, y: 78, width: 328, height: 344)

    static func template(height: CGFloat) -> NSImage {
        let size = NSSize(width: (height * bounds.width / bounds.height).rounded(), height: height)
        let image = NSImage(size: size)
        for resolution in [1, 2] {
            let pixelsWide = Int(size.width) * resolution
            let pixelsHigh = Int(size.height) * resolution
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            let graphics = NSGraphicsContext(bitmapImageRep: rep)!
            let context = graphics.cgContext
            context.scaleBy(x: CGFloat(resolution), y: CGFloat(resolution))
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(origin: .zero, size: size)
            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            context.translateBy(
                x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(solid)
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(holes)
            context.fillPath()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mergeport"
        return image
    }

    private static var solid: CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 241, y: 140, width: 30, height: 262), cornerWidth: 6, cornerHeight: 6)
        path.addRoundedRect(in: CGRect(x: 174, y: 160, width: 164, height: 28), cornerWidth: 14, cornerHeight: 14)
        // The fluke arc: a band around (256, 270) from about 20° to 160°.
        let center = CGPoint(x: 256, y: 270)
        let start = 20 * CGFloat.pi / 180, end = 160 * CGFloat.pi / 180
        let band = CGMutablePath()
        band.addArc(center: center, radius: 150, startAngle: start, endAngle: end, clockwise: false)
        band.addArc(center: center, radius: 122, startAngle: end, endAngle: start, clockwise: true)
        band.closeSubpath()
        path.addPath(band)
        for (x, y) in [(124.0, 304.0), (388, 304), (256, 110)] {
            path.addEllipse(in: CGRect(x: x - 31, y: y - 31, width: 62, height: 62))
        }
        return path
    }

    private static var holes: CGPath {
        let path = CGMutablePath()
        for (x, y, r) in [(124.0, 304.0, 12.0), (388, 304, 12), (256, 110, 13)] {
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}
