import SwiftUI

/// How a figure keeps to one line (iPhone spec §4, "no figure ever wraps or truncates").
public enum FigureFit: Equatable, Sendable {
    /// At its natural width: it never wraps or truncates, and the layout around it gives way (a label beside it
    /// wraps, a row stacks). The default.
    case natural
    /// In a slot whose width can't give way (a tile, a fixed column): one line that shrinks down to `minimumScale`
    /// before it would truncate.
    case shrink(minimumScale: CGFloat = FigureFit.defaultMinimumScale)

    /// How far a figure in a fixed width may shrink by default.
    public static let defaultMinimumScale: CGFloat = 0.7

    /// The smallest scale it may be drawn at: 1 at its natural width.
    public var minimumScale: CGFloat {
        switch self {
        case .natural: 1
        case let .shrink(scale): scale
        }
    }
}

extension Text {
    /// A figure that isn't an amount (`MoneyText`) or a day (`DateText`): a count ("1,234 days"), a percentage, a
    /// rate, "3 of 5". One line, tabular digits, its natural width or a slight shrink in a fixed width; the wrap
    /// probe checks it in the snapshot harness and names it by its words and source line.
    @MainActor
    public func figureText(_ fit: FigureFit = .natural, file: StaticString = #fileID, line: UInt = #line) -> some View {
        monospacedDigit()
            .modifier(FigureFontModifier())
            .modifier(FigureFitModifier(fit: fit, kind: "figure", text: WrapProbeRegistry.describe(self),
                                        source: "\(file):\(line)"))
    }
}

/// One line at its natural width, or one line shrinking to the fit's minimum; reported to the wrap probe.
struct FigureFitModifier: ViewModifier {
    let fit: FigureFit
    let kind: String
    let text: String?
    let source: String?
    /// Set by a stacked `FigureRow`: there a natural figure may shrink to fit the row's width.
    @Environment(\.stackedFigureRowSize) private var stackedRowSize

    func body(content: Content) -> some View {
        switch stackedRowSize.map({ AmountRowLayout.fit(fit, at: $0) }) ?? fit {
        case .natural:
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .wrapProbe(kind, text: text, source: source, minimumScale: 1)
        case let .shrink(minimumScale):
            content
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
                .wrapProbe(kind, text: text, source: source, minimumScale: minimumScale)
        }
    }
}

extension EnvironmentValues {
    /// The Dynamic Type size of the stacked `FigureRow` a figure is in (nil: not in one).
    @Entry var stackedFigureRowSize: DynamicTypeSize?
}
