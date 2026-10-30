import SwiftUI
import BudgetCore
#if canImport(UIKit)
import UIKit
#endif

/// The sheet the Downloads tray's Check opens (`BrowserView`): builds the model for one tray file and reads it.
struct CheckAndLinkHost: View {
    @State private var model: CheckAndLinkModel
    let showsLivePreview: Bool
    let onClose: () -> Void

    init(item: TrayItem, tray: DownloadsTray, source: CheckAndLinkSource, showsLivePreview: Bool = true, onClose: @escaping () -> Void) {
        _model = State(initialValue: CheckAndLinkModel(item: item, tray: tray, engine: source.engine, writer: source.writer,
                                                       statements: source.statements))
        self.showsLivePreview = showsLivePreview
        self.onClose = onClose
    }

    var body: some View {
        CheckAndLinkSheet(model: model, showsLivePreview: showsLivePreview, onClose: onClose)
            .task { await model.start() }
            #if os(iOS)
            .presentationSizing(.page)
            #endif
    }
}

/// Check and link (step 10, Task 8), as agreed in the mockup. Cancel / "Check and link" / Save across the top. Left: the
/// PDF (pinch to zoom). Right: The document (fields read from the PDF are marked "read"; the ones Save will count as
/// checked are marked "to check"), Paid by (the suggested payment, "Linked"), and Recharge (the tenant's share and the
/// statement it joins). Nothing is saved until Save; a refusal shows under the header and the file stays in the tray.
struct CheckAndLinkSheet: View {
    @Bindable var model: CheckAndLinkModel
    /// False in the snapshot routes: the page as a still picture (Quick Look draws nothing there).
    var showsLivePreview = true
    let onClose: () -> Void
    @State private var choosing: PadChoiceRequest?
    @Environment(\.phoneTheme) private var theme

