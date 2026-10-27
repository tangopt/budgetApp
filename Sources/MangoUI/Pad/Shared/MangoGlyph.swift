import SwiftUI

/// The Mango fruit with its stem and leaf, drawn as plain paths from the app icon's master artwork
/// (`docs/design/mango-icon.svg`, 1024 × 1024 viewBox, minus the icon's blue background, shadow and shading).
struct MangoGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 740
            // The artwork's fruit, stem and leaf fill x 270…872, y 170…885: centred on (571, 527).
            let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: scale, y: scale).translatedBy(x: -571, y: -527)
            context.fill(MangoFruit().path(in: .zero).applying(transform), with: .linearGradient(
                Gradient(colors: [Color(red: 0.85, green: 0.23, blue: 0.10), Color(red: 0.93, green: 0.42, blue: 0.11),
                                  Color(red: 0.98, green: 0.64, blue: 0.12), Color(red: 1.0, green: 0.83, blue: 0.23)]),
                startPoint: CGPoint(x: size.width * 0.8, y: size.height), endPoint: CGPoint(x: size.width * 0.2, y: 0)))
            context.stroke(MangoStem().path(in: .zero).applying(transform), with: .color(Color(red: 0.48, green: 0.29, blue: 0.13)),
                           style: StrokeStyle(lineWidth: 28 * scale, lineCap: .round))
            context.fill(MangoLeaf().path(in: .zero).applying(transform), with: .linearGradient(
                Gradient(colors: [Color(red: 0.37, green: 0.70, blue: 0.24), Color(red: 0.16, green: 0.43, blue: 0.15)]),
                startPoint: CGPoint(x: size.width * 0.5, y: 0), endPoint: CGPoint(x: size.width, y: size.height * 0.5)))
        }
        .accessibilityHidden(true)
    }
}

private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

struct MangoFruit: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: point(585, 300))
        p.addCurve(to: point(790, 540), control1: point(720, 300), control2: point(800, 400))
        p.addCurve(to: point(580, 840), control1: point(780, 680), control2: point(700, 790))
        p.addCurve(to: point(270, 820), control1: point(470, 885), control2: point(330, 880))
        p.addCurve(to: point(290, 650), control1: point(220, 770), control2: point(230, 700))
        p.addCurve(to: point(370, 500), control1: point(350, 600), control2: point(360, 560))
        p.addCurve(to: point(585, 300), control1: point(385, 380), control2: point(460, 300))
        p.closeSubpath()
        return p
    }
}

struct MangoStem: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: point(588, 306))
        p.addCurve(to: point(516, 170), control1: point(584, 250), control2: point(562, 204))
        return p
    }
}

struct MangoLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: point(592, 270))
        p.addCurve(to: point(846, 358), control1: point(680, 214), control2: point(800, 246))
        p.addCurve(to: point(846, 562), control1: point(872, 428), control2: point(862, 508))
        p.addCurve(to: point(662, 420), control1: point(800, 502), control2: point(722, 470))
        p.addCurve(to: point(592, 270), control1: point(616, 382), control2: point(596, 324))
        p.closeSubpath()
        return p
    }
}
