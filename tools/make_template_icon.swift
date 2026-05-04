import Cocoa

guard CommandLine.arguments.count == 3 else {
    print("Usage: make_template_icon <input> <output>")
    exit(1)
}
let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]

guard let image = NSImage(contentsOfFile: input) else {
    print("Failed to load \(input)")
    exit(1)
}

// Draw the image into a bitmap context
let width = Int(image.size.width)
let height = Int(image.size.height)
let rep = NSBitmapImageRep(
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
    print("Failed to create bitmap representation")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Draw original image
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))

// We want to make a proper template.
// A simple way is to use the alpha channel and create a filled silhouette, but for a parrot maybe a luma-based template is better?
// Let's just make it a pure black silhouette based on the alpha channel.
// Wait, if it's a solid silhouette, it's just a blob. Let's do luma extraction: we want darker areas to be opaque black, lighter areas to be transparent (or vice versa).
// Actually, Apple's guidelines suggest a solid silhouette with transparent cutouts for details.
// Let's just convert it to grayscale and use that as the alpha channel, then output a black image with that alpha.

for y in 0..<height {
    for x in 0..<width {
        guard let color = rep.colorAt(x: x, y: y) else {
            continue
        }
        let alpha = color.alphaComponent
        if alpha > 0 {
            // Calculate luminance
            let luma = (0.299 * color.redComponent) + (0.587 * color.greenComponent) + (0.114 * color.blueComponent)
            // For a black and white template, darker colors in the original should probably be more opaque
            // Let's map luma to alpha. So 1.0 (white) -> transparent, 0.0 (black) -> opaque.
            // And multiply by original alpha.
            let newAlpha = (1.0 - luma) * alpha
            rep.setColor(NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: newAlpha), atX: x, y: y)
        }
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    print("Failed to get PNG data")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: output))
} catch {
    print("Failed to write \(output): \(error.localizedDescription)")
    exit(1)
}
print("Template icon generated at \(output)")
