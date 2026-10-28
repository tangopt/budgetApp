import SwiftUI
import BudgetCore

/// Add account on the iPad (step 11, Task 3): name, kind, currency, bank details, how the balance is kept, Count toward net
/// worth, the opening balance and its day, and (for the household's admin only) Joint. Saved only with Add account; Cancel
/// writes nothing. A refusal shows at the top and the form stays.
struct PadAddAccountSheet: View {
    @ObservedObject var model: PadAccountFormModel
    var onSaved: (Int64?) -> Void = { _ in }

    var body: some View {
        PadAccountFormScaffold(model: model, title: "Add account", button: "Add account", onSaved: onSaved) {
            Section("Account") {
                nameField
                Picker("Currency", selection: Binding(get: { model.currency }, set: { model.setCurrency($0) })) {
                    ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .frame(minHeight: 44)
                kindPicker
            }
            Section {
                Toggle("Updated by hand", isOn: $model.updatedByHand).frame(minHeight: 44)
                Toggle("Count toward net worth", isOn: $model.includeInNetWorth).frame(minHeight: 44)
                if model.showsJointToggle {
                    Toggle(SharingCopy.addJointLabel, isOn: $model.joint).frame(minHeight: 44)
                        .accessibilityIdentifier("account-joint")
                }
            } footer: {
                Text(model.showsJointToggle ? SharingCopy.addJointNote : "How the balance is kept: by hand, or from statements.")
            }
            Section {
                LabeledContent(model.kind == .credit ? "Amount owed" : "Opening balance") {
                    TextField("Optional", text: $model.balanceText)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("account-opening-balance")
                }
                .frame(minHeight: 44)
                if let error = model.balanceError { Text(error).font(.footnote).foregroundStyle(.red) }
                if !model.balanceText.trimmingCharacters(in: .whitespaces).isEmpty {
                    DatePicker("As of", selection: $model.asOf, in: ...Date(), displayedComponents: .date).frame(minHeight: 44)
                }
            } footer: {
                Text(model.kind == .credit
                     ? "Enter what you owe on the card as a positive number. Transactions after that day are added to it."
                     : "Transactions after that day are added to it. Leave empty to start from zero.")
            }
            PadAccountBankSection(model: model)
        }
    }

    private var nameField: some View {
        PadAccountNameField(model: model)
    }

    private var kindPicker: some View {
        PadAccountKindPicker(model: model)
    }
}

/// Edit details on the iPad: name, kind (no move to or from credit once the account has a history), Count toward net worth,
/// the bank details, and, for the account's owner, Sharing. No delete or archive here: a set-aside account is one that
/// doesn't count toward net worth, and Delete stays on the Mac.
struct PadEditAccountSheet: View {
    @ObservedObject var model: PadAccountFormModel
    var onSaved: (Int64?) -> Void = { _ in }

    var body: some View {
        PadAccountFormScaffold(model: model, title: "Edit account", button: "Save", onSaved: onSaved) {
            Section("Account") {
                PadAccountNameField(model: model)
                if case .edit(let account) = model.mode {
                    LabeledContent("Currency") { Text(account.currency.rawValue.uppercased()) }.frame(minHeight: 44)
                }
                PadAccountKindPicker(model: model)
            }
            Section {
                Toggle("Count toward net worth", isOn: $model.includeInNetWorth).frame(minHeight: 44)
            } footer: {
                Text("Switch it off to set an account aside. Deleting an account is done on the Mac.")
            }
            PadAccountBankSection(model: model)
            if model.showsSharing { PadAccountSharingSection(model: model) }
        }
    }
}

// MARK: - Shared pieces

/// The form's frame: the refusal and the problems at the top, Cancel and Save. Nothing is written on dismiss.
private struct PadAccountFormScaffold<Content: View>: View {
    @ObservedObject var model: PadAccountFormModel
    let title: String
    let button: String
    let onSaved: (Int64?) -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: model.write.message(for: PadAccountFormModel.rowId)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                content
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(button) {
                        Task {
                            if await model.save() {
                                onSaved(model.addedId)
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canPressSave)
                    .accessibilityIdentifier("account-save")
                }
            }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.isSaving)
    }
}

private struct PadAccountNameField: View {
    @ObservedObject var model: PadAccountFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Name") {
                TextField("Name", text: $model.name, prompt: Text("Name")).multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 44)
                .accessibilityIdentifier("account-name")
            if let error = model.nameError { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }
}

