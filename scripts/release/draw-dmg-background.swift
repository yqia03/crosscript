#!/usr/bin/swift
// Native, offline artwork for the Finder installer; no third-party bitmap assets.
import AppKit
import Foundation

let width = 640
let height = 400

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: draw-dmg-background.swift OUTPUT.tiff\n", stderr)
    exit(2)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func draw(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
                              pixelsHigh: height * scale, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    // NSGraphicsContext already maps the representation's point size to its
    // pixel dimensions; scaling again would crop the Retina representation.
    // Draw in Finder content coordinates: origin at top left.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    color(0.985, 0.993, 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let wash = NSGradient(starting: color(1, 1, 1), ending: color(0.965, 0.990, 1))!
    wash.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    // Translucent radial washes leave the application icons readable.
    let mint = NSGradient(starting: color(0.67, 0.98, 0.82, 0.72), ending: color(0.90, 1, 0.96, 0))!
    mint.draw(fromCenter: NSPoint(x: 140, y: 450), radius: 0,
              toCenter: NSPoint(x: 140, y: 450), radius: 335, options: .drawsBeforeStartingLocation)
    let yellow = NSGradient(starting: color(0.94, 0.99, 0.64, 0.70), ending: color(1, 1, 0.94, 0))!
    yellow.draw(fromCenter: NSPoint(x: 465, y: 435), radius: 0,
                toCenter: NSPoint(x: 465, y: 435), radius: 280, options: .drawsBeforeStartingLocation)

    // A hand-drawn loop gives a clear, light directional cue.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 278, y: 199))
    arrow.curve(to: NSPoint(x: 312, y: 191), controlPoint1: NSPoint(x: 284, y: 187), controlPoint2: NSPoint(x: 313, y: 183))
    arrow.curve(to: NSPoint(x: 304, y: 207), controlPoint1: NSPoint(x: 334, y: 207), controlPoint2: NSPoint(x: 304, y: 220))
    arrow.curve(to: NSPoint(x: 357, y: 186), controlPoint1: NSPoint(x: 287, y: 178), controlPoint2: NSPoint(x: 334, y: 174))
    arrow.move(to: NSPoint(x: 349, y: 176))
    arrow.line(to: NSPoint(x: 358, y: 187))
    arrow.line(to: NSPoint(x: 344, y: 190))
    arrow.lineWidth = 1.8
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0.13, 0.20, 0.23).setStroke()
    arrow.stroke()

    // Flip text separately so glyphs stay upright in the top-left coordinate system.
    func centeredText(_ text: String, y: CGFloat, font: NSFont, ink: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: 0, y: y + size.height)
        context.scaleBy(x: 1, y: -1)
        string.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: 0))
        NSGraphicsContext.restoreGraphicsState()
    }
    centeredText("将 Crosscript 拖入「应用程序」文件夹", y: 300,
                 font: .systemFont(ofSize: 15), ink: color(0.34, 0.43, 0.40))
    centeredText("Drag Crosscript to Applications", y: 324,
                 font: .systemFont(ofSize: 10.5), ink: color(0.44, 0.51, 0.49))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let reps = [draw(scale: 1), draw(scale: 2)]
guard let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 1) else {
    fputs("Could not encode the installer background.\n", stderr)
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
