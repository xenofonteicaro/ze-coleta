import CoreGraphics
import Foundation
import ImageIO

// Render original vector initials offscreen, without AppKit or a WindowServer.
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
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.setFillColor(CGColor(red: 0.078, green: 0.478, blue: 0.384, alpha: 1))
    let square = CGRect(x: edge * 0.08, y: edge * 0.08, width: edge * 0.84, height: edge * 0.84)
    context.addPath(CGPath(roundedRect: square, cornerWidth: edge * 0.2, cornerHeight: edge * 0.2, transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(edge * 0.055)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: edge * 0.265, y: edge * 0.65))
    context.addLine(to: CGPoint(x: edge * 0.465, y: edge * 0.65))
    context.addLine(to: CGPoint(x: edge * 0.265, y: edge * 0.35))
    context.addLine(to: CGPoint(x: edge * 0.465, y: edge * 0.35))
    context.strokePath()
    context.addArc(center: CGPoint(x: edge * 0.665, y: edge * 0.50), radius: edge * 0.155,
                   startAngle: .pi / 4, endAngle: 7 * .pi / 4, clockwise: false)
    context.strokePath()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
                                                            "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
