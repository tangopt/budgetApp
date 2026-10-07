// App/Accounts/AccountFormSheets.swift
import SwiftUI
import BudgetCore

/// "+ Add account": name, currency, kind, tracking and an optional opening balance
/// (entered as the amount owed for credit) dated by a picked calendar day.
struct AddAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var currency: Currency = .gbp
    @State private var kind: AccountKind = .cash
    @State private var trackingMode: AccountTrackingMode = .manual
    @State private var balanceText = ""
    @State private var asOf = Date()

    private var trimmedBalance: String { balanceText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var openingBalance: Int? { Money.parseMinorUnits(trimmedBalance) }
    private var balanceInvalid: Bool { !trimmedBalance.isEmpty && openingBalance == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !balanceInvalid
    }

    var body: some View {
        SheetScaffold(title: "Add account", saveTitle: "Add account", canSave: canSave, error: viewModel.errorMessage, onCancel: { dismiss() }, onSave: save) {
            TextField("Name", text: $name)
            Picker("Currency", selection: $currency) {
                ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            KindPicker(selection: $kind)
            TrackingPicker(selection: $trackingMode)
            TextField(kind == .credit ? "Amount owed (optional)" : "Opening balance (optional)", text: $balanceText)
            if kind == .credit {
                SheetCaption("Enter what you owe on the card as a positive number.")
            }
            if balanceInvalid {
                SheetCaption(AccountsFormat.invalidAmountMessage(balanceText), isError: true)
            }
            if !trimmedBalance.isEmpty {
                DatePicker("As of", selection: $asOf, displayedComponents: .date)
            }
        }
        .onAppear { viewModel.errorMessage = nil }
    }

    private func save() {
        guard canSave else { return }
        let balance = trimmedBalance.isEmpty ? nil : openingBalance
        if viewModel.addAccount(name: name, currency: currency, kind: kind, trackingMode: trackingMode, openingBalanceEntered: balance, asOf: AccountsFormat.snapshotDay(asOf)) {
            dismiss()
        }
    }
}

/// "Edit…": name, kind (credit transitions disabled once the account has history),
/// tracking; currency is read-only.
struct EditAccountSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: AccountKind
    @State private var trackingMode: AccountTrackingMode
    @State private var hasHistory = true

    init(viewModel: AccountsViewModel, account: Account) {
        self.viewModel = viewModel
        self.account = account
        _name = State(initialValue: account.name)
        _kind = State(initialValue: account.kind)
        _trackingMode = State(initialValue: account.trackingMode)
    }

    /// Whether switching to `candidate` would cross the credit boundary.
    private func crossesCredit(_ candidate: AccountKind) -> Bool {
        (account.kind == .credit) != (candidate == .credit)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(hasHistory && crossesCredit(kind))
    }

    var body: some View {
        SheetScaffold(title: "Edit account", saveTitle: "Save", canSave: canSave, error: viewModel.errorMessage, onCancel: { dismiss() }, onSave: save) {
            TextField("Name", text: $name)
            LabeledContent("Currency", value: account.currency.rawValue.uppercased())
            KindPicker(selection: $kind, isDisabled: { hasHistory && crossesCredit($0) })
            if hasHistory {
                SheetCaption("Can't change to or from credit once the account has history.")
            }
            TrackingPicker(selection: $trackingMode)
        }
        .onAppear {
            viewModel.errorMessage = nil
            if let id = account.id { hasHistory = viewModel.hasHistory(id) }
        }
    }

    private func save() {
        guard canSave, let id = account.id else { return }
        if viewModel.updateAccount(id: id, name: name, kind: kind, trackingMode: trackingMode) {
            dismiss()
        }
    }
}

// MARK: - Shared pieces

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
