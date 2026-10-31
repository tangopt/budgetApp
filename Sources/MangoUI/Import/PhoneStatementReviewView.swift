import SwiftUI
import BudgetCore

/// The statement screen: what the file is, its account and period, how many rows are new and how many are in Mango
/// already, the balance check, what to look at, and the one primary action for the state it is in (`StatementCard`).
struct PhoneStatementReviewView: View {
    @Bindable var model: PhoneImportModel
    let file: PhoneImportBatch.File
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.phoneTheme) private var theme

    private var statement: StatementImportSummary? { model.statement }
    private var card: PhoneImportModel.StatementCard? { model.statementCard }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.m) {
                    header
                    if let statement {
                        if let refusal = model.review?.refusal { InlineBanner(tone: .amber, text: refusal) }
                        note
                        details(statement)
                        counts(statement)
                        balance(statement)
                        warnings(statement)
                    }
                }
                .padding(MangoSpacing.m)
            }
            bottom
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            Text(file.name).mangoFont(.title3, weight: .bold).lineLimit(1).truncationMode(.middle)
            StatusPill("Statement", .neutral)
        }
        .accessibilityElement(children: .combine)
    }

    private func details(_ statement: StatementImportSummary) -> some View {
        Card {
            accountRow(statement)
            if let period = model.review?.rows.first(where: { $0.label == "Period" }) {
                Divider()
                ImportCheckRow(period)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ statement: StatementImportSummary) -> some View {
        let detected = statement.accountId != nil
        Menu {
            ForEach(model.accountChoices) { account in
                Button(account.name) { Task { await model.chooseAccount(account.id) } }
            }
        } label: {
            ImportFieldRow(label: "Account", pill: detected ? (PhoneImportCopy.detected, .done) : nil) {
                HStack(spacing: 4) {
                    Text(statement.accountName?.value ?? PhoneImportCopy.chooseAccount)
                        .mangoFont(.body)
                        .foregroundStyle(detected ? Color.primary : theme.accent)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").mangoFont(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.accountChoices.isEmpty)
        .accessibilityHint("Changes the account")
    }

    private func counts(_ statement: StatementImportSummary) -> some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MangoSpacing.tile))
            : AnyLayout(HStackLayout(spacing: MangoSpacing.tile))
        return layout {
            ImportCountTile(count: statement.rowsToAdd, caption: statement.rowsToAdd == 1 ? "new row" : "new rows")
            ImportCountTile(count: statement.alreadyImported, caption: "already in Mango")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func balance(_ statement: StatementImportSummary) -> some View {
        Card {
            if let opening = statement.openingBalance?.value {
                FigureRow(label: "Opening balance") {
                    MoneyText(minorUnits: opening, currency: statement.currency, role: .balance, fit: .shrink())
                }
            }
            if let closing = statement.closingBalance?.value {
                if statement.openingBalance != nil { Divider() }
                FigureRow(label: "Closing balance") {
                    MoneyText(minorUnits: closing, currency: statement.currency, role: .balance, fit: .shrink())
                }
                Divider()
                ImportFieldRow(label: "Balance check", pill: statement.balanceMatches ? ("Matches", .done) : ("Doesn’t match", .problem)) {
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func warnings(_ statement: StatementImportSummary) -> some View {
        let lines = statement.checks + statement.check.blockers.filter { !statement.checks.contains($0) } + statement.check.notes
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                ForEach(lines, id: \.self) { InlineBanner(tone: .amber, text: $0) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var note: some View {
        switch card {
        case .allAlreadyIn(let rows):
            InlineBanner(tone: .neutral, text: PhoneImportBatchCopy.allAlreadyIn(rows))
        case .heldByOther(let message), .offline(let message):
            InlineBanner(tone: .amber, text: message)
        case .sendToMac:
            InlineBanner(tone: .neutral, text: PadStatementImportCopy.noImportAccess)
        case .ownerImports:
            InlineBanner(tone: .neutral, text: PadStatementImportCopy.ownerImports)
        case .confirmAccount(let detected, let preset):
            VStack(alignment: .leading, spacing: 0) {
                InlineBanner(tone: .amber, text: PhoneImportCopy.detectedFor(detected, preset: preset))
                Button(PhoneImportCopy.useAccount(detected)) { model.confirmDetectedAccount() }
                    .buttonStyle(ImportTextButtonStyle())
            }
        default:
            EmptyView()
        }
    }

    // MARK: Primary action

    private var bottom: some View {
        ImportBottomBar {
            switch card {
            case .importReady(let rows):
                primary(PhoneImportCopy.importRows(rows), enabled: model.canImportStatement) { await model.importStatement() }
            case .heldByOther, .offline:
                primary(PhoneImportCopy.importRows(statement?.rowsToAdd ?? 0), enabled: false) {}
                Button(PhoneImportCopy.checkAgain) { Task { await model.checkAgain() } }.buttonStyle(ImportTextButtonStyle())
            case .sendToMac:
                primary(PadStatementImportCopy.sendToMac, enabled: model.canSendToMac) { await model.sendToMac() }
            case .allAlreadyIn:
                primary(PhoneImportBatchCopy.doneWithFile, enabled: !model.isWorking) { await model.doneWithFile() }
            case .needsAccount, .confirmAccount, .blocked:
                primary(PhoneImportCopy.importRows(statement?.rowsToAdd ?? 0), enabled: false) {}
            case .ownerImports, nil:
                EmptyView()
            }
            if card != .allAlreadyIn(rows: statement?.alreadyImported ?? 0) {
                Button(PhoneImportCopy.notNow) { Task { await model.skipCurrent() } }
                    .buttonStyle(ImportTextButtonStyle())
                    .disabled(model.isWorking)
            }
        }
    }

    private func primary(_ title: String, enabled: Bool, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            if model.isWorking { ProgressView().tint(theme.onAccent) } else { Text(title) }
        }
        .buttonStyle(ImportPrimaryButtonStyle())
        .disabled(!enabled)
    }
}
