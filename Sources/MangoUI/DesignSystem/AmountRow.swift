import SwiftUI

/// When a row puts its figure under its label instead of beside it, and how the figure fits there.
public enum AmountRowLayout {
    /// At accessibility Dynamic Type sizes (iPhone spec §4): side by side there'd be no room for the label.
    public static func stacks(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// A figure's fit in a row at `size`: stacked, a natural figure has the row's whole width and may shrink to the
    /// minimum (0.7) rather than run past it (ruling, fix round 1: no figure overflows at any size); side by side, as
    /// given.
    public static func fit(_ fit: FigureFit, at size: DynamicTypeSize) -> FigureFit {
        stacks(at: size) && fit == .natural ? .shrink() : fit
    }
}

/// A label (and an optional secondary line) with a figure: side by side, the figure trailing at its natural width
/// and the label wrapping beside it; stacked at accessibility sizes, the figure under the label, shrinking to fit
/// the row if it must. At least 44 pt tall.
public struct FigureRow<Figure: View>: View {
    public let label: String
    public let secondary: String?
    public let figure: Figure
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(label: String, secondary: String? = nil, @ViewBuilder figure: () -> Figure) {
        self.label = label
        self.secondary = secondary
        self.figure = figure()
    }

    public var body: some View {
        Group {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 4) {
                    labels
                    figure
                        .environment(\.stackedFigureRowSize, dynamicTypeSize)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                    figure
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let secondary {
                Text(secondary.figuresUnbroken)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A `FigureRow` whose figure is an amount.
public struct AmountRow: View {
    public let label: String
    public let secondary: String?
    public let amount: MoneyText

    public init(label: String, secondary: String? = nil, amount: MoneyText) {
        self.label = label
        self.secondary = secondary
        self.amount = amount
    }

    public var body: some View {
        FigureRow(label: label, secondary: secondary) { amount }
    }
}
