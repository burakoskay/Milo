import SwiftUI
import AppKit

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
