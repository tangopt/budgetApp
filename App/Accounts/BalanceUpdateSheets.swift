// App/Accounts/BalanceUpdateSheets.swift
import SwiftUI
import BudgetCore

/// What Update balance will record for an account (spec 2026-10-14 §1): the difference
/// between the entered balance and the computed one at the as-of day, as Market movement
/// (investments) or Balance adjustment (anything else); nothing when they match.
enum BalanceUpdatePreview {
    static func difference(_ row: AccountRow, entered: Int?, baseline: BalanceBaseline?) -> Int? {
        guard let entered, case .computed(let computed)? = baseline else { return nil }
        return NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: entered, accountKind: row.account.kind) - computed
    }

    static func text(_ row: AccountRow, difference: Int) -> String {
        guard difference != 0 else { return "Balance already matches — nothing will be added." }
        let role = CategoryBuiltInRole.forAccount(kind: row.account.kind)
        let sign = difference > 0 ? "+" : ""
        return "Adds a \(role.defaultName) of \(sign)\(Money.format(difference, currency: row.account.currency)) on that day."
    }

    /// The caution for correcting anything but an investment.
    static func caution(_ kind: AccountKind) -> String? {
        switch kind {
        case .investment: return nil
        case .cash: return "Adjusting a cash account's balance is unusual — check for missing or duplicate transactions first."
        case .credit: return "Adjusting a credit card's balance is unusual — check for missing or duplicate transactions first."
        }
    }
}

/// An account's Update balance baseline for one day (`AccountsViewModel.balanceBaselines`).
enum BalanceBaseline: Equatable {
    case computed(Int)
    /// A recorded balance on or after the day blocks the update; the message says which.
    case blocked(String)
}

/// Baselines read once per as-of day (never per keystroke): `refresh` re-reads only when the
/// day changes.
struct BalanceBaselineCache: Equatable {
    private(set) var day: Date?
    private(set) var values: [Int64: BalanceBaseline] = [:]

    subscript(id: Int64) -> BalanceBaseline? { values[id] }

    @MainActor mutating func refresh(_ viewModel: AccountsViewModel, accountIds: [Int64], day: Date) {
        guard day != self.day else { return }
        self.day = day
        values = viewModel.balanceBaselines(accountIds: accountIds, asOf: day)
    }
}

/// "Update balance…" for one account: amount (amount owed for credit), as-of day, note. Saving
/// adds the difference from the computed balance as an adjustment transaction (no snapshot).
struct UpdateBalanceSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let row: AccountRow
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    @State private var asOf = Date()
    @State private var note = ""
    @State private var error: String?
    @State private var baselines = BalanceBaselineCache()

    init(viewModel: AccountsViewModel, row: AccountRow) {
        self.viewModel = viewModel
        self.row = row
        _amountText = State(initialValue: AccountsFormat.enteredAmountText(row))
    }

    private var amount: Int? { Money.parseMinorUnits(amountText) }
    private var day: Date { AccountsFormat.snapshotDay(asOf) }
    private var difference: Int? {
        BalanceUpdatePreview.difference(row, entered: amount, baseline: baselines[row.id])
    }

    var body: some View {
        SheetScaffold(title: "Update balance", subtitle: row.account.displayName, error: error, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: amount != nil, action: save)) {
            SheetForm {
                LabeledContent(row.account.kind == .credit ? "Amount owed" : "Balance") {
                    MoneyField(row.account.kind == .credit ? "Amount owed" : "Balance", text: $amountText, currency: row.account.currency)
                        .onChange(of: amountText) { _, _ in error = nil }
                        .sheetFieldNote(row.account.kind == .credit ? "Enter what you owe on the card as a positive number." : nil)
                }
                LabeledContent("As of") {
                    DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
                        .fixedSize()
                        .onChange(of: asOf) { _, _ in error = nil }
                }
                LabeledContent("Note") { TextField("Note", text: $note, prompt: Text("Optional")) }
                if case .blocked(let message)? = baselines[row.id] {
                    SheetFormNote(message, isError: true)
                } else if let difference {
                    SheetFormNote(BalanceUpdatePreview.text(row, difference: difference))
                    if difference != 0, let caution = BalanceUpdatePreview.caution(row.account.kind) {
                        SheetFormNote(caution, isError: true)
                    }
                }
            }
        }
        .onAppear { baselines.refresh(viewModel, accountIds: [row.id], day: day) }
        .onChange(of: day) { _, newDay in baselines.refresh(viewModel, accountIds: [row.id], day: newDay) }
    }

    private func save() {
        guard let amount else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = BalanceUpdates.Entry(accountId: row.id, enteredMinorUnits: amount, note: trimmedNote.isEmpty ? nil : trimmedNote)
        finish(viewModel.saveBalances([entry], asOf: AccountsFormat.snapshotDay(asOf)), error: $error, dismiss: dismiss)
    }
}

