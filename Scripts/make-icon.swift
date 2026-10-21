// Renders the Veltoret app icon (Android's adaptive-icon mark on the macOS icon grid) to Resources/AppIcon.icns.
// Run: swift Scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    // macOS grid: 824×824 rounded square centred in 1024, corner radius ~185.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil))
    ctx.setFillColor(CGColor(red: 0x0B/255, green: 0x0B/255, blue: 0x0D/255, alpha: 1))
    ctx.fillPath()
    // Hairline outline (flat, no gradient).
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
    ctx.setStrokeColor(CGColor(red: 0x2C/255, green: 0x2C/255, blue: 0x35/255, alpha: 1))
    ctx.setLineWidth(3 * s)
    ctx.strokePath()
    // The 108-unit Android viewport mapped onto the tile (safe zone 18…90 → scaled up a little).
    let unit = 824 * s / 72, ox = tile.minX - 18 * unit, oy = tile.minY - 18 * unit
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * unit, y: oy + (108 - y) * unit) }
    ctx.move(to: p(35, 36)); ctx.addLine(to: p(42.5, 36)); ctx.addLine(to: p(54, 66.5)); ctx.addLine(to: p(65.5, 36))
    ctx.addLine(to: p(73, 36)); ctx.addLine(to: p(57.2, 76)); ctx.addLine(to: p(50.8, 76)); ctx.closePath()
    ctx.setFillColor(CGColor(red: 0xF3/255, green: 0xEF/255, blue: 0xE6/255, alpha: 1))
    ctx.fillPath()
    let c = p(76, 70), r = 4.5 * unit
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(CGColor(red: 0xE8/255, green: 0xA3/255, blue: 0x3D/255, alpha: 1))
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
