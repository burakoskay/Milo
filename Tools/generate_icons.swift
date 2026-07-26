import Foundation
import AppKit

enum Style: String {
    case dark
    case light

    var backgroundColor: NSColor {
        switch self {
        case .dark: return .black
        case .light: return .white
        }
    }

    var foregroundColor: NSColor {
        switch self {
        case .dark: return .white
        case .light: return .black
        }
    }

    var borderColor: NSColor {
        switch self {
        case .dark: return NSColor.white.withAlphaComponent(0.18)
        case .light: return NSColor.black.withAlphaComponent(0.10)
        }
    }

    var highlightTop: NSColor {
        switch self {
        case .dark: return NSColor.white.withAlphaComponent(0.14)
        case .light: return NSColor.white.withAlphaComponent(0.55)
        }
    }

    var highlightBottom: NSColor {
        switch self {
        case .dark: return NSColor.white.withAlphaComponent(0.02)
        case .light: return NSColor.black.withAlphaComponent(0.04)
        }
    }
}

struct Args {
    var style: Style
    var outDir: URL
}

enum IconGenerationError: LocalizedError {
    case bitmapCreationFailed
    case graphicsContextCreationFailed

    var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed:
            return "Failed to create bitmap representation"
        case .graphicsContextCreationFailed:
            return "Failed to create graphics context"
        }
    }
}

func parseArgs() -> Args {
    var style: Style?
    var out: URL?

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--style":
            if let value = iterator.next(), let s = Style(rawValue: value) {
                style = s
            }
        case "--out":
            if let value = iterator.next() {
                out = URL(fileURLWithPath: value)
            }
        default:
            break
        }
    }

    guard let style else {
        fputs("Missing/invalid --style (dark|light)\n", stderr)
        exit(2)
    }
    guard let out else {
        fputs("Missing --out <path/to/icon.iconset>\n", stderr)
        exit(2)
    }

    return Args(style: style, outDir: out)
}

func ensureCleanDirectory(_ url: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        try fm.removeItem(at: url)
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
}

func makeBitmapContext(width: Int, height: Int) throws -> (NSBitmapImageRep, CGContext) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGenerationError.bitmapCreationFailed
    }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw IconGenerationError.graphicsContextCreationFailed
    }
    return (rep, ctx.cgContext)
}

func renderEmojiMask(size: Int, style: Style) throws -> NSImage {
    let (rep, cg) = try makeBitmapContext(width: size, height: size)

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    // Transparent background
    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Draw the emoji
    let emoji = "💀"
    let fontSize = CGFloat(size) * 0.70
    let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attr = NSAttributedString(
        string: emoji,
        attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ]
    )

    let textSize = attr.size()
    let textRect = CGRect(
        x: (CGFloat(size) - textSize.width) / 2.0,
        y: (CGFloat(size) - textSize.height) / 2.0 - CGFloat(size) * 0.02,
        width: textSize.width,
        height: textSize.height
    )

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    attr.draw(in: textRect)
    NSGraphicsContext.restoreGraphicsState()

    // Convert the colored emoji to a tinted monochrome mask with transparent holes.
    guard let src = rep.bitmapData else {
        return NSImage(size: NSSize(width: size, height: size))
    }

    guard let outRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGenerationError.bitmapCreationFailed
    }

    guard let dst = outRep.bitmapData else {
        return NSImage(size: NSSize(width: size, height: size))
    }

    let bytesPerRow = rep.bytesPerRow

    let fg = style.foregroundColor.usingColorSpace(.deviceRGB) ?? style.foregroundColor
    let fgR = UInt8((fg.redComponent * 255.0).rounded())
    let fgG = UInt8((fg.greenComponent * 255.0).rounded())
    let fgB = UInt8((fg.blueComponent * 255.0).rounded())

    for y in 0..<size {
        for x in 0..<size {
            let i = y * bytesPerRow + x * 4
            let r = Double(src[i + 0]) / 255.0
            let g = Double(src[i + 1]) / 255.0
            let b = Double(src[i + 2]) / 255.0
            let a = Double(src[i + 3]) / 255.0

            if a <= 0.0001 {
                dst[i + 0] = 0
                dst[i + 1] = 0
                dst[i + 2] = 0
                dst[i + 3] = 0
                continue
            }

            // Luminance-based hole mask: darker pixels fade out (eye sockets, mouth).
            let lum = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            let holeFactor = max(0.0, min(1.0, (lum - 0.18) / 0.82))
            let outA = UInt8((a * holeFactor * 255.0).rounded())

            dst[i + 0] = fgR
            dst[i + 1] = fgG
            dst[i + 2] = fgB
            dst[i + 3] = outA
        }
    }

    let img = NSImage(size: NSSize(width: size, height: size))
    img.addRepresentation(outRep)
    return img
}

func makeIconImage(size: Int, style: Style) throws -> NSImage {
    let (rep, cg) = try makeBitmapContext(width: size, height: size)

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    style.backgroundColor.setFill()
    bgPath.fill()

    // Subtle "liquid glass" highlight.
    if let gradient = NSGradient(colors: [style.highlightTop, style.highlightBottom]) {
        gradient.draw(in: bgPath, angle: 90)
    }

    style.borderColor.setStroke()
    bgPath.lineWidth = max(1.0, CGFloat(size) * 0.01)
    bgPath.stroke()

    let skullSize = Int(Double(size) * 0.68)
    let skull = try renderEmojiMask(size: skullSize, style: style)

    let skullRect = NSRect(
        x: (CGFloat(size) - CGFloat(skullSize)) / 2.0,
        y: (CGFloat(size) - CGFloat(skullSize)) / 2.0 + CGFloat(size) * 0.01,
        width: CGFloat(skullSize),
        height: CGFloat(skullSize)
    )

    skull.draw(in: skullRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: NSSize(width: size, height: size))
    img.addRepresentation(rep)
    return img
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
        let data = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "generate_icons", code: 1)
    }
    try data.write(to: url)
}

let args = parseArgs()

let files: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

do {
    try ensureCleanDirectory(args.outDir)

    for (name, size) in files {
        let icon = try makeIconImage(size: size, style: args.style)
        try writePNG(icon, to: args.outDir.appendingPathComponent(name))
    }
} catch {
    fputs("Failed: \(error)\n", stderr)
    exit(1)
}
