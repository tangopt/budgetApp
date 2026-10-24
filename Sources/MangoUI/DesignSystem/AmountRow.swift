import SwiftUI

/// When a row puts its amount under its label instead of beside it.
public enum AmountRowLayout {
    /// At accessibility Dynamic Type sizes (iPhone spec §4): side by side there'd be no room for the label.
    public static func stacks(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }
}

/// A label (and an optional secondary line) with an amount: side by side, the amount trailing at its natural
/// width and the label wrapping beside it; stacked, the amount under the label, at accessibility sizes. At least
/// 44 pt tall.
public struct AmountRow: View {
    public let label: String
    public let secondary: String?
    public let amount: MoneyText
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(label: String, secondary: String? = nil, amount: MoneyText) {
        self.label = label
        self.secondary = secondary
        self.amount = amount
    }

    public var body: some View {
        Group {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 4) {
                    labels
                    amount
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                    amount
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