/// "Update balances…": every account, grouped like the list, prefilled with its current
/// entered balance; included rows (default: every account that has a balance) are updated
/// as of one day — each difference becomes an adjustment, matching rows add nothing.
/// Accounts with no balance yet start unticked with an empty field.
struct UpdateBalancesSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let groups: [AccountGroup]
    @Environment(\.dismiss) private var dismiss

    @State private var included: [Int64: Bool]
    @State private var texts: [Int64: String]
    @State private var asOf = Date()
    @State private var error: String?
    @State private var baselines = BalanceBaselineCache()

    init(viewModel: AccountsViewModel, groups: [AccountGroup]) {
        self.viewModel = viewModel
        self.groups = groups
        let rows = groups.flatMap(\.rows)
        _included = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lastUpdated != nil) }))
        _texts = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lastUpdated == nil ? "" : AccountsFormat.enteredAmountText($0)) }))
    }

    private var includedRows: [AccountRow] {
        groups.flatMap(\.rows).filter { included[$0.id] ?? false }
    }

    /// nil when any included row doesn't parse.
    private var entries: [BalanceUpdates.Entry]? {
        var result: [BalanceUpdates.Entry] = []
        for row in includedRows {
            guard let amount = Money.parseMinorUnits(texts[row.id] ?? "") else { return nil }
            result.append(BalanceUpdates.Entry(accountId: row.id, enteredMinorUnits: amount))
        }
        return result
    }

    private var saveTitle: String {
        let count = includedRows.count
        return "Save \(count) balance\(count == 1 ? "" : "s")"
    }

    /// Included cash and credit rows whose entered balance differs from the computed one.
    private var cautionCount: Int {
        includedRows.filter { row in
            guard row.account.kind != .investment else { return false }
            let difference = BalanceUpdatePreview.difference(row, entered: Money.parseMinorUnits(texts[row.id] ?? ""), baseline: baselines[row.id])
            return (difference ?? 0) != 0
        }.count
    }

    /// Included rows a recorded balance on or after the day blocks, with why.
    private var blockedMessages: [String] {
        includedRows.compactMap { row in
            if case .blocked(let message)? = baselines[row.id] { return message }
            return nil
        }
    }

    private var day: Date { AccountsFormat.snapshotDay(asOf) }
    private var allIds: [Int64] { groups.flatMap(\.rows).map(\.id) }

    var body: some View {
        SheetScaffold(title: "Update balances", subtitle: "Credit cards: enter the amount owed. Each difference from the computed balance is added as a Market movement (investments) or Balance adjustment; matching rows add nothing.",
                      error: error, width: 480, onCancel: { dismiss() },
                      primary: SheetAction(saveTitle, isEnabled: entries?.isEmpty == false, action: save)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        Text(AccountsFormat.kind(group.kind)).font(.headline)
                        ForEach(group.rows) { row in
                            rowView(row)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            SheetForm {
                LabeledContent("As of") {
                    DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
                        .fixedSize()
                        .onChange(of: asOf) { _, _ in error = nil }
                }
                ForEach(blockedMessages, id: \.self) { SheetFormNote($0, isError: true) }
                let cautions = cautionCount
                if cautions > 0 {
                    SheetFormNote("\(cautions == 1 ? "1 cash or credit account" : "\(cautions) cash or credit accounts") would be adjusted. That's unusual — check for missing or duplicate transactions first.", isError: true)
                }
            }
        }
        .onAppear { baselines.refresh(viewModel, accountIds: allIds, day: day) }
        .onChange(of: day) { _, newDay in baselines.refresh(viewModel, accountIds: allIds, day: newDay) }
    }

    private func rowView(_ row: AccountRow) -> some View {
        let isIncluded = included[row.id] ?? false
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { included[row.id] ?? false }, set: { included[row.id] = $0 })) {
                Text(row.account.displayName).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            Spacer()
            MoneyField(row.account.kind == .credit ? "Amount owed" : "Balance", text: Binding(get: { texts[row.id] ?? "" }, set: { texts[row.id] = $0 }), currency: row.account.currency, width: 130)
                .labelsHidden()
                .disabled(!isIncluded)
        }
    }

    private func save() {
        guard let entries, !entries.isEmpty else { return }
        finish(viewModel.saveBalances(entries, asOf: AccountsFormat.snapshotDay(asOf)), error: $error, dismiss: dismiss)
    }
}
