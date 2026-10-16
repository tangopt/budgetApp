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
/// an Edit transaction (pencil) button — newest first, a transaction added by hand tagged
/// "Manual", one with documents a paperclip and their count; then an optional `plannedSection` (a `Section` for the panel's `List`). With
/// `onAdd`, the header also has Add transaction… (+).
struct TransactionsSidePanel<Planned: View>: View {
    let title: String
    let transactions: [Transaction]
    var categoryById: [Int64: Category] = [:]
    var showCategory = false
    /// Account names by id: each row names its account when given.
    var accountNameById: [Int64: String] = [:]
    /// Linked transfers' other legs by transaction id (`TransferLinks.counterparts`).
    var transfers: [Int64: [TransferCounterpart]] = [:]
    /// Each row's account currency and the total's GBP equivalent: rows show each account's
    /// own currency, the total is in GBP like the cell it opened from.
    var conversion: CurrencyConversion = .none
    /// False for a reserve (planned items only): no transactions list or count.
    var showsTransactions = true
    /// Shown above the list (e.g. an error banner or a filter), when given.
    var accessory: AnyView? = nil
    /// Add transaction… in the header, when given.
    var onAdd: (() -> Void)? = nil
    let plannedSection: () -> Planned
    /// Each transaction's Edit transaction (pencil) button, when given (the Forecast grid's
    /// panel lists actuals read-only).
    let onEdit: ((Transaction) -> Void)?
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    init(title: String, transactions: [Transaction], categoryById: [Int64: Category] = [:], showCategory: Bool = false,
         accountNameById: [Int64: String] = [:],
         transfers: [Int64: [TransferCounterpart]] = [:], conversion: CurrencyConversion = .none,
         showsTransactions: Bool = true, accessory: AnyView? = nil,
         onAdd: (() -> Void)? = nil,
         @ViewBuilder plannedSection: @escaping () -> Planned,
         onEdit: ((Transaction) -> Void)?, onClose: @escaping () -> Void) {
        self.title = title
        self.transactions = transactions
        self.categoryById = categoryById
        self.showCategory = showCategory
        self.accountNameById = accountNameById
        self.transfers = transfers
        self.conversion = conversion
        self.showsTransactions = showsTransactions
        self.accessory = accessory
        self.onAdd = onAdd
        self.plannedSection = plannedSection
        self.onEdit = onEdit
        self.onClose = onClose
    }

    /// "Total in GBP at <rate>" when any row is in another currency (the total converts it).
    private var convertedTotalNote: String? {
        guard transactions.contains(where: { conversion.currency(ofAccount: $0.accountId) != .gbp }) else { return nil }
        return "Total in GBP at \(String(format: "%.4f", conversion.eurToGbpRate))"
    }

    private static var convertedTotalHelp: String { "Each transaction shows its account's own currency; the total converts them to GBP at the stored rate." }

    private var sorted: [Transaction] {
        transactions.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).lineLimit(2)
                Spacer()
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add transaction…")
                    .accessibilityLabel("Add transaction")
                }
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
                    MoneyText(minorUnits: transactions.reduce(0) { $0 + conversion.gbp($1) })
                        .help(convertedTotalNote.map { _ in Self.convertedTotalHelp } ?? "")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let note = convertedTotalNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(Self.convertedTotalHelp)
                }
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
        .background(theme.windowFill)
    }

    private func row(_ transaction: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(transaction.rawDescription).lineLimit(2)
                Spacer()
                MoneyText(minorUnits: transaction.amountMinorUnits, currency: conversion.currency(ofAccount: transaction.accountId))
                    .fixedSize()
            }
            if let note = transaction.note, !note.isEmpty {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
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
                if transaction.isManual { ManualTag() }
                TransactionDocumentBadge(transactionId: transaction.id)
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
                if let onEdit {
                    Button { onEdit(transaction) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit transaction")
                    .accessibilityLabel("Edit transaction")
                }
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
         transfers: [Int64: [TransferCounterpart]] = [:], conversion: CurrencyConversion = .none, accessory: AnyView? = nil,
         onEdit: @escaping (Transaction) -> Void, onClose: @escaping () -> Void) {
        self.init(title: title, transactions: transactions, categoryById: categoryById, showCategory: showCategory,
                  transfers: transfers, conversion: conversion, accessory: accessory, plannedSection: { EmptyView() }, onEdit: onEdit, onClose: onClose)
    }
}
