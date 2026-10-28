import SwiftUI

/// Liquid Glass, applied only where the system actually has it.
///
/// Every glass API — `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`
/// — is macOS 26.0 or newer, and this app still runs on macOS 13. Rather than
/// raise the floor (which would stop the updater's own builds launching on
/// older Macs), each one sits behind an availability check with a material
/// fallback chosen to look deliberate on the older systems rather than broken.
extension View {

    /// Glass on macOS 26+, a material of the same shape below it.
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    /// For controls sitting on top of glass.
    @ViewBuilder
    func liquidGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Wraps sibling glass elements so the system can blend them into one another
/// instead of stacking separate panes. A plain passthrough before macOS 26.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum LiquidGlass {
    /// Whether the running system has the real thing. Used to tune padding and
    /// corner radii, which want to be a little more generous under glass.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
