import SwiftUI
import BudgetCore

/// A pill by tone, as the iPad's screens name them; drawn by the shared `StatusPill` (word on a status-role tint):
/// neutral = neutral, accent = to do, warning = waiting, positive = done.
struct PadStatusPill: View {
    enum Tone {
        case neutral, accent, warning, positive

        var status: StatusPill.Status {
            switch self {
            case .neutral: .neutral
            case .accent: .todo
            case .warning: .waiting
            case .positive: .done
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View { StatusPill(text, tone.status) }
}

extension PadBillsAndRechargesModel {
    /// The pill a statement shows.
    func pill(for statement: Statement) -> (text: String, tone: PadStatusPill.Tone) {
        switch statement.statement.status {
        case .draft: ("Draft", .neutral)
        case .paid: ("Paid", .positive)
        case .sent:
            if statement.row.payments.reduce(0, { $0 + $1.amountMinorUnits }) != 0 { ("Part paid", .warning) }
            else if isOverdue(statement) { ("Overdue", .warning) }
            else { ("Sent", .accent) }
        }
    }

    func monthTitle(_ statement: Statement) -> String {
        RechargeEmail.monthName(statement.statement.month, language: .english)
    }
}

/// The statements below the grid: month, total and status pill; "Prepare email" on the draft; a tap opens the statement.
struct PadStatementsList: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var write: PadWriteModel
    let open: (PadBillsAndRechargesModel.Statement) -> Void
    let prepareEmail: (PadBillsAndRechargesModel.Statement) -> Void
    let choosePayment: (PadBillsAndRechargesModel.Statement) -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Statements").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            if model.statements.isEmpty {
                Text("No statements yet.").foregroundStyle(.secondary)
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(model.statements.enumerated()), id: \.element.id) { index, statement in
                            if index > 0 { MangoDivider() }
                            row(statement)
                        }
                    }
                }
            }
        }
    }

    private func row(_ statement: PadBillsAndRechargesModel.Statement) -> some View {
        let pill = model.pill(for: statement)
        let name = model.monthTitle(statement)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open(statement) } label: {
                    HStack(spacing: 12) {
                        Text(name.figuresUnbroken).mangoFont(.body, weight: .medium).lineLimit(1)
                        PadStatusPill(text: pill.text, tone: pill.tone)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: statement.statement.totalMinorUnits, currency: model.currency, role: .neutral)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) statement, \(pill.text)")
                .accessibilityHint("Opens the statement")
                trailing(statement, name: name)
            }
            if statement.statement.status == .sent {
                HStack(spacing: 8) {
                    Text("Still owed").mangoFont(.footnote).foregroundStyle(.secondary)
                    MoneyText(minorUnits: statement.row.outstandingMinorUnits, currency: model.currency, role: .neutral, font: .footnote)
                }
            }
            PadRefusalBanner(message: write.message(for: statement.rowId))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func trailing(_ statement: PadBillsAndRechargesModel.Statement, name: String) -> some View {
        if let action = model.listAction(for: statement) {
            switch action {
            case .prepareEmail:
                Button(action.title) { prepareEmail(statement) }
                    .buttonStyle(.pad(.secondary, size: .small))
                    .accessibilityLabel("\(action.title), \(name)")
            case .recordPayment:
                RowIconButton(.recordPayment, item: "\(name) statement", size: .small) { choosePayment(statement) }
            default:
                EmptyView()
            }
        }
        RowIconButton(.view, item: "\(name) statement", size: .small) { open(statement) }
    }
}

/// One statement opened in the side panel (from the list, a bill, or the summary's difference): its charges, the bank credits that pay it
/// (each with Unlink), the credits that might, and the actions its status offers; a draft's Prepare email opens
/// `PrepareEmailSheet` over it.
struct PadStatementSheet: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var write: PadWriteModel
    let statementId: Int64
    let choosePayment: (PadBillsAndRechargesModel.Statement) -> Void
    let onClose: () -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.documentPanelSource) private var documentSource
    @State private var confirmsDelete = false
    @State private var emailing = false

    var body: some View {
        PadSidePanel(title: model.statements.first { $0.id == statementId }.map(model.monthTitle) ?? "Statement", onClose: onClose) {
            PadWriteNotices(write: write)
            if let statement = model.statements.first(where: { $0.id == statementId }) {
                content(statement)
            } else {
                Text("This statement is gone.").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $emailing) {
            PrepareEmailSheet(model: model.prepareEmailModel(statementId: statementId, open: documentSource?.open), write: write)
        }
    }

    @ViewBuilder
    private func content(_ statement: PadBillsAndRechargesModel.Statement) -> some View {
        let pill = model.pill(for: statement)
        let currency = model.currency
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PadStatusPill(text: pill.text, tone: pill.tone)
            Spacer(minLength: 8)
            MoneyText(minorUnits: statement.statement.totalMinorUnits, currency: currency, role: .neutral, font: .title2.weight(.semibold))
        }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Charges").mangoFont(.headline)
                if statement.lines.isEmpty { Text("No charges yet.").foregroundStyle(.secondary) }
                ForEach(statement.lines, id: \.line.id) { detail in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.provider?.name ?? detail.line.lineDescription ?? "Line").mangoFont(.subheadline)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: detail.line.amountMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                    }
                }
                if statement.statement.status == .sent {
                    MangoDivider()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Still owed").mangoFont(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: statement.row.outstandingMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !statement.row.payments.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paid by the tenant").mangoFont(.headline)
                    ForEach(statement.row.payments) { payment in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(statement.credits[payment.transactionId]?.rawDescription ?? "Bank credit")
                                    .mangoFont(.subheadline).lineLimit(1).truncationMode(.middle)
                                if let date = statement.credits[payment.transactionId]?.date { DateText(date, font: .footnote).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            MoneyText(minorUnits: payment.amountMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                            if write.canEdit {
                                RowIconButton(.unlink, item: "payment, \(model.monthTitle(statement)) statement") {
                                    Task { await model.unlink(statement, payment: payment) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        actions(statement)
        PadRefusalBanner(message: write.message(for: statement.rowId))
    }

    @ViewBuilder
    private func actions(_ statement: PadBillsAndRechargesModel.Statement) -> some View {
        let offered = model.actions(for: statement)
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(offered, id: \.self) { action in
                    switch action {
                    case .prepareEmail:
                        Button(action.title) { emailing = true }.buttonStyle(.pad(.primary))
                    case .markSent:
                        Button(action.title) { Task { await model.markSent(statement) } }.buttonStyle(.pad(.secondary))
                    case .recordPayment:
                        Button(action.title) { choosePayment(statement) }.buttonStyle(.pad(.secondary))
                    case .reopen:
                        Button(action.title) { Task { await model.reopen(statement) } }.buttonStyle(.pad(.secondary))
                    case .deleteStatement:
                        Button(action.title) { confirmsDelete = true }.buttonStyle(.pad(.destructive))
                            .confirmationDialog("Delete the \(model.monthTitle(statement)) statement?", isPresented: $confirmsDelete,
                                                titleVisibility: .visible) {
                                Button("Delete statement", role: .destructive) { Task { await model.delete(statement) } }
                            }
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}
