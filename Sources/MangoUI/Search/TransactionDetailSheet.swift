import SwiftUI
import BudgetCore

/// What the read-only transaction sheet shows (iPhone spec §3.5, read parts only): amount, description, account,
/// date, category and note.
public struct TransactionDetailPresentation {
    public let description: String
    public let account: String
    public let date: Date
    /// "Uncategorised" when it has none.
    public let category: String
    /// Nil when there's no note (or only spaces).
    public let note: String?
    public let amount: (minorUnits: Int, role: MoneyRole)
    public let currency: Currency
    public let isUncategorised: Bool

    public init(_ row: TransactionSearch.Row) {
        let shown = TransactionRowPresentation(row)
        description = row.description
        account = row.accountName
        date = row.date
        category = row.categoryName.isEmpty ? "Uncategorised" : row.categoryName
        let trimmed = row.transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        note = trimmed.isEmpty ? nil : trimmed
        amount = shown.amount
        currency = shown.currency
        isUncategorised = shown.isUncategorised
    }
}

/// A transaction: the amount large, the description, then account, date, category and note. Where the user may edit it
/// (`QuickEditModel.canEdit`) an Edit button opens the edit sheet; otherwise there is no edit control at all (absent,
/// not disabled) and the footer reads "Edit on iPad or Mac". Large detent; Done closes it.
public struct TransactionDetailSheet: View {
    let row: TransactionSearch.Row
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @Environment(\.quickEdit) private var quickEdit
    @State private var canEdit = false
    @State private var editing = false

    public init(row: TransactionSearch.Row) {
        self.row = row
    }

    public var body: some View {
        NavigationStack {
            TransactionDetailContent(row: row, showsFooter: !canEdit)
                .background(theme.background)
                .mangoNavigationTitle("Transaction")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    if canEdit {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Edit") { editing = true }
                                .accessibilityIdentifier("edit-transaction")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .demoBannerSlot()
        }
        .presentationDetents([.large])
        .task(id: row.id) { canEdit = await quickEdit?.canEdit(transactionId: row.id) ?? false }
        .sheet(isPresented: $editing) {
            if let quickEdit { TransactionEditSheet(row: row, model: quickEdit) }
        }
    }
}

/// The sheet's scrolling body (also what the snapshot route renders).
struct TransactionDetailContent: View {
    let row: TransactionSearch.Row
    /// "Edit on iPad or Mac", where the user can't edit here.
    var showsFooter = true

    var body: some View {
        ScrollView {
            TransactionDetailBody(row: row, showsFooter: showsFooter)
                .padding(16)
        }
    }
}

/// The transaction's amount, description, account, date, category and note (the sheet's and the iPad side panel's content).
struct TransactionDetailBody: View {
    let row: TransactionSearch.Row
    var showsFooter = true

    var body: some View {
        let shown = TransactionDetailPresentation(row)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                MoneyText(minorUnits: shown.amount.minorUnits, currency: shown.currency, role: shown.amount.role,
                          fit: .shrink(), font: .largeTitle.weight(.semibold))
                Text(shown.description)
                    .mangoFont(.title3, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Card {
                DetailField(label: "Account") {
                    Text(shown.account.isEmpty ? "—" : shown.account)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DetailField(label: "Date") {
                    DateText(shown.date)
                }
                Divider()
                DetailField(label: "Category") {
                    HStack(spacing: 8) {
                        if let category = row.category {
                            CategoryBadge(category: category)
                        } else {
                            UncategorisedBadge()
                        }
                        Text(shown.category)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = shown.note {
                    Divider()
                    DetailField(label: "Note") {
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if showsFooter {
                Label(SearchCopy.detailFooter, systemImage: "ipad.and.iphone")
                    .mangoFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A label over its value, at least 44 pt tall.
private struct DetailField<Value: View>: View {
    let label: String
    let value: Value

    init(label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .mangoFont(.subheadline)
                .foregroundStyle(.secondary)
            value
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
