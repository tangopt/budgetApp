// App/DesignSystem/ManualTransactionForm.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// What a manual transaction's save writes (`ManualTransactions.add` / `.update`): the date
/// is the stored UTC day, the amount signed (negative = money out).
struct ManualTransactionInput {
    let accountId: Int64
    let date: Date
    let description: String
    let amountMinorUnits: Int
    let categoryId: Int64?
    let note: String?
}

/// What Edit transaction needs for a manual transaction (spec 2026-10-14 §2): the accounts it
/// can move to, and Delete… (followed by the screen's reload). Its edits are written by Save
/// (`TransactionEditing.save`).
struct ManualTransactionActions {
    /// The accounts a manual transaction can be in, in the order the app lists them.
    let accounts: [Account]
    let delete: (_ id: Int64) -> SaveOutcome
}

/// The editable fields shared by Add transaction… and Edit transaction (manual): account,
/// date, description, direction and amount. Category and note are the sheets' own rows.
struct ManualTransactionDraft: Equatable {
    var accountId: Int64?
    /// Local midnight of the picked day (what a `DatePicker` holds).
    var day: Date
    var description: String
    var isMoneyIn: Bool
    var amountText: String

    /// A new transaction: today, money out unless the preselected category is income.
    init(accountId: Int64?, category: Category?) {
        self.accountId = accountId
        day = Calendar.current.startOfDay(for: Date())
        description = ""
        isMoneyIn = category?.type == .income
        amountText = ""
    }

    /// An existing transaction's values.
    init(_ transaction: Transaction) {
        accountId = transaction.accountId
        day = PayCalendar.localDay(sameDayAs: transaction.date, in: .current)
        description = transaction.rawDescription
        isMoneyIn = transaction.amountMinorUnits > 0
        amountText = Money.formatInput(abs(transaction.amountMinorUnits))
    }

    /// The entered amount with the direction's sign; nil while empty, unparseable or zero.
    var signedAmountMinorUnits: Int? {
        guard let value = Money.parseMinorUnits(amountText), value != 0 else { return nil }
        return isMoneyIn ? abs(value) : -abs(value)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        accountId != nil && !trimmedDescription.isEmpty && signedAmountMinorUnits != nil
    }

    /// Under the amount: why it can't be saved (not shown while empty).
    var amountNote: String? {
        let text = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Money.parseMinorUnits(text) else { return MoneyField.invalidAmountMessage(text) }
        return value == 0 ? "Enter an amount other than zero." : nil
    }

    /// What Edit transaction's Save writes for the account, date, description and amount.
    var fields: TransactionEditChanges.ManualFields? {
        guard let accountId, let amount = signedAmountMinorUnits, !trimmedDescription.isEmpty else { return nil }
        return TransactionEditChanges.ManualFields(accountId: accountId, date: PayCalendar.utcDay(sameDayAs: day, in: .current),
                                                   description: trimmedDescription, amountMinorUnits: amount)
    }

    func input(categoryId: Int64?, note: String) -> ManualTransactionInput? {
        guard let accountId, let amount = signedAmountMinorUnits, !trimmedDescription.isEmpty else { return nil }
        return ManualTransactionInput(accountId: accountId, date: PayCalendar.utcDay(sameDayAs: day, in: .current),
                                      description: trimmedDescription, amountMinorUnits: amount,
                                      categoryId: categoryId, note: Transaction.normalizedNote(note))
    }
}

/// The `SheetForm` rows for a `ManualTransactionDraft`: Account, Date, Description,
/// Money in / Money out and Amount (in the chosen account's currency).
struct ManualTransactionFields: View {
    @Binding var draft: ManualTransactionDraft
    let accounts: [Account]

    private var currency: Currency {
        accounts.first { $0.id == draft.accountId }?.currency ?? .gbp
    }

    var body: some View {
        LabeledContent("Account") {
            Picker("Account", selection: $draft.accountId) {
                ForEach(accounts) { account in
                    Text(account.displayName).tag(account.id)
                }
            }
            .fixedSize()
        }
        LabeledContent("Date") {
            DatePicker("Date", selection: $draft.day, displayedComponents: .date)
                .fixedSize()
        }
        LabeledContent("Description") {
            TextField("Description", text: $draft.description, prompt: Text("e.g. Transfer to ISA"))
        }
        LabeledContent("Direction") {
            Picker("Direction", selection: $draft.isMoneyIn) {
                Text("Money out").tag(false)
                Text("Money in").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        LabeledContent("Amount") {
            MoneyField("Amount", text: $draft.amountText, currency: currency, width: 140)
                .sheetFieldNote(draft.amountNote, isError: true)
        }
    }
}

/// The small secondary "Manual" tag on a transaction added by hand.
struct ManualTag: View {
    var body: some View {
        Text("Manual")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Added by hand")
    }
}

enum ManualFormat {
    /// "9 Mar" for a stored (UTC) day.
    static func shortDay(_ utcDate: Date) -> String {
        var style = Date.FormatStyle().day().month(.abbreviated)
        style.timeZone = TimeZone(identifier: "UTC")!
        return utcDate.formatted(style)
    }

    /// A refused transaction write's readable reason (`ManualTransactionError`,
    /// `TransactionEditError`, `TransferLinkError`), else "Couldn't save: …".
    static func errorMessage(for error: Error) -> String {
        let refusal: String?
        switch error {
        case let error as ManualTransactionError: refusal = error.errorDescription
        case let error as TransactionEditError: refusal = error.errorDescription
        case let error as TransferLinkError: refusal = error.errorDescription
        default: refusal = nil
        }
        if let refusal { return refusal }
        return "Couldn't save: \(error.localizedDescription)"
    }
}
