import AppKit
import Foundation

let fm = FileManager.default
let dir = URL(fileURLWithPath: "work/AppIcon.iconset")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    let box = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
    NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1).setFill()
    box.fill()
    // Same seven-ring arrangement as the menu-bar reference, drawn crisply at every icon size.
    NSColor(calibratedRed: 0.14, green: 0.135, blue: 0.12, alpha: 1).setStroke()
    let spacing: CGFloat = 192
    let centers = [CGPoint(x: 512, y: 512)] + (0..<6).map { i in
        CGPoint(x: 512 + spacing * cos(CGFloat(i) * .pi / 3), y: 512 + spacing * sin(CGFloat(i) * .pi / 3))
    }
    for center in centers {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 69, y: center.y - 69, width: 138, height: 138))
        circle.lineWidth = 31
        circle.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name + ".png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", dir.path, "-o", "Resources/LumaRingIcon-1.3.icns"]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
