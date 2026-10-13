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
    /// Set when Save is pressed with invalid details: every field shows its error.
    @State private var revealErrors = false
    @State private var error: String?

    private var trimmedBalance: String { balanceText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var openingBalance: Int? { Money.parseMinorUnits(trimmedBalance) }
    private var balanceInvalid: Bool { !trimmedBalance.isEmpty && openingBalance == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !balanceInvalid && details.isValid
    }
    /// Save stays pressable once there's a name, so pressing it can say what's wrong.
    private var canPressSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SheetScaffold(title: "Add account", error: error, onCancel: { dismiss() },
                      primary: SheetAction("Add account", isEnabled: canPressSave, action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $name) }
                LabeledContent("Currency") {
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Kind") { KindPicker(selection: $kind) }
                LabeledContent("Tracking") { TrackingPicker(selection: $trackingMode) }
                LabeledContent(kind == .credit ? "Amount owed" : "Opening balance") {
                    MoneyField("Optional", text: $balanceText, currency: currency)
                        .onChange(of: balanceText) { _, _ in error = nil }
                        .sheetFieldNote(kind == .credit ? "Enter what you owe on the card as a positive number." : nil)
                }
                if !trimmedBalance.isEmpty {
                    LabeledContent("As of") {
                        DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
                            .fixedSize()
                    }
                }
                AccountDetailsFields(draft: $details, revealAll: revealErrors)
            }
        }
    }

    private func save() {
        guard canSave else {
            revealErrors = true
            if balanceInvalid { error = MoneyField.invalidAmountMessage(balanceText) }
            return
        }
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
    /// Set when Save is pressed with invalid details: every field shows its error.
    @State private var revealErrors = false
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

    private var canSave: Bool { canPressSave && details.isValid }
    /// Save stays pressable while only the bank details are invalid, so pressing it can say why.
    private var canPressSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(hasHistory && crossesCredit(kind))
    }

    var body: some View {
        SheetScaffold(title: "Edit account", error: error, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: canPressSave, action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $name) }
                LabeledContent("Currency", value: account.currency.rawValue.uppercased())
                LabeledContent("Kind") {
                    KindPicker(selection: $kind, isDisabled: { hasHistory && crossesCredit($0) })
                        .sheetFieldNote(hasHistory ? "Can't change to or from credit once the account has history." : nil)
                }
                LabeledContent("Tracking") { TrackingPicker(selection: $trackingMode) }
                AccountDetailsFields(draft: $details, revealAll: revealErrors)
            }
        }
        .onAppear {
            if let id = account.id { hasHistory = viewModel.hasHistory(id) }
        }
    }

    private func save() {
        guard canSave else {
            revealErrors = true
            return
        }
        guard let id = account.id else { return }
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

/// Alias, sort code, account number and IBAN rows for a `SheetForm`. A field's validation
/// error shows once the field has lost focus or Return was pressed in it — not while it is
/// being typed in (an edit hides it again until then) — or, with `revealAll`, always (Save
/// was pressed while a field is invalid; the sheet doesn't save then).
struct AccountDetailsFields: View {
    @Binding var draft: AccountDetailsDraft
    var revealAll = false

    private enum Field: Hashable { case sortCode, accountNumber, iban }

    @FocusState private var focused: Field?
    /// Fields whose error may show: left, or submitted, since their last edit.
    @State private var revealed: Set<Field> = []

    var body: some View {
        LabeledContent("Alias") {
            TextField("Alias", text: $draft.alias, prompt: Text("Optional short name shown in the app"))
                // Inside the cell: a modifier on a row would stop the grid seeing it as a row.
                .onChange(of: focused) { old, _ in
                    if let old { revealed.insert(old) }
                }
                .onChange(of: draft.sortCode) { _, _ in revealed.remove(.sortCode) }
                .onChange(of: draft.accountNumber) { _, _ in revealed.remove(.accountNumber) }
                .onChange(of: draft.iban) { _, _ in revealed.remove(.iban) }
        }
        LabeledContent("Sort code") {
            field(.sortCode, text: $draft.sortCode, prompt: "30-00-00", error: draft.sortCodeError)
        }
        LabeledContent("Account number") {
            field(.accountNumber, text: $draft.accountNumber, prompt: "12345678", error: draft.accountNumberError)
        }
        LabeledContent("IBAN") {
            field(.iban, text: $draft.iban, prompt: "GB29 NWBK 6016 1331 9268 19", error: draft.ibanError)
        }
    }

    private func field(_ field: Field, text: Binding<String>, prompt: String, error: String?) -> some View {
        TextField(prompt, text: text, prompt: Text(prompt))
            .focused($focused, equals: field)
            .onSubmit { revealed.insert(field) }
            .sheetFieldNote(revealAll || revealed.contains(field) ? error : nil, isError: true)
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
        .fixedSize()
    }
}

private struct TrackingPicker: View {
    @Binding var selection: AccountTrackingMode

    var body: some View {
        Picker("Tracking", selection: $selection) {
            Text("Manual balance").tag(AccountTrackingMode.manual)
            Text("Imported").tag(AccountTrackingMode.imported)
        }
        .fixedSize()
    }
}
