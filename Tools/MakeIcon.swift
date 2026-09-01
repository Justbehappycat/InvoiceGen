import AppKit
import Foundation

// Draws the app icon: a miniature invoice sheet on a rounded slate tile.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 60 * s, y: 60 * s, width: 904 * s, height: 904 * s),
        xRadius: 200 * s, yRadius: 200 * s
    )
    let gradient = NSGradient(
        colors: [NSColor(calibratedWhite: 0.36, alpha: 1), NSColor(calibratedWhite: 0.62, alpha: 1)]
    )!
    gradient.draw(in: tile, angle: -90)

    // Paper
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let paper = NSBezierPath(
        roundedRect: NSRect(x: 250 * s, y: 190 * s, width: 524 * s, height: 644 * s),
        xRadius: 26 * s, yRadius: 26 * s
    )
    NSColor.white.setFill()
    paper.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Banner
    ctx.saveGState()
    paper.addClip()
    NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
    NSRect(x: 250 * s, y: 690 * s, width: 524 * s, height: 144 * s).fill()
    NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
    NSRect(x: 600 * s, y: 690 * s, width: 174 * s, height: 144 * s).fill()
    ctx.restoreGState()

    // Ruled lines
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    var y: CGFloat = 600
    for index in 0..<6 {
        let width: CGFloat = index.isMultiple(of: 2) ? 300 : 240
        NSRect(x: 310 * s, y: y * s, width: width * s, height: 20 * s).fill()
        y -= 62
    }
    NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
    NSRect(x: 560 * s, y: 250 * s, width: 154 * s, height: 26 * s).fill()

    image.unlockFocus()
    return image
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("InvoiceGen.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}
print(iconset.path)
