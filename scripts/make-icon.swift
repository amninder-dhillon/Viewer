import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let shape = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.46, blue: 0.34, alpha: 1), ending: NSColor(calibratedRed: 0.10, green: 0.27, blue: 0.20, alpha: 1))!.draw(in: shape, angle: -90)
        let frame = NSBezierPath(roundedRect: NSRect(x: 202, y: 270, width: 620, height: 484), xRadius: 40, yRadius: 40)
        NSColor(calibratedWhite: 0.95, alpha: 1).setStroke()
        frame.lineWidth = 25
        frame.stroke()
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 655, y: 592, width: 76, height: 76)).fill()
        let mountains = NSBezierPath()
        mountains.move(to: NSPoint(x: 248, y: 318))
        mountains.line(to: NSPoint(x: 425, y: 550))
        mountains.line(to: NSPoint(x: 563, y: 384))
        mountains.line(to: NSPoint(x: 652, y: 493))
        mountains.line(to: NSPoint(x: 776, y: 318))
        mountains.close()
        mountains.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

// Package PNG representations directly into the standard ICNS container.
// This also works on build machines without a populated Launch Services database.
func block(_ type: String, _ payload: Data) -> Data {
    var data = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
]
var payload = Data()
for (type, name) in representations {
    payload.append(block(type, try Data(contentsOf: directory.appendingPathComponent(name))))
}
try block("icns", payload).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
