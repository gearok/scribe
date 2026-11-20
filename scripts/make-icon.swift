import AppKit
import Foundation

// One vector drawing supplies both the monochrome in-app symbol and every Dock icon resolution.
func drawFeather(in rect: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.translateBy(x: rect.minX, y: rect.minY)
    NSGraphicsContext.current?.cgContext.scaleBy(x: rect.width / 24, y: rect.height / 24)

    // A tapered plume, cut barbs, and a long exposed nib read as a writing quill at Dock sizes.
    let plume = NSBezierPath()
    plume.move(to: NSPoint(x: 10.2, y: 8.6))
    plume.curve(to: NSPoint(x: 8.5, y: 13.5), controlPoint1: NSPoint(x: 8.7, y: 9.3), controlPoint2: NSPoint(x: 8.0, y: 11.3))
    plume.curve(to: NSPoint(x: 14, y: 21.2), controlPoint1: NSPoint(x: 9.1, y: 16.9), controlPoint2: NSPoint(x: 11.7, y: 19.9))
    plume.curve(to: NSPoint(x: 21, y: 23), controlPoint1: NSPoint(x: 16.4, y: 22.5), controlPoint2: NSPoint(x: 19.1, y: 22.6))
    plume.curve(to: NSPoint(x: 20.3, y: 17.2), controlPoint1: NSPoint(x: 21.4, y: 21.1), controlPoint2: NSPoint(x: 21.3, y: 19.1))
    plume.line(to: NSPoint(x: 18.5, y: 17.4))
    plume.line(to: NSPoint(x: 19.6, y: 15.8))
    plume.curve(to: NSPoint(x: 16.1, y: 12.1), controlPoint1: NSPoint(x: 18.9, y: 14.4), controlPoint2: NSPoint(x: 17.5, y: 12.9))
    plume.line(to: NSPoint(x: 14.6, y: 12.4))
    plume.line(to: NSPoint(x: 15.1, y: 11))
    plume.curve(to: NSPoint(x: 11.6, y: 8.8), controlPoint1: NSPoint(x: 13.8, y: 9.9), controlPoint2: NSPoint(x: 12.6, y: 9.3))
    plume.line(to: NSPoint(x: 10.9, y: 10.2))
    plume.line(to: NSPoint(x: 10.2, y: 8.6))
    plume.close()

    // The transparent spine stays crisp in the template PDF as well as the app icon.
    let spine = NSBezierPath()
    spine.move(to: NSPoint(x: 10.6, y: 10.3))
    spine.curve(to: NSPoint(x: 19.8, y: 22), controlPoint1: NSPoint(x: 13.1, y: 14.3), controlPoint2: NSPoint(x: 16.7, y: 18.9))
    spine.curve(to: NSPoint(x: 10.6, y: 10.3), controlPoint1: NSPoint(x: 16.2, y: 19.1), controlPoint2: NSPoint(x: 12.7, y: 14.2))
    spine.close()
    plume.append(spine)
    plume.windingRule = .evenOdd
    color.setFill()
    plume.fill()

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 2.8, y: 1))
    shaft.curve(to: NSPoint(x: 10.8, y: 11), controlPoint1: NSPoint(x: 4.4, y: 4.6), controlPoint2: NSPoint(x: 7.7, y: 8.7))
    shaft.line(to: NSPoint(x: 11.5, y: 9.9))
    shaft.curve(to: NSPoint(x: 2.8, y: 1), controlPoint1: NSPoint(x: 8.6, y: 6.6), controlPoint2: NSPoint(x: 5.3, y: 3.1))
    shaft.close()
    shaft.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let symbolURL = root.appendingPathComponent("Sources/Scribe/Resources/Feather.pdf")
if !FileManager.default.fileExists(atPath: symbolURL.path) || CommandLine.arguments.contains("--refresh-symbol") {
    try FileManager.default.createDirectory(at: symbolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 24, height: 24)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawFeather(in: box, color: .black)
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: symbolURL)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let unit = CGFloat(size) / 1024
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: NSRect(x: 70 * unit, y: 70 * unit, width: 884 * unit, height: 884 * unit),
                     xRadius: 195 * unit, yRadius: 195 * unit).fill()
        drawFeather(in: NSRect(x: 202 * unit, y: 220 * unit, width: 620 * unit, height: 620 * unit),
                    color: .black)
        let ink = NSBezierPath()
        ink.move(to: NSPoint(x: 278 * unit, y: 238 * unit))
        ink.curve(to: NSPoint(x: 495 * unit, y: 205 * unit),
                  controlPoint1: NSPoint(x: 382 * unit, y: 166 * unit), controlPoint2: NSPoint(x: 417 * unit, y: 246 * unit))
        ink.curve(to: NSPoint(x: 724 * unit, y: 214 * unit),
                  controlPoint1: NSPoint(x: 566 * unit, y: 166 * unit), controlPoint2: NSPoint(x: 639 * unit, y: 217 * unit))
        ink.lineWidth = 17 * unit
        ink.lineCapStyle = .round
        NSColor.black.setStroke()
        ink.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(pointSize)x\(pointSize)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
