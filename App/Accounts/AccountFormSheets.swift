// App/Accounts/AccountFormSheets.swift
import SwiftUI
import BudgetCore

/// "+ Add account": name, currency, kind and an optional opening balance (entered as the
/// amount owed for credit) dated by a picked calendar day, plus the optional alias and bank
/// details. The balance is then the opening balance plus the account's transactions after
/// that day; without one it starts from zero (spec 2026-10-14 §1).
struct AddAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var currency: Currency = .gbp
    @State private var kind: AccountKind = .cash
    @State private var balanceText = ""
    @State private var asOf = AppClock.now
    @State private var details = AccountDetailsDraft()
    @State private var includeInNetWorth = true
    @State private var joint = false
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
                    .onChange(of: currency) { _, new in
                        if !details.regionChosen { details.region = .forCurrency(new) }
                    }
                }
                LabeledContent("Kind") { KindPicker(selection: $kind) }
                LabeledContent(kind == .credit ? "Amount owed" : "Opening balance") {
                    MoneyField("Optional", text: $balanceText, currency: currency)
                        .onChange(of: balanceText) { _, _ in error = nil }
                        .sheetFieldNote(kind == .credit
                                        ? "Enter what you owe on the card as a positive number. Transactions after that day are added to it."
                                        : "Transactions after that day are added to it. Leave empty to start from zero.")
                }
                if !trimmedBalance.isEmpty {
                    LabeledContent("As of") {
                        DatePicker("As of", selection: $asOf, in: ...AppClock.now, displayedComponents: .date)
                            .fixedSize()
                    }
                }
                NetWorthToggle(isOn: $includeInNetWorth)
                LabeledContent(SharingCopy.addJointLabel) {
                    Toggle(SharingCopy.addJointLabel, isOn: $joint)
                        .labelsHidden()
                        .sheetFieldNote(SharingCopy.addJointNote)
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
        finish(viewModel.addAccount(name: name, currency: currency, kind: kind, openingBalanceEntered: balance, asOf: AccountsFormat.snapshotDay(asOf), details: details.details,
                                      includeInNetWorth: includeInNetWorth, joint: joint), error: $error, dismiss: dismiss)
    }
}

/// "Edit…": name, kind (credit transitions disabled once the account has history), sharing
/// (`AccountSharingSection`), alias and bank details; currency is read-only.
struct EditAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: AccountKind
    @State private var details: AccountDetailsDraft
    @State private var isMain: Bool
    @State private var includeInNetWorth: Bool
    @State private var hasHistory = true
    @StateObject private var sharing = AccountSharingDraft()
    @State private var isSaving = false
    /// Set when Save is pressed with invalid details: every field shows its error.
    @State private var revealErrors = false
    @State private var error: String?
    /// A sharing choice made as the sheet opens (snapshot routes: a change already picked).
    private let sharingPreset: AccountSharingDraft.Preset?

    init(viewModel: AccountsViewModel, account: Account, sharingPreset: AccountSharingDraft.Preset? = nil) {
        self.viewModel = viewModel
        self.account = account
        self.sharingPreset = sharingPreset
        _name = State(initialValue: account.name)
        _kind = State(initialValue: account.kind)
        _details = State(initialValue: AccountDetailsDraft(account))
        _isMain = State(initialValue: account.isMain)
        _includeInNetWorth = State(initialValue: account.includeInNetWorth)
    }

    /// Whether switching to `candidate` would cross the credit boundary.
    private func crossesCredit(_ candidate: AccountKind) -> Bool {
        (account.kind == .credit) != (candidate == .credit)
    }

    private var canSave: Bool { canPressSave && details.isValid }
    /// Save stays pressable while only the bank details are invalid, so pressing it can say why.
    private var canPressSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(hasHistory && crossesCredit(kind)) && sharing.canSave && !isSaving
    }

    var body: some View {
        SheetScaffold(title: "Edit account", error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: canPressSave, action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $name) }
                LabeledContent("Currency", value: account.currency.rawValue.uppercased())
                LabeledContent("Kind") {
                    KindPicker(selection: $kind, isDisabled: { hasHistory && crossesCredit($0) })
                        .sheetFieldNote(hasHistory ? "Can't change to or from credit once the account has history." : nil)
                }
                LabeledContent("Main account") {
                    Toggle("Main account", isOn: $isMain)
                        .labelsHidden()
                        .help(Self.mainAccountHelp)
                        .sheetFieldNote(Self.mainAccountHelp)
                }
                NetWorthToggle(isOn: $includeInNetWorth)
                AccountSharingSection(draft: sharing, viewModel: viewModel)
                AccountDetailsFields(draft: $details, revealAll: revealErrors)
            }
        }
        .onAppear {
            if let id = account.id { hasHistory = viewModel.hasHistory(id) }
        }
        .task {
            guard let id = account.id else { return }
            await sharing.load(accountId: id, viewModel: viewModel)
            if let sharingPreset { sharing.apply(sharingPreset, viewModel: viewModel) }
        }
    }

    private func save() {
        guard canSave else {
            revealErrors = true
            return
        }
        guard let id = account.id else { return }
        guard let change = sharing.change else {
            finish(viewModel.updateAccount(id: id, name: name, kind: kind, details: details.details, isMain: isMain, includeInNetWorth: includeInNetWorth),
                   error: $error, dismiss: dismiss)
            return
        }
        isSaving = true
        error = nil
        Task {
            let outcome = await viewModel.updateAccount(id: id, name: name, kind: kind, details: details.details, isMain: isMain,
                                                        includeInNetWorth: includeInNetWorth, sharing: change)
            isSaving = false
            finish(outcome, error: $error, dismiss: dismiss)
        }
    }

    static let mainAccountHelp = "Planned items with no account of their own go to this account"
}

