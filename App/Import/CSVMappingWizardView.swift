// App/Import/CSVMappingWizardView.swift
import SwiftUI
import BudgetCore

/// The CSV column-mapping sheet: pick a role for each column straight from the file, with
/// a live check of the whole file and a preview of the transactions it would import.
/// Opens prefilled from `existingProfile` when editing, otherwise from the header names.
struct CSVMappingWizardView: View {
    let account: Account
    let onSave: (ImportProfile) -> Void

    @StateObject private var model: CSVMappingModel
    @State private var showUnreadable = false
    /// Set when Save is pressed while something is still missing; cleared on the next change.
    @State private var saveAttemptMessage: String?
    @Environment(\.dismiss) private var dismiss

    private static let unreadableListLimit = 10

    init(account: Account, csvText: String, existingProfile: ImportProfile?, onSave: @escaping (ImportProfile) -> Void) {
        self.account = account
        self.onSave = onSave
        _model = StateObject(wrappedValue: CSVMappingModel(account: account, csvText: csvText, existingProfile: existingProfile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Map columns — \(account.name)")
                    .font(.title2.weight(.semibold))
                Text("Choose what each column holds. Columns set to Ignore aren't imported.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    CSVMappingTable(model: model)
                    optionsRow
                    Divider()
                    CSVMappingPreview(transactions: previewTransactions, currency: model.currency, showsBalance: showsBalanceInPreview)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Divider()
            buttonRow
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 720)
        .onChange(of: model.check) { saveAttemptMessage = nil }
        .onChange(of: model.effectiveDateFormat) { saveAttemptMessage = nil }
    }

    // MARK: - Options row

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                dateFormatControls
                if model.hasSignedAmountColumn {
                    Toggle("Flip sign", isOn: $model.negateAmounts)
                        .toggleStyle(.checkbox)
                        .help("For banks that export spending as positive numbers.")
                }
                Spacer(minLength: 0)
            }
            if model.noFormatMatches {
                Text("None of the usual date formats reads every date in this column. Type the format, e.g. dd/MM/yyyy.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            liveCheck
        }
    }

    private var dateFormatControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Picker("Date format", selection: $model.selectedDateFormat) {
                ForEach(model.dateFormatCandidates, id: \.self) { format in
                    Text(format).tag(Optional(format))
                }
                if !model.dateFormatCandidates.isEmpty { Divider() }
                Text("Custom…").tag(String?.none)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if model.selectedDateFormat == nil {
                TextField("e.g. dd/MM/yyyy", text: $model.customDateFormat)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
    }

    @ViewBuilder
    private var liveCheck: some View {
        switch model.check {
        case .missing(let roles):
            Label("Still needed: \(CSVMappingModel.missingDescription(roles))", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .parsed(let rowCount, let unreadable, _):
            if unreadable.isEmpty {
                Label("\(rowsRead(rowCount)), 0 problems", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label("\(rowsRead(rowCount)), \(unreadable.count) can't be read", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Button(showUnreadable ? "Hide" : "Show") { showUnreadable.toggle() }
                            .buttonStyle(.link)
                    }
                    if showUnreadable {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(unreadable.prefix(Self.unreadableListLimit).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .textSelection(.enabled)
                            }
                            if unreadable.count > Self.unreadableListLimit {
                                Text("…and \(unreadable.count - Self.unreadableListLimit) more")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
        }
    }

    private func rowsRead(_ count: Int) -> String {
        count == 1 ? "1 row read" : "\(count) rows read"
    }

    private var previewTransactions: [ParsedTransaction] {
        if case .parsed(_, _, let preview) = model.check { return preview }
        return []
    }

    private var showsBalanceInPreview: Bool {
        model.allowBalance && model.mapping.roles.contains(.balance)
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 12) {
            if let saveAttemptMessage {
                Text(saveAttemptMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save mapping") {
                if let profile = model.makeProfile() {
                    onSave(profile)
                } else {
                    saveAttemptMessage = model.saveBlocker
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
