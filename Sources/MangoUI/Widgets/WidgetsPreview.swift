import SwiftUI
import BudgetCore

/// The Net worth and Payday widgets' tiles from a snapshot, in the app's own frame (the snapshot harness's `widgets-preview` route; the
/// extension draws the real ones, with the same `WidgetPresentation` words). Figures sit in tiles of the widgets' size.
public struct WidgetsPreview: View {
    let snapshot: WidgetSnapshot
    let today: Date

    public init(snapshot: WidgetSnapshot, today: Date) {
        self.snapshot = snapshot
        self.today = today
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                tile("Net worth", WidgetPresentation.netWorthWholeText(snapshot))
            }
            HStack(spacing: 16) {
                Circle().fill(.fill.tertiary).frame(width: 76, height: 76)
                    .overlay {
                        VStack(spacing: 0) {
                            Text("Payday").mangoFont(.caption2).foregroundStyle(.secondary)
                            Text(WidgetPresentation.paydayText(snapshot, on: today))
                                .mangoFont(MangoType.footnote.weight(.semibold).figure())
                        }
                    }
                Text(WidgetPresentation.emptyText).mangoFont(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ title: String, _ figure: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).mangoFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(figure).mangoFont(.figureL)
        }
        .padding()
        .frame(width: 155, height: 155, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22))
    }
}