    /// The two columns need this much; narrower, the PDF sits above the fields.
    static let sideBySideWidth: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                if proxy.size.width >= Self.sideBySideWidth {
                    HStack(spacing: 0) {
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        fields.frame(width: min(480, proxy.size.width * 0.5))
                    }
                } else {
                    VStack(spacing: 0) {
                        preview.frame(height: min(300, proxy.size.height * 0.4))
                        Divider()
                        fields
                    }
                }
            }
        }
        .background(theme.background)
        .sheet(item: $choosing) { PadChoiceSheet(request: $0) }
        .interactiveDismissDisabled(model.isWorking)
        .onDisappear { model.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel") { close() }
                .buttonStyle(.pad(.textLink))
            Spacer(minLength: 8)
            Text(CheckAndLinkSheetCopy.title).mangoFont(.headline).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if case .saved = model.phase {
                if model.importedRunId != nil {
                    Button(PadStatementImportCopy.undo) { Task { await model.undoImport() } }
                        .buttonStyle(.pad(.secondary))
                        .disabled(model.isWorking)
                }
                Button("Done") { close() }.buttonStyle(.pad(.primary))
            } else if model.route == .ownerImports {
                // A member's iPad: nothing to press (the note says where statements are imported).
                EmptyView()
            } else if let route = model.route, route != .sendToMac {
                // Step 19: a bank statement imported here, under the household's import lease.
                Button { Task { await model.importStatement() } } label: {
                    if model.isWorking { ProgressView().tint(.white) } else { Text(PadStatementImportCopy.importButton) }
                }
                .buttonStyle(.pad(.primary))
                .disabled(!model.canImport)
            } else {
                Button { Task { await model.save() } } label: {
                    if model.isWorking { ProgressView().tint(.white) } else { Text(model.route == .sendToMac ? PadStatementImportCopy.sendToMac : "Save") }
                }
                .buttonStyle(.pad(.primary))
                .disabled(!model.canSave)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func close() {
        model.cancel()
        onClose()
    }

    // MARK: The PDF

    private var preview: some View {
        VStack(spacing: 8) {
            Group {
                #if canImport(UIKit)
                if showsLivePreview {
                    PadDocumentPreview(url: model.fileURL)
                } else {
                    DocumentThumbnailImage(url: model.fileURL).padding(12)
                }
                #else
                Image(systemName: "doc.text").mangoFont(.largeTitle).foregroundStyle(.secondary)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 6) {
                Image(systemName: "hand.pinch").accessibilityHidden(true)
                Text(CheckAndLinkSheetCopy.pinchToZoom)
            }
            .mangoFont(.caption).foregroundStyle(.secondary)
            Text(model.item.fileName).mangoFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(16)
    }

    // MARK: The fields

    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PadRefusalBanner(message: model.refusal)
                switch model.phase {
                case .reading:
                    HStack(spacing: 8) { ProgressView(); Text("Reading the file…") }
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .failed(let message):
                    InlineBanner(tone: .amber, text: message)
                case .saved(let summary):
                    InlineBanner(tone: .neutral, text: summary)
                    content
                case .ready:
                    content
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let proposal = model.proposal {
            holdBacks(proposal.check)
            documentCard(proposal)
            switch proposal {
            case .utilityBill(let bill):
                paidByCard(bill)
                rechargeCard(bill)
            case .statement(let statement):
                statementCard(statement)
            case .document:
                EmptyView()
            }
        }
    }

    /// What Save will count as checked, what must be answered first, and what isn't held back.
    @ViewBuilder
    private func holdBacks(_ check: CheckAndLinkCheck) -> some View {
        if let of = check.duplicateOf { InlineBanner(tone: .amber, text: CheckAndLinkCopy.alreadyInMango(of)) }
        ForEach(check.blockers, id: \.self) { InlineBanner(tone: .amber, text: $0) }
        if !check.toCheck.isEmpty {
            InlineBanner(tone: .amber, text: CheckAndLinkSheetCopy.checkBeforeSave(check.toCheck))
        }
        ForEach(check.notes, id: \.self) { note in
            Text(note.figuresUnbroken).mangoFont(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func documentCard(_ proposal: CheckAndLinkProposal) -> some View {
        Card(title: "The document") {
            Text("Fields marked “\(CheckAndLinkSheetCopy.readBadge)” were read from the PDF.")
                .mangoFont(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { MangoDivider() }
                CheckRowView(row: row)
            }
            if case .document(let document) = proposal, document.needsKind {
                Menu {
                    ForEach(document.kindChoices, id: \.self) { choice in
                        Button(choice.label) { Task { await model.chooseKind(choice) } }
                    }
                } label: {
                    Label("Choose the kind", systemImage: "list.bullet").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pad(.secondary))
            }
            if case .document(let document) = proposal, !document.links.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Linked to").foregroundStyle(.secondary)
                    ForEach(document.links, id: \.self) { Text($0.figuresUnbroken).lineLimit(2).truncationMode(.middle) }
                }
            }
        }
    }

    // MARK: Paid by

    private func paidByCard(_ bill: UtilityBillFields) -> some View {
        Card(title: "Paid by") {
            if let paid = bill.paidBy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(paid.description).mangoFont(.body, weight: .semibold).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        linkedBadge
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            DateText(paid.date, font: .subheadline)
                            MoneyText(minorUnits: paid.amountMinorUnits, currency: paid.currency, role: .neutral, font: .subheadline)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            DateText(paid.date, font: .subheadline)
                            MoneyText(minorUnits: paid.amountMinorUnits, currency: paid.currency, role: .neutral, font: .subheadline)
                        }
                    }
                    .foregroundStyle(.secondary)
                    if let reason = paid.reasons.first {
                        Text(reason.figuresUnbroken).mangoFont(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(CheckAndLinkSheetCopy.noPaymentFound).foregroundStyle(.secondary)
            }
            Button(CheckAndLinkSheetCopy.notThisOne) { choosePayment(bill) }
                .buttonStyle(.pad(.textLink))
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.isWorking)
        }
    }

    private var linkedBadge: some View {
        Label(CheckAndLinkSheetCopy.linked, systemImage: "link")
            .mangoFont(.caption, weight: .semibold).foregroundStyle(theme.accent)
            .lineLimit(1).fixedSize()
    }

    private func choosePayment(_ bill: UtilityBillFields) {
        let others = bill.paymentChoices.filter { $0.transactionId != bill.paidBy?.transactionId }
        choosing = PadChoiceRequest(
            title: "Paid by", button: CheckAndLinkSheetCopy.useThisOne,
            empty: "No other payments found for this bill.", currency: bill.currency,
            choices: others.map { PadChoice(id: $0.transactionId, title: $0.description, date: $0.date, amountMinorUnits: $0.amountMinorUnits) },
            choose: { id in await model.choosePayment(id) })
    }

    // MARK: Recharge

    @ViewBuilder
    private func rechargeCard(_ bill: UtilityBillFields) -> some View {
        let lines = model.rechargeLines
        if !lines.isEmpty {
            Card(title: "Recharge") {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Tenant’s share").foregroundStyle(.secondary).fixedSize()
                                Spacer(minLength: 8)
                                MoneyText(minorUnits: line.amount, currency: line.currency, role: .neutral)
                                Text("for \(line.who)").lineLimit(1).truncationMode(.middle)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tenant’s share").foregroundStyle(.secondary)
                                MoneyText(minorUnits: line.amount, currency: line.currency, role: .neutral)
                                Text("for \(line.who)").lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if let note = line.note {
                            Text(note.figuresUnbroken).mangoFont(.caption).foregroundStyle(.secondary)
                        }
                        Text(line.goes).mangoFont(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Statements

    private func statementCard(_ statement: StatementImportSummary) -> some View {
        Card(title: "Checks") {
            if statement.checks.isEmpty && statement.balanceMatches {
                Label(CheckAndLinkCopy.balanceMatches, systemImage: "checkmark.circle")
                    .mangoFont(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(statement.checks, id: \.self) { check in
                Label { Text(check.figuresUnbroken).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.pending)
                }
                .mangoFont(.subheadline)
            }
            statementActions(statement)
        }
    }

    /// Step 19: how the statement is imported. Without a route (no import here) Save sends it to the Mac; with one,
    /// Import adds the new rows here (waiting while another device imports, or for a connection), or Send to the Mac.
    @ViewBuilder
    private func statementActions(_ statement: StatementImportSummary) -> some View {
        switch model.route {
        case nil:
            note(CheckAndLinkSheetCopy.statementNote)
        case .sendToMac?:
            note(CheckAndLinkSheetCopy.sendToMacNote)
        case .ownerImports?:
            InlineBanner(tone: .neutral, text: PadStatementImportCopy.ownerImports)
        default:
            if case .saved = model.phase {
                EmptyView()
            } else {
                if let wait = model.importWaitMessage {
                    InlineBanner(tone: .amber, text: wait)
                }
                note(CheckAndLinkSheetCopy.importNote(rows: statement.rowsToAdd, skipped: statement.alreadyImported))
                if model.canFinishOnMac {
                    Button(PadStatementImportCopy.finishOnMac) { Task { await model.save() } }
                        .buttonStyle(.pad(.secondary))
                        .disabled(!model.canSave)
                    note(CheckAndLinkSheetCopy.finishOnMacNote)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One field: label, value, and its mark. A figure keeps one line (the row stacks when it doesn't fit beside its label);
/// a name truncates in the middle.
struct CheckRowView: View {
    let row: CheckRow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                value
                CheckMarkBadge(mark: row.mark)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.label).foregroundStyle(.secondary)
                    CheckMarkBadge(mark: row.mark)
                }
                value
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var value: some View {
        if row.isFigure {
            Text(row.value).figureText()
        } else {
            Text(row.value).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "read" (taken from the PDF) or "to check" (Save counts it as checked), as words, not colour alone.
struct CheckMarkBadge: View {
    let mark: CheckRow.Mark
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        switch mark {
        case .none:
            EmptyView()
        case .read:
            Text(CheckAndLinkSheetCopy.readBadge)
                .mangoFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        case .toCheck:
            Label(CheckAndLinkSheetCopy.toCheckBadge, systemImage: "exclamationmark.circle")
                .mangoFont(.caption2, weight: .semibold).foregroundStyle(.primary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.pending.opacity(0.2)))
        }
    }
}