private struct PadAccountKindPicker: View {
    @ObservedObject var model: PadAccountFormModel

    var body: some View {
        Picker("Kind", selection: $model.kind) {
            ForEach(model.kindChoices, id: \.self) { Text(PadAccountDetailView.kindTitle($0)).tag($0) }
        }
        .frame(minHeight: 44)
    }
}

/// Alias, the region and the region's bank fields; a field's problem shows under it once it is wrong.
private struct PadAccountBankSection: View {
    @ObservedObject var model: PadAccountFormModel

    var body: some View {
        Section {
            LabeledContent("Alias") {
                TextField("Alias", text: text(\.alias), prompt: Text("Optional")).multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 44)
            Picker("Region", selection: Binding(get: { model.details.region ?? .uk }, set: { model.setRegion($0) })) {
                ForEach(BankRegion.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(minHeight: 44)
            ForEach(model.details.activeFields, id: \.self) { field in fieldRow(field) }
        } header: {
            Text("Bank details")
        }
    }

    private func fieldRow(_ field: BankDetailField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(BankDetailsFormat.label(field)) {
                TextField(BankDetailsFormat.label(field), text: Binding(get: { model.details[field] ?? "" }, set: { model.details[field] = $0 }),
                          prompt: Text(prompt(field)))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(field == .iban || field == .bic ? .characters : .never)
                    #endif
            }
            .frame(minHeight: 44)
            if let error = model.detailError(field) { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func text(_ path: WritableKeyPath<AccountDetails, String?>) -> Binding<String> {
        Binding(get: { model.details[keyPath: path] ?? "" }, set: { model.details[keyPath: path] = $0 })
    }

    private func prompt(_ field: BankDetailField) -> String {
        switch field {
        case .bankName: return "Optional, e.g. Lloyds Bank"
        case .sortCode: return "30-00-00"
        case .routingNumber: return "021000021"
        case .accountNumber:
            switch model.details.region ?? .uk {
            case .uk: return "12345678"
            case .us: return "4 to 17 digits"
            case .europe, .other: return "Account number"
            }
        case .iban: return "GB29 NWBK 6016 1331 9268 19"
        case .bic: return "Optional, e.g. LOYDGB2L"
        }
    }
}

/// The account's own Sharing section: the owner (only the admin moves an account between hers and Joint) and the level (only
/// its owner). Lowering says what it stops and how many records move; a blocker says why Hidden can't be saved yet.
private struct PadAccountSharingSection: View {
    @ObservedObject var model: PadAccountFormModel

    private struct PreviewKey: Equatable {
        var joint: Bool
        var level: SharingLevel
    }

    var body: some View {
        Section {
            if model.showsOwnerPicker, let state = model.context.sharing {
                Picker(SharingCopy.ownerLabel, selection: Binding(get: { model.sharingJoint }, set: { model.setSharingJoint($0) })) {
                    Text(state.ownerName.isEmpty ? "Mine" : state.ownerName).tag(false)
                    Text(SharingCopy.jointChoice).tag(true)
                }
                .frame(minHeight: 44)
            }
            if model.showsLevelPicker {
                Picker(SharingCopy.levelLabel, selection: $model.sharingLevel) {
                    ForEach(SharingLevel.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                }
                .frame(minHeight: 44)
            } else if model.sharingJoint {
                Text(SharingCopy.jointLevelNote).foregroundStyle(.secondary)
            }
            if let warning = model.loweringWarning() {
                VStack(alignment: .leading, spacing: 6) {
                    if let count = model.preview?.affectedCount, count > 0 { Text(SharingCopy.moves(count: count)).font(.subheadline.weight(.semibold)) }
                    Text(warning).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let preview = model.preview, preview.affectedCount > 0 {
                Text(SharingCopy.moves(count: preview.affectedCount)).font(.subheadline).foregroundStyle(.secondary)
            }
            if model.preview?.isBlocked == true {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SharingCopy.blockedNote).font(.footnote).foregroundStyle(.secondary)
                    ForEach(model.blockerLines(), id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                }
            }
            if model.context.sharing?.isConfirmed == false, model.sharingChange != nil {
                Text(SharingCopy.confirmsDefaultsNote).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(SharingCopy.sectionTitle)
        }
        .task(id: PreviewKey(joint: model.sharingJoint, level: model.sharingLevel)) { await model.refreshPreview() }
    }
}
