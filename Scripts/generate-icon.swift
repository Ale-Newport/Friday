// Generates the Friday app icon (an orb with pulse rings) into an .appiconset directory.
//   swift Scripts/generate-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824-pt rounded square centred in the 1024-pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Background gradient.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.05, green: 0.04, blue: 0.16, alpha: 1),
            CGColor(red: 0.16, green: 0.10, blue: 0.45, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Soft glow behind the orb.
    let glow = CGGradient(
        colorsSpace: space,
        colors: [CGColor(red: 0.2, green: 0.7, blue: 1, alpha: 0.55), CGColor(red: 0.2, green: 0.7, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])

    // Pulse rings.
    for (radius, alpha, width) in [(215.0, 0.55, 9.0), (290.0, 0.32, 7.0), (365.0, 0.16, 5.0)] {
        context.setStrokeColor(CGColor(red: 0.45, green: 0.9, blue: 1, alpha: alpha))
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: 512 - radius, y: 512 - radius, width: radius * 2, height: radius * 2))
    }

    // The orb.
    let orb = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0.45, green: 0.95, blue: 1, alpha: 1),
            CGColor(red: 0.08, green: 0.45, blue: 1, alpha: 1),
        ] as CFArray,
        locations: [0, 0.35, 1]
    )!
    context.saveGState()
    context.addEllipse(in: CGRect(x: 512 - 150, y: 512 - 150, width: 300, height: 300))
    context.clip()
    context.drawRadialGradient(orb, startCenter: CGPoint(x: 470, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 165, options: [.drawsAfterEndLocation])
    context.restoreGState()

    // Top edge highlight on the tile.
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

struct Slot { let points: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }
var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)@\(slot.scale)x.png"
    try drawIcon(pixels: slot.points * slot.scale).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.points)x\(slot.points)", "scale": "\(slot.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icon images to \(outputDirectory.path)")
