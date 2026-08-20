import SwiftUI

enum GlassSurfacePresentation: Equatable {
    case liquidGlass
    case translucentMaterial
    case opaque
}

struct GlassAppearance: Equatable {
    let surface: GlassSurfacePresentation
    let usesHighContrastBorder: Bool
}

enum GlassAppearancePolicy {
    static func resolve(
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> GlassAppearance {
        let surface: GlassSurfacePresentation

        if reduceTransparency {
            surface = .opaque
        } else if supportsLiquidGlass {
            surface = .liquidGlass
        } else {
            surface = .translucentMaterial
        }

        return GlassAppearance(
            surface: surface,
            usesHighContrastBorder: increaseContrast
        )
    }
}

enum GlassDesign {
    static let canvasPadding: CGFloat = 12
    static let contentPadding: CGFloat = 24
    static let cardCornerRadius: CGFloat = 20
    static let chromeCornerRadius: CGFloat = 24
    static let compactCornerRadius: CGFloat = 14
    static let contentMaxWidth: CGFloat = 1_120
}

struct GlassCanvasBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.16),
                        Color.cyan.opacity(0.07),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 420, height: 420)
                    .blur(radius: 100)
                    .offset(x: 280, y: -240)

                Circle()
                    .fill(Color.mint.opacity(0.09))
                    .frame(width: 360, height: 360)
                    .blur(radius: 110)
                    .offset(x: -320, y: 260)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct AdaptiveGlassEffectContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let tint: Color?
    let isInteractive: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let appearance = GlassAppearancePolicy.resolve(
            supportsLiquidGlass: supportsLiquidGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )

#if compiler(>=6.2)
        if #available(macOS 26.0, *), appearance.surface == .liquidGlass {
            content
                .glassEffect(
                    glass(tint: tint, isInteractive: isInteractive),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .glassSurfaceBoundary(appearance, cornerRadius: cornerRadius)
        } else {
            fallbackSurface(content, appearance: appearance)
        }
#else
        fallbackSurface(content, appearance: appearance)
#endif
    }

    private var supportsLiquidGlass: Bool {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
#endif
        return false
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func glass(tint: Color?, isInteractive: Bool) -> Glass {
        let base = Glass.regular.tint(tint)
        return isInteractive ? base.interactive() : base
    }
#endif

    @ViewBuilder
    private func fallbackSurface(
        _ content: Content,
        appearance: GlassAppearance
    ) -> some View {
        switch appearance.surface {
        case .opaque:
            content
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassSurfaceBoundary(appearance, cornerRadius: cornerRadius)
        case .liquidGlass, .translucentMaterial:
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassSurfaceBoundary(appearance, cornerRadius: cornerRadius)
        }
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
#else
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
#endif
    }
}

private extension View {
    func glassSurfaceBoundary(
        _ appearance: GlassAppearance,
        cornerRadius: CGFloat
    ) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(appearance.usesHighContrastBorder ? 0.30 : 0.10),
                    lineWidth: appearance.usesHighContrastBorder ? 1.5 : 0.75
                )
        }
        .shadow(
            color: Color.black.opacity(appearance.usesHighContrastBorder ? 0.14 : 0.08),
            radius: 14,
            y: 6
        )
    }
}

extension View {
    func adaptiveGlassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat = GlassDesign.cardCornerRadius
    ) -> some View {
        modifier(
            AdaptiveGlassSurfaceModifier(
                tint: tint,
                isInteractive: interactive,
                cornerRadius: cornerRadius
            )
        )
    }

    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        modifier(AdaptiveGlassButtonModifier(isProminent: prominent))
    }
}
