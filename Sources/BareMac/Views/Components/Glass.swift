import SwiftUI

/// The shapes BareMac draws glass in.
enum GlassShape {
    case rounded(CGFloat)
    case capsule
    case circle

    var shape: AnyShape {
        switch self {
        case let .rounded(radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .capsule: AnyShape(Capsule(style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }
}

/// Liquid Glass on macOS 26 and later. On earlier systems a material with a soft
/// specular rim stands in, and with Reduce Transparency on it becomes a solid,
/// high-contrast panel.
struct GlassBackground: ViewModifier {
    var shape: GlassShape
    var tint: Color?
    var interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(glass, in: shape.shape)
        } else {
            content
                .background {
                    if reduceTransparency {
                        shape.shape.fill(Color(nsColor: .controlBackgroundColor))
                    } else {
                        shape.shape.fill(.regularMaterial)
                        if let tint { shape.shape.fill(tint.opacity(0.12)) }
                    }
                }
                .overlay {
                    shape.shape.stroke(rim, lineWidth: 1)
                }
                .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.08), radius: 12, y: 4)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.35)) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    private var rim: some ShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .separatorColor))
        }
        let top = Color.white.opacity(colorScheme == .dark ? 0.28 : 0.85)
        let bottom = Color.white.opacity(colorScheme == .dark ? 0.04 : 0.15)
        return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
    }
}

extension View {
    func glass(_ shape: GlassShape = .rounded(20), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
    }

    /// The confident, filled button style (glass on macOS 26).
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The quiet, secondary button style (glass on macOS 26).
    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Lets glass shapes morph into each other inside a `GlassGroup`.
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend and morph (macOS 26); a plain container before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A soft, colourful backdrop for glass to sit on. It stays calm in both modes and
/// switches off under Reduce Transparency.
struct Backdrop: View {
    var tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            let strength = colorScheme == .dark ? 0.32 : 0.22
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [tint.opacity(strength), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Color.purple.opacity(strength * 0.7), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color.teal.opacity(strength * 0.6), .clear], center: .bottom, startRadius: 0, endRadius: 700)
            }
        }
    }
}

extension View {
    /// Extends a backdrop under the floating glass sidebar on macOS 26.
    @ViewBuilder
    func extendsUnderSidebar() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}
