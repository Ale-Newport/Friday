#!/usr/bin/env swift
// Renders docs/assets/social-preview.png (1280×640, GitHub's social preview size) from the real app icon and a real
// screenshot of Friday's chat window.  Usage: swift Scripts/generate-social-preview.swift <chat-screenshot.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let shot = NSImage(contentsOfFile: args[1]),
      let icon = NSImage(contentsOfFile: "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png") else {
    print("usage: swift Scripts/generate-social-preview.swift <chat-screenshot.png> <out.png> (run from the repository root)"); exit(2)
}
let size = NSSize(width: 1280, height: 640)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: deep blue-violet gradient with a soft glow behind the screenshot.
NSGradient(colors: [NSColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1), NSColor(red: 0.10, green: 0.08, blue: 0.22, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -20)
NSGradient(colors: [NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 0.35), .clear])!
    .draw(fromCenter: NSPoint(x: 960, y: 330), radius: 0, toCenter: NSPoint(x: 960, y: 330), radius: 420, options: [])

// Left column: icon, name, tagline, chips.
icon.draw(in: NSRect(x: 72, y: 418, width: 132, height: 132))
func text(_ string: String, _ font: NSFont, _ color: NSColor, at point: NSPoint, width: CGFloat = 560) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    // `point` is the bottom-left of the text block; size the rect to the text so wrapped lines grow upwards from it.
    let height = ceil(attributed.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
    attributed.draw(with: NSRect(x: point.x, y: point.y, width: width, height: height), options: [.usesLineFragmentOrigin])
}
text("Friday", .systemFont(ofSize: 88, weight: .heavy), .white, at: NSPoint(x: 220, y: 420))
text("A bilingual voice assistant for your Mac that actually does things.", .systemFont(ofSize: 34, weight: .semibold),
     NSColor(white: 0.92, alpha: 1), at: NSPoint(x: 72, y: 268), width: 560)
var x: CGFloat = 72
for chip in ["Local wake word", "136 Mac actions", "Chrome agent", "ES · EN"] {
    let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    let w = (chip as NSString).size(withAttributes: [.font: font]).width + 24
    let rect = NSRect(x: x, y: 150, width: w, height: 36)
    NSColor(white: 1, alpha: 0.10).setFill(); NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
    text(chip, font, NSColor(red: 0.75, green: 0.85, blue: 1, alpha: 1), at: NSPoint(x: x + 12, y: 158))
    x += w + 10
}
text("Swift · SwiftUI · on-device speech · open source (MIT)", .systemFont(ofSize: 20), NSColor(white: 0.65, alpha: 1), at: NSPoint(x: 72, y: 80))

// Right column: the real chat window, rounded, with a shadow.
let frame = NSRect(x: 690, y: 64, width: 540, height: 540 * shot.size.height / shot.size.width)
let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowColor = NSColor(white: 0, alpha: 0.6); shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSColor.black.setFill(); NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18).addClip()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
