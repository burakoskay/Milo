import SwiftUI
import AppKit

// MARK: - Menu Bar Panel Geometry

/// Geometry for the menu bar panel and every sheet presented inside it.
///
/// These were previously repeated as literals across six views and the app delegate, which let
/// the panel drift narrower than its own header and footer and clip them at both edges.
enum MiloPanelMetrics {
    static let width: CGFloat = 400
    static let height: CGFloat = 560
}

// MARK: - Rounded Sheet Window

/// Rounds the corners of the `NSWindow` that macOS creates for a SwiftUI sheet.
///
/// The status bar panel masks its own content view, but a sheet is a separate window layered on
/// top and is not clipped by that mask, so sheets rendered square-cornered over a rounded panel.
private struct RoundedSheetWindow: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is in the hierarchy, so this must run a turn later.
        DispatchQueue.main.async {
            applyRounding(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyRounding(to: nsView.window)
    }

    private func applyRounding(to window: NSWindow?) {
        guard let window, let contentView = window.contentView else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        // The content view is not the outermost layer: AppKit's frame view sits behind it and
        // paints the square backdrop that remains visible at the corners. Both must be masked.
        for view in [contentView, contentView.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

extension View {
    /// Applies the panel's corner treatment to a sheet presented over it.
    func roundedSheetWindow(cornerRadius: CGFloat = 16) -> some View {
        background(RoundedSheetWindow(cornerRadius: cornerRadius))
    }
}

// MARK: - Liquid Glass Aware Visual Effect

/// Reads the user's Liquid Glass preference and maps it to the correct NSVisualEffectView.Material.
/// - "Auto": uses `.underWindowBackground` which follows the system Clear/Tinted setting.
/// - "Clear": uses `.popover` which is always clear/transparent.
/// - "Tinted": uses `.underWindowBackground` which tints with the desktop wallpaper.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    /// Resolves the correct material based on the user's Liquid Glass AppStorage preference.
    static func resolvedMaterial() -> NSVisualEffectView.Material {
        let pref = UserDefaults.standard.string(forKey: "Milo.liquidGlass") ?? "Auto"
        switch pref {
        case "Clear":
            return .popover
        case "Tinted":
            return .underWindowBackground
        default:
            // Auto: underWindowBackground follows system Clear/Tinted preference
            return .underWindowBackground
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Convenience initializer for Liquid Glass

extension VisualEffectBlur {
    /// Creates a VisualEffectBlur that automatically respects the user's Liquid Glass preference.
    init(liquidGlass: Bool = true, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow, state: NSVisualEffectView.State = .active) {
        if liquidGlass {
            self.material = VisualEffectBlur.resolvedMaterial()
        } else {
            self.material = .popover
        }
        self.blendingMode = blendingMode
        self.state = state
    }
}

// MARK: - Glass Card Container

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        // Without this the card shrinks to its content, so a section with short controls
        // renders narrower and centred while its neighbours fill the column.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Stat Card (used in StatsView)

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
            }

            Text(value)
                .font(.title.weight(.bold))

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Reusable Toast

struct ToastView: View {
    let icon: String
    let iconColor: Color
    let message: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Sheet Header

struct SheetHeader: View {
    let title: String
    let subtitle: String
    let dismiss: DismissAction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(16)
    }
}

// MARK: - Hover Highlight Modifier

struct HoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlight())
    }
}
