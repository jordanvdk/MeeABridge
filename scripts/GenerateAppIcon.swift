import AppKit
import Foundation

// A small, reproducible vector mark. This script runs on macOS before XcodeGen.
let destination = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/Icon.png")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.055, green: 0.145, blue: 0.18, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let mark = NSBezierPath()
mark.move(to: NSPoint(x: 280, y: 310))
mark.line(to: NSPoint(x: 280, y: 714))
mark.line(to: NSPoint(x: 512, y: 475))
mark.line(to: NSPoint(x: 744, y: 714))
mark.line(to: NSPoint(x: 744, y: 310))
mark.lineWidth = 88
mark.lineCapStyle = .round
mark.lineJoinStyle = .round
NSColor(srgbRed: 0.53, green: 0.88, blue: 0.77, alpha: 1).setStroke()
mark.stroke()
NSColor(srgbRed: 0.99, green: 0.76, blue: 0.40, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: 270, width: 84, height: 84)).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render app icon")
}
try png.write(to: destination, options: .atomic)
print("Generated opaque 1024px app icon.")