// MARK: - Shared pieces

/// Count toward net worth (`Account.includeInNetWorth`), as a `SheetForm` row.
struct NetWorthToggle: View {
    @Binding var isOn: Bool

    static let help = "Turn off for accounts like a mortgage on a property the app doesn't track"

    var body: some View {
        LabeledContent("Count toward net worth") {
            Toggle("Count toward net worth", isOn: $isOn)
                .labelsHidden()
                .help(Self.help)
                .sheetFieldNote(Self.help)
        }
    }
}

/// The alias and bank-detail text fields as typed, with the bank region (spec 2026-10-15 §2).
/// Each field validates on its own so the sheet can show the error under it; blank fields are
/// fine, only the region's fields (plus bank name and BIC) count, and a stored value that
/// predates a rule only errs once edited.
struct AccountDetailsDraft: Equatable {
    var alias = ""
    var region: BankRegion = .uk
    /// Whether the region was picked (or loaded from an account); until then the Add sheet
    /// follows the currency.
    var regionChosen = false
    var bankName = ""
    var sortCode = ""
    var accountNumber = ""
    var iban = ""
    var routingNumber = ""
    var bic = ""
    /// The account being edited: its stored values pass validation unchanged.
    private var original: Account?

    init(currency: Currency = .gbp) {
        region = .forCurrency(currency)
    }

    init(_ account: Account) {
        alias = account.alias ?? ""
        region = account.effectiveBankRegion
        regionChosen = true
        bankName = account.bankName ?? ""
        sortCode = account.sortCode.map(AccountDetailsFormat.formattedSortCode) ?? ""
        accountNumber = account.accountNumber ?? ""
        iban = account.iban.map(AccountDetailsFormat.formattedIBAN) ?? ""
        routingNumber = account.routingNumber ?? ""
        bic = account.bic ?? ""
        original = account
    }

    subscript(field: BankDetailField) -> String {
        get {
            switch field {
            case .bankName: return bankName
            case .sortCode: return sortCode
            case .routingNumber: return routingNumber
            case .accountNumber: return accountNumber
            case .iban: return iban
            case .bic: return bic
            }
        }
        set {
            switch field {
            case .bankName: bankName = newValue
            case .sortCode: sortCode = newValue
            case .routingNumber: routingNumber = newValue
            case .accountNumber: accountNumber = newValue
            case .iban: iban = newValue
            case .bic: bic = newValue
            }
        }
    }

    var details: AccountDetails {
        AccountDetails(alias: alias, sortCode: sortCode, accountNumber: accountNumber, iban: iban,
                       region: region, bankName: bankName, routingNumber: routingNumber, bic: bic)
    }

    var errors: [BankDetailField: AccountDetailsError] { details.errors(existing: original) }
    func error(_ field: BankDetailField) -> String? { errors[field]?.errorDescription }
    var isValid: Bool { errors.isEmpty }
}

/// Alias, then a "Bank details" part: the region picker, bank name, the region's fields and
/// BIC, as rows for a `SheetForm`. A field's validation error shows once the field has lost
/// focus or Return was pressed in it — not while it is being typed in (an edit hides it again
/// until then) — or, with `revealAll`, always (Save was pressed while a field is invalid; the
/// sheet doesn't save then).
struct AccountDetailsFields: View {
    @Binding var draft: AccountDetailsDraft
    var revealAll = false

    @FocusState private var focused: BankDetailField?
    /// Fields whose error may show: left, or submitted, since their last edit.
    @State private var revealed: Set<BankDetailField> = []

    private var region: Binding<BankRegion> {
        Binding(get: { draft.region }, set: { draft.region = $0; draft.regionChosen = true })
    }

    var body: some View {
        LabeledContent("Alias") {
            TextField("Alias", text: $draft.alias, prompt: Text("Optional short name shown in the app"))
                // Inside the cell: a modifier on a row would stop the grid seeing it as a row.
                .onChange(of: focused) { old, _ in
                    if let old { revealed.insert(old) }
                }
                .onChange(of: draft) { old, new in
                    for field in BankDetailField.allCases where old[field] != new[field] { revealed.remove(field) }
                }
        }
        Text("Bank details")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        LabeledContent("Region") {
            Picker("Region", selection: region) {
                ForEach(BankRegion.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).prominentTint()
            .fixedSize()
        }
        LabeledContent("Bank name") { field(.bankName) }
        ForEach(draft.region.fields, id: \.self) { field in
            LabeledContent(BankDetailsFormat.label(field)) { self.field(field) }
        }
        LabeledContent("BIC/SWIFT") { field(.bic) }
    }

    private func prompt(_ field: BankDetailField) -> String {
        switch field {
        case .bankName: return "Optional, e.g. Lloyds Bank"
        case .sortCode: return "30-00-00"
        case .routingNumber: return "021000021"
        case .accountNumber:
            switch draft.region {
            case .uk: return "12345678"
            case .us: return "4 to 17 digits"
            case .europe, .other: return "Account number"
            }
        case .iban: return draft.region == .uk ? "GB29 NWBK 6016 1331 9268 19" : "DE89 3704 0044 0532 0130 00"
        case .bic: return "Optional, e.g. LOYDGB2L"
        }
    }

    private func field(_ field: BankDetailField) -> some View {
        TextField(BankDetailsFormat.label(field), text: $draft[field], prompt: Text(prompt(field)))
            .focused($focused, equals: field)
            .onSubmit { revealed.insert(field) }
            .sheetFieldNote(revealAll || revealed.contains(field) ? draft.error(field) : nil, isError: true)
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
