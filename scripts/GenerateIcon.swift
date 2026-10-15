import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(64) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
] {
    let edge = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: edge, height: edge).fill()
    NSColor(srgbRed: 0.078, green: 0.478, blue: 0.384, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: edge * 0.08, y: edge * 0.08, width: edge * 0.84, height: edge * 0.84),
                 xRadius: edge * 0.2, yRadius: edge * 0.2).fill()
    let text = NSAttributedString(string: "ZC", attributes: [
        .font: NSFont.systemFont(ofSize: edge * 0.34, weight: .semibold), .foregroundColor: NSColor.white,
        .kern: -edge * 0.025,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: (edge - size.width) / 2, y: (edge - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}
