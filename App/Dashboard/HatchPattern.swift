import SwiftUI

/// A tiled diagonal-hatch fill: solid = actual, hatched = forecast, everywhere on the
/// dashboard. The tile is an image, so `color` is resolved for `colorScheme` first (a theme
/// colour differs between light and dark); callers pass their view's scheme, so the hatch is
/// redrawn when the appearance changes. If the image can't be rendered, falls back to a
/// 30%-opacity fill of the same color (the accepted fallback in the spec).
@MainActor
enum HatchPattern {
    static func style(_ color: Color, colorScheme: ColorScheme) -> AnyShapeStyle {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let resolved = Color(color.resolve(in: environment))
        let tile = Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height)); path.addLine(to: CGPoint(x: size.width, y: 0))
            path.move(to: CGPoint(x: -2, y: 2)); path.addLine(to: CGPoint(x: 2, y: -2))
            path.move(to: CGPoint(x: size.width - 2, y: size.height + 2)); path.addLine(to: CGPoint(x: size.width + 2, y: size.height - 2))
            context.stroke(path, with: .color(resolved), lineWidth: 1.5)
        }
        .frame(width: 6, height: 6)
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return AnyShapeStyle(color.opacity(0.3)) }
        return AnyShapeStyle(ImagePaint(image: Image(decorative: image, scale: 2), scale: 1))
    }
}
