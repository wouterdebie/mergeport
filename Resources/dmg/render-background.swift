import AppKit

// Run from the repository root: swift Resources/dmg/render-background.swift
let width = 600
let height = 360
let output = URL(fileURLWithPath: "Resources/dmg")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
                                  pixelsHigh: height * scale, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // The bitmap context already maps this logical size to its Retina pixels.
    // An additional scale transform would crop the 2x background in Finder.
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(starting: color(0xFBFCFE), ending: color(0xEDF2F8))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
              foreground: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (value as NSString).draw(in: NSRect(x: 20, y: y, width: 560, height: size + 10),
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                             .foregroundColor: foreground, .paragraphStyle: style])
    }
    text("Drag Mergeport to Applications", y: 285,
         size: 21, weight: .semibold, foreground: color(0x26364D))
    text("→", y: 150, size: 46, weight: .light, foreground: color(0x75879C))
    text("Then open it from Applications.", y: 34,
         size: 13, weight: .regular, foreground: color(0x5B6A7D))
    NSGraphicsContext.restoreGraphicsState()
    let filename = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}
