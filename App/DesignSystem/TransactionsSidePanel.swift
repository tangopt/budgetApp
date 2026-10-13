// App/DesignSystem/TransactionsSidePanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import struct BudgetCore.Category

/// The right-hand side panel listing a cell's (or a category's) transactions (spec §2, §4):
/// a title with ✕ (Escape also closes), the count and total, then each transaction — date,
/// description, its note underneath, its transfer link ("↔ <account> · <date> · <amount>",
/// spec §6), its account when `accountNameById` is given (the Budget grid's, spec §7), its
/// category (badge and name) when `showCategory` (group and section rows), the amount and
/// an Edit transaction (pencil) button — newest first; then an optional `plannedSection` (a
/// `Section` for the panel's `List`).
struct TransactionsSidePanel<Planned: View>: View {
    let title: String
    let transactions: [Transaction]
    var categoryById: [Int64: Category] = [:]
    var showCategory = false
    /// Account names by id: each row names its account when given.
    var accountNameById: [Int64: String] = [:]
    /// Linked transfers' other legs by transaction id (`TransferLinks.counterparts`).
    var transfers: [Int64: [TransferCounterpart]] = [:]
    /// False for a reserve (planned items only): no transactions list or count.
    var showsTransactions = true
    /// Shown above the list (e.g. an error banner or a filter), when given.
    var accessory: AnyView? = nil
    let plannedSection: () -> Planned
    let onEdit: (Transaction) -> Void
    let onClose: () -> Void

    init(title: String, transactions: [Transaction], categoryById: [Int64: Category] = [:], showCategory: Bool = false,
         accountNameById: [Int64: String] = [:],
         transfers: [Int64: [TransferCounterpart]] = [:], showsTransactions: Bool = true, accessory: AnyView? = nil,
         @ViewBuilder plannedSection: @escaping () -> Planned,
         onEdit: @escaping (Transaction) -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.transactions = transactions
        self.categoryById = categoryById
        self.showCategory = showCategory
        self.accountNameById = accountNameById
        self.transfers = transfers
        self.showsTransactions = showsTransactions
        self.accessory = accessory
        self.plannedSection = plannedSection
        self.onEdit = onEdit
        self.onClose = onClose
    }

    private var sorted: [Transaction] {
        transactions.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).lineLimit(2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            if showsTransactions {
                HStack {
                    Text(transactions.count == 1 ? "1 transaction" : "\(transactions.count) transactions")
                    Spacer()
                    MoneyText(minorUnits: transactions.reduce(0) { $0 + $1.amountMinorUnits })
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let accessory { accessory }
            List {
                if showsTransactions {
                    Section("Transactions") {
                        if transactions.isEmpty {
                            Text("No transactions.").foregroundStyle(.secondary)
                        }
                        ForEach(sorted) { transaction in
                            row(transaction)
                        }
                    }
                }
                plannedSection()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ transaction: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(transaction.rawDescription).lineLimit(2)
                Spacer()
                MoneyText(minorUnits: transaction.amountMinorUnits)
                    .fixedSize()
            }
            if let note = transaction.note, !note.isEmpty {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(transaction.id.flatMap { transfers[$0] } ?? []) { counterpart in
                Text(TransferFormat.line(counterpart))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Transfer between your accounts: counted once, as sent")
            }
            HStack(spacing: 4) {
                Text(caption(transaction))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if showCategory {
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    if let category = transaction.categoryId.flatMap({ categoryById[$0] }) {
                        CategoryBadge(category: category, size: .small)
                        Text(category.name)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Uncategorized")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button { onEdit(transaction) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit transaction")
                .accessibilityLabel("Edit transaction")
            }
        }
        .padding(.vertical, 2)
    }

    /// "12 Oct 2026", plus " · Lloyds Classic" when accounts are named (the category, when
    /// shown, follows with its badge).
    private func caption(_ transaction: Transaction) -> String {
        var parts = [transaction.date.formatted(date: .abbreviated, time: .omitted)]
        if let account = accountNameById[transaction.accountId] { parts.append(account) }
        return parts.joined(separator: " · ")
    }
}

extension TransactionsSidePanel where Planned == EmptyView {
    /// No planned section (e.g. a Year Total, or the Categories screen).
    init(title: String, transactions: [Transaction], categoryById: [Int64: Category] = [:], showCategory: Bool = false,
         transfers: [Int64: [TransferCounterpart]] = [:], accessory: AnyView? = nil,
         onEdit: @escaping (Transaction) -> Void, onClose: @escaping () -> Void) {
        self.init(title: title, transactions: transactions, categoryById: categoryById, showCategory: showCategory,
                  transfers: transfers, accessory: accessory, plannedSection: { EmptyView() }, onEdit: onEdit, onClose: onClose)
    }
}
