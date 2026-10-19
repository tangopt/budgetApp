// App/Property/PropertySidePanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// A page with its side panel docked at the trailing edge (like the Budget grid's cell
/// panel): 320 pt behind a divider, the page narrowing to make room — its `DataTable`s hide or
/// narrow low-priority columns — so the panel never covers the page. Closing it gives the
/// page its full width back.
struct PropertyPanelDock<Page: View, SidePanel: View>: View {
    static var panelWidth: CGFloat { 320 }

    let isOpen: Bool
    @ViewBuilder let page: Page
    @ViewBuilder let panel: SidePanel

    var body: some View {
        HStack(spacing: 0) {
            page.frame(maxWidth: .infinity, alignment: .leading)
            if isOpen {
                Divider()
                panel
                    .frame(width: Self.panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isOpen)
    }
}

/// The property page's side panel (the Budget grid's and Categories' `TransactionsSidePanel`
/// recipe): 12 pt padding on `theme.windowFill`, a `.headline` title with ✕ (Escape closes),
/// a `.callout` secondary subtitle, then the content (figures and a sectioned `List`).
struct PropertySidePanel<Content: View>: View {
    let title: String
    var subtitle: String?
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).lineLimit(1).figureText()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close \(title)")
            }
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.windowFill)
    }
}

/// A label and an amount on one line of a side panel's figures ("Rent received  €1,000.00").
struct PropertyPanelFigure: View {
    let title: String
    let minorUnits: Int
    let currency: Currency
    var role: MoneyRole = .signed
    var isTotal = false

    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            MoneyText(minorUnits: minorUnits, currency: currency,
                      font: isTotal ? .callout.monospacedDigit().weight(.semibold) : .callout.monospacedDigit(), role: role)
        }
        .font(isTotal ? .callout.weight(.semibold) : .callout)
        .accessibilityElement(children: .combine)
    }
}

/// A section header of a side panel's list: the group's name and its total.
struct PropertyPanelSectionHeader: View {
    let title: String
    let minorUnits: Int
    let currency: Currency
    var role: MoneyRole = .signed

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            MoneyText(minorUnits: minorUnits, currency: currency, font: .caption.monospacedDigit().weight(.semibold), role: role)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A transaction in a side panel: its description and the amount it counts, then its day,
/// category and account, its documents, Edit transaction (pencil) and Show in Search;
/// a note beneath when the amount counted isn't the transaction's own. The amount and the
/// icons share a trailing column at their own size; the words truncate beside them.
struct PropertyPanelTransactionRow: View {
    let transaction: Transaction
    /// What the row counts, in `currency`.
    let minorUnits: Int
    let currency: Currency
    var detail: String?
    var note: String?
    let onEdit: (Transaction) -> Void
    let onShow: (Transaction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Two columns: the words on the left (they truncate), the amount over the row's
            // icons on the right at their own size, so nothing ever covers a figure.
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(transaction.rawDescription).lineLimit(1).truncationMode(.tail).help(transaction.rawDescription)
                    HStack(spacing: 4) {
                        DateText(date: transaction.date, font: .caption).foregroundStyle(.secondary).fixedSize()
                        if let detail {
                            Text("· " + detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
                        }
                        if transaction.isManual { ManualTag() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    MoneyText(minorUnits: minorUnits, currency: currency)
                    HStack(spacing: 6) {
                        TransactionDocumentBadge(transactionId: transaction.id)
                        Button { onEdit(transaction) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit transaction: category, note, documents")
                            .accessibilityLabel("Edit \(transaction.rawDescription)")
                        Button { onShow(transaction) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless)
                            .help("Show the transaction: Search, on its day and account, with it selected")
                            .accessibilityLabel("Show \(transaction.rawDescription) in Search")
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Edit transaction… from a side panel: the app's `EditTransactionSheet`, with the category
/// lists, transfer links and manual-transaction actions of a Search model read when it opens.
struct PropertyEditTransactionSheet: View {
    let transaction: Transaction
    @StateObject private var model: SearchViewModel

    init(transaction: Transaction, dbQueue: DatabaseQueue) {
        self.transaction = transaction
        _model = StateObject(wrappedValue: {
            let model = SearchViewModel(dbQueue: dbQueue)
            model.load()
            return model
        }())
    }

    var body: some View {
        EditTransactionSheet(
            transaction: transaction, categories: model.categories, groups: model.groups, recentIds: model.recentCategoryIds,
            createCategory: model.createCategory, transfer: model.transferActions, manual: model.manualActions,
            onSave: { changes in
                guard let id = transaction.id else { return .failed("This transaction hasn't been saved yet.") }
                return model.saveTransactionEdit(id: id, changes: changes)
            })
    }
}
