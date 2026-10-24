import SwiftUI
import BudgetCore

/// The one thing an empty state lets the person do.
public struct EmptyStateAction {
    public let title: String
    public let perform: () -> Void

    public init(_ title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// "Nothing here" (iPhone spec §3.9): an SF Symbol, a title, one sentence and at most one action, centred. The
/// sentence wraps as prose; the figures in it stay whole.
public struct EmptyState: View {
    public let symbol: String
    public let title: String
    public let message: String
    public let action: EmptyStateAction?

    public init(symbol: String, title: String, message: String, action: EmptyStateAction? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message.figuresUnbroken)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }
}
