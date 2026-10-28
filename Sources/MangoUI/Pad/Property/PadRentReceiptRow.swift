import SwiftUI
import BudgetCore

/// One rent receipt in the Tenancies list (step 10, Task 13): its month, receipt number and rent period, the rent, its status
/// (Paid, Part paid, Not matched, Cancelled: the word, never the colour alone) and the icon buttons its state offers. Tapping
/// the row opens the receipt in the document panel; a refusal of an action shows under the row.
struct PadRentReceiptRow: View {
    let receipt: PadTenanciesModel.Receipt
    let isSelected: Bool
    /// The actions drawn as icons in the row (a subset of what the receipt offers).
    let actions: [PadTenanciesAction]
    let write: PadWriteModel
    let select: () -> Void
    let perform: (PadTenanciesAction) -> Void
    @Environment(\.phoneTheme) private var theme

    static let rowActions: [PadTenanciesAction] = [.viewReceipt, .linkPayment, .addDocument, .fetchFromPortal]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: select) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PadTenanciesModel.monthTitle(receipt)).mangoFont(.headline).lineLimit(1)
                            Text("Receipt \(receipt.receipt.receiptNumber)".figuresUnbroken)
                                .mangoFont(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        PadStatusPill(text: receipt.status.name, tone: tone)
                        if receipt.status == .partPaid {
                            MoneyText(minorUnits: receipt.coveredMinorUnits, currency: receipt.currency, role: .neutral, font: .footnote)
                                .accessibilityLabel("Paid so far \(Money.format(receipt.coveredMinorUnits, currency: receipt.currency))")
                        }
                        MoneyText(minorUnits: receipt.receipt.amountMinorUnits, currency: receipt.currency, role: .neutral, font: .headline)
                            .opacity(receipt.status == .cancelled ? 0.5 : 1)
                            .frame(minWidth: 96, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the receipt")
                // One fixed slot per row action, kept (hidden) when this receipt doesn't offer it, so the
                // status, amount and icons line up in columns down the list.
                ForEach(Self.rowActions, id: \.self) { action in
                    if let row = action.rowAction {
                        let offered = actions.contains(action) && (action != .addDocument || receipt.row.documentCount == 0)
                        RowIconButton(row, item: "receipt \(receipt.receipt.receiptNumber)", size: .small) { perform(action) }
                            .opacity(offered ? 1 : 0)
                            .disabled(!offered)
                            .accessibilityHidden(!offered)
                    }
                }
            }
            PadRefusalBanner(message: write.message(for: receipt.rowId))
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? theme.accent.opacity(0.12) : .clear))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pad-receipt-\(receipt.id)")
    }

    private var tone: PadStatusPill.Tone {
        switch receipt.status {
        case .paid: .positive
        case .partPaid, .notMatched: .warning
        case .cancelled: .neutral
        }
    }
}
