import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixel = size * scale
        let image = NSImage(size: NSSize(width: pixel, height: pixel))
        image.lockFocus()
        let p = CGFloat(pixel)
        NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p*0.08, y: p*0.08, width: p*0.84, height: p*0.84), xRadius: p*0.21, yRadius: p*0.21).fill()
        NSColor(calibratedWhite: 0.98, alpha: 1).setStroke()
        let path = NSBezierPath(); path.lineWidth = p*0.07; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: p*0.28, y: p*0.50)); path.line(to: NSPoint(x: p*0.42, y: p*0.36)); path.line(to: NSPoint(x: p*0.68, y: p*0.64)); path.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
