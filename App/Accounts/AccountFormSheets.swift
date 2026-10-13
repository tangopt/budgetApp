// App/Accounts/AccountFormSheets.swift
import SwiftUI
import BudgetCore

/// "+ Add account": name, currency, kind, tracking and an optional opening balance
/// (entered as the amount owed for credit) dated by a picked calendar day, plus the
/// optional alias and bank details.
struct AddAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var currency: Currency = .gbp
    @State private var kind: AccountKind = .cash
    @State private var trackingMode: AccountTrackingMode = .manual
    @State private var balanceText = ""
    @State private var asOf = Date()
    @State private var details = AccountDetailsDraft()
    @State private var error: String?

    private var trimmedBalance: String { balanceText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var openingBalance: Int? { Money.parseMinorUnits(trimmedBalance) }
    private var balanceInvalid: Bool { !trimmedBalance.isEmpty && openingBalance == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !balanceInvalid && details.isValid
    }

    var body: some View {
        SheetScaffold(title: "Add account", saveTitle: "Add account", canSave: canSave, error: error, onCancel: { dismiss() }, onSave: save) {
            TextField("Name", text: $name)
            Picker("Currency", selection: $currency) {
                ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            KindPicker(selection: $kind)
            TrackingPicker(selection: $trackingMode)
            MoneyField(kind == .credit ? "Amount owed (optional)" : "Opening balance (optional)", text: $balanceText, currency: currency)
            if kind == .credit {
                SheetCaption("Enter what you owe on the card as a positive number.")
            }
            if !trimmedBalance.isEmpty {
                DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
            }
            AccountDetailsFields(draft: $details)
        }
    }

    private func save() {
        guard canSave else { return }
        let balance = trimmedBalance.isEmpty ? nil : openingBalance
        finish(viewModel.addAccount(name: name, currency: currency, kind: kind, trackingMode: trackingMode, openingBalanceEntered: balance, asOf: AccountsFormat.snapshotDay(asOf), details: details.details), error: $error, dismiss: dismiss)
    }
}

/// "Edit…": name, kind (credit transitions disabled once the account has history),
/// tracking, alias and bank details; currency is read-only.
struct EditAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: AccountKind
    @State private var trackingMode: AccountTrackingMode
    @State private var details: AccountDetailsDraft
    @State private var hasHistory = true
    @State private var error: String?

    init(viewModel: AccountsViewModel, account: Account) {
        self.viewModel = viewModel
        self.account = account
        _name = State(initialValue: account.name)
        _kind = State(initialValue: account.kind)
        _trackingMode = State(initialValue: account.trackingMode)
        _details = State(initialValue: AccountDetailsDraft(account))
    }

    /// Whether switching to `candidate` would cross the credit boundary.
    private func crossesCredit(_ candidate: AccountKind) -> Bool {
        (account.kind == .credit) != (candidate == .credit)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(hasHistory && crossesCredit(kind)) && details.isValid
    }

    var body: some View {
        SheetScaffold(title: "Edit account", saveTitle: "Save", canSave: canSave, error: error, onCancel: { dismiss() }, onSave: save) {
            TextField("Name", text: $name)
            LabeledContent("Currency", value: account.currency.rawValue.uppercased())
            KindPicker(selection: $kind, isDisabled: { hasHistory && crossesCredit($0) })
            if hasHistory {
                SheetCaption("Can't change to or from credit once the account has history.")
            }
            TrackingPicker(selection: $trackingMode)
            AccountDetailsFields(draft: $details)
        }
        .onAppear {
            if let id = account.id { hasHistory = viewModel.hasHistory(id) }
        }
    }

    private func save() {
        guard canSave, let id = account.id else { return }
        finish(viewModel.updateAccount(id: id, name: name, kind: kind, trackingMode: trackingMode, details: details.details), error: $error, dismiss: dismiss)
    }
}

// MARK: - Shared pieces

/// The alias and bank-detail text fields as typed. Each field validates on its own so the
/// sheet can show the error under it; blank fields are fine.
struct AccountDetailsDraft: Equatable {
    var alias = ""
    var sortCode = ""
    var accountNumber = ""
    var iban = ""

    init() {}

    init(_ account: Account) {
        alias = account.alias ?? ""
        sortCode = account.sortCode.map(AccountDetailsFormat.formattedSortCode) ?? ""
        accountNumber = account.accountNumber ?? ""
        iban = account.iban.map(AccountDetailsFormat.formattedIBAN) ?? ""
    }

    var details: AccountDetails {
        AccountDetails(alias: alias, sortCode: sortCode, accountNumber: accountNumber, iban: iban)
    }

    var sortCodeError: String? { Self.message { try AccountDetailsFormat.normalizedSortCode(sortCode) } }
    var accountNumberError: String? { Self.message { try AccountDetailsFormat.normalizedAccountNumber(accountNumber) } }
    var ibanError: String? { Self.message { try AccountDetailsFormat.normalizedIBAN(iban) } }
    var isValid: Bool { sortCodeError == nil && accountNumberError == nil && ibanError == nil }

    private static func message(_ check: () throws -> String?) -> String? {
        do { _ = try check(); return nil } catch { return (error as? AccountDetailsError)?.errorDescription ?? error.localizedDescription }
    }
}

/// Alias, sort code, account number and IBAN fields with inline validation errors.
struct AccountDetailsFields: View {
    @Binding var draft: AccountDetailsDraft

    var body: some View {
        TextField("Alias (optional)", text: $draft.alias, prompt: Text("Short name shown in the app"))
        TextField("Sort code", text: $draft.sortCode, prompt: Text("30-00-00"))
        if let message = draft.sortCodeError { SheetCaption(message, isError: true) }
        TextField("Account number", text: $draft.accountNumber, prompt: Text("12345678"))
        if let message = draft.accountNumberError { SheetCaption(message, isError: true) }
        TextField("IBAN", text: $draft.iban, prompt: Text("GB29 NWBK 6016 1331 9268 19"))
        if let message = draft.ibanError { SheetCaption(message, isError: true) }
    }
}

/// Closes the sheet once the change is saved (even if the reload then failed — the screen
/// banner says so); otherwise shows the failure in the sheet's own error.
@MainActor
func finish(_ outcome: SaveOutcome, error: Binding<String?>, dismiss: DismissAction) {
    switch outcome {
    case .saved, .savedButReloadFailed: dismiss()
    case .failed(let message): error.wrappedValue = message
    }
}

private struct KindPicker: View {
    @Binding var selection: AccountKind
    var isDisabled: (AccountKind) -> Bool = { _ in false }

    var body: some View {
        Picker("Kind", selection: $selection) {
            ForEach([AccountKind.cash, .investment, .credit], id: \.self) { kind in
                Text(AccountsFormat.kind(kind)).tag(kind).disabled(isDisabled(kind))
            }
        }
    }
}

private struct TrackingPicker: View {
    @Binding var selection: AccountTrackingMode

    var body: some View {
        Picker("Tracking", selection: $selection) {
            Text("Manual balance").tag(AccountTrackingMode.manual)
            Text("Imported").tag(AccountTrackingMode.imported)
        }
    }
}

/// Form + inline error + Cancel / Save row used by all four account sheets.
struct SheetScaffold<Content: View>: View {
    let title: String
    let saveTitle: String
    let canSave: Bool
    let error: String?
    var width: CGFloat = 380
    /// False for content that lays itself out (the bulk sheet's scrolling rows).
    var wrapsInForm = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            if wrapsInForm {
                Form { content }
            } else {
                VStack(alignment: .leading, spacing: 10) { content }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(saveTitle, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: width)
    }
}

struct SheetCaption: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
