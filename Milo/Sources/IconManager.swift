import Cocoa

enum IconManager {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func applyAppIcon(for appearance: NSAppearance) {
        let resource = isDark(appearance) ? "MiloDark" : "MiloLight"
        if let url = Bundle.main.url(forResource: resource, withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = img
        } else {
            // Fallback: draw a simple procedural icon
            NSApplication.shared.applicationIconImage = makeFallbackIcon(dark: isDark(appearance))
        }
    }

    /// Draws a simple 128×128 fallback icon when .icns assets are missing.
    private static func makeFallbackIcon(dark: Bool) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()

        let bg: NSColor = dark ? .black : .white
        let fg: NSColor = dark ? .white : .black

        bg.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 24, yRadius: 24).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 80, weight: .bold),
            .foregroundColor: fg
        ]
        let letter = NSAttributedString(string: "M", attributes: attrs)
        let textSize = letter.size()
        let origin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        letter.draw(at: origin)

        image.unlockFocus()
        return image
    }
}
