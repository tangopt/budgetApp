// App/Property/RentReceiptPanel.swift
import SwiftUI
import QuickLook
import BudgetCore
import struct BudgetCore.Transaction

/// A rent receipt beside the Tenancies tab (clicking its row): its status and figures (rent,
/// tax withheld, received, covered by credits), the credits that paid it with Edit transaction
/// and Show in Search, then its PDF — page 1 (click for Quick Look), Open in Preview,
/// Show in Documents, Replace PDF… — or Add the receipt PDF… when it has none.
struct RentReceiptPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let receiptId: Int64
    let tenancyId: Int64
    let openTransaction: (Transaction) -> Void
    let showDocument: (Int64) -> Void
    @Environment(\.theme) private var theme
    @State private var editing: Transaction?
    @State private var documents: [EvidenceDocument] = []
    /// The receipt `documents` were read for (the panel stays as the open receipt changes).
    @State private var documentsReceiptId: Int64?
    @State private var picking = false
    @State private var replacing: [Int64] = []
    @State private var pickingMany = true

    var body: some View {
        let currency = viewModel.currency
        if let row = viewModel.receiptRow(receiptId, tenancyId: tenancyId) {
            let receipt = row.receipt
            PropertySidePanel(title: "Receipt \(receipt.receiptNumber)",
                              subtitle: "Rent for \(DocumentFormat.day(receipt.periodStart).unbroken) – \(DocumentFormat.day(receipt.periodEnd).unbroken)",
                              onClose: { viewModel.sidePanel = nil }) {
                HStack(spacing: 8) {
                    ReceiptStatusHelp.pill(row, currency: currency, snapshot: viewModel.snapshot)
                    if let day = receipt.receiptDate {
                        HStack(spacing: 3) {
                            Text("Received on").foregroundStyle(.secondary)
                            DateText(date: day, font: .caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    PropertyPanelFigure(title: "Rent", minorUnits: receipt.amountMinorUnits, currency: currency, role: .neutral)
                    if receipt.withholdingMinorUnits != 0 {
                        PropertyPanelFigure(title: "Tax withheld", minorUnits: receipt.withholdingMinorUnits, currency: currency, role: .neutral)
                    }
                    PropertyPanelFigure(title: "Received", minorUnits: receipt.amountReceivedMinorUnits, currency: currency, role: .neutral)
                    if receipt.status == .issued {
                        PropertyPanelFigure(title: "Left to link", minorUnits: max(0, receipt.amountReceivedMinorUnits - row.paidMinorUnits),
                                            currency: currency, role: .neutral, isTotal: true)
                    }
                }
                List {
                    Section {
                        if row.payments.isEmpty {
                            Text(receipt.status == .cancelled ? "Cancelled: no credit expected." : "No credit linked yet: Match credits (in More).")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(row.payments, id: \.payment.id) { info in
                            PropertyPanelTransactionRow(
                                transaction: info.transaction, minorUnits: info.transaction.amountMinorUnits, currency: currency,
                                note: info.payment.otherMinorUnits > 0
                                    ? "Incl. \(Money.format(info.payment.otherMinorUnits, currency: currency).unbroken) other (utility recharges and the like)"
                                    : nil,
                                onEdit: { editing = $0 }, onShow: openTransaction)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Paid by", minorUnits: row.paidMinorUnits, currency: currency)
                    }
                    Section {
                        pdfSection(row)
                    } header: {
                        Text(row.documentCount > 1 ? "Receipt PDFs" : "Receipt PDF")
                    }
                }
                .wrapProbeClips()
            }
            .sheet(item: $editing) { PropertyEditTransactionSheet(transaction: $0, dbQueue: viewModel.dbQueue) }
            .fileImporter(isPresented: $picking, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: pickingMany) { result in
                let replaced = replacing
                replacing = []
                switch result {
                case .success(let urls): viewModel.addDocuments(urls, to: .rentReceipt(receiptId), role: "Receipt", replacing: replaced)
                case .failure(let error): viewModel.errorMessage = error.localizedDescription
                }
            }
            // Read off the main thread when the receipt changes or its links do (a PDF added,
            // replaced or unlinked).
            .task(id: DocumentsKey(receiptId: receiptId, documentIds: row.documentIds)) {
                let loaded = await viewModel.loadDocuments(for: .rentReceipt(receiptId))
                guard !Task.isCancelled else { return }
                documents = loaded
                documentsReceiptId = receiptId
            }
        } else {
            PropertySidePanel(title: "Receipt", onClose: { viewModel.sidePanel = nil }) {
                Text("The receipt no longer exists.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private struct DocumentsKey: Equatable {
        let receiptId: Int64
        let documentIds: [Int64]
    }

    /// Opens the file picker: one file when replacing, any number when adding.
    private func pick(replacing ids: [Int64]) {
        replacing = ids
        pickingMany = ids.isEmpty
        picking = true
    }

    @ViewBuilder
    private func pdfSection(_ row: TenancyReceiptRow) -> some View {
        let number = row.receipt.receiptNumber
        // Another receipt's documents (just switched; this one's are being read): the
        // thumbnail's place, loading.
        let documents = documentsReceiptId == receiptId ? documents : []
        if documents.isEmpty, documentsReceiptId != receiptId, row.documentCount > 0 {
            ProgressView().frame(maxWidth: .infinity).frame(height: 200)
        } else if documents.isEmpty {
            if row.receipt.status == .cancelled {
                Text("Cancelled: no PDF needed.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dashed").foregroundStyle(theme.pending).accessibilityHidden(true)
                        Text("No receipt PDF yet.").foregroundStyle(.secondary)
                    }
                    Button("Add the receipt PDF…") { pick(replacing: []) }
                        .controlSize(.small)
                        .help("Download it from Portal das Finanças, then choose the file")
                        .accessibilityLabel("Add the PDF of receipt \(number)")
                }
            }
        } else {
            ForEach(documents) { document in
                VStack(alignment: .leading, spacing: 6) {
                    DocumentThumbnail(url: viewModel.fileURL(for: document), height: 200)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("The PDF of receipt \(number): Quick Look")
                    Text(document.displayName).font(.callout).lineLimit(1).truncationMode(.middle).help(document.displayName)
                    HStack(spacing: 8) {
                        Button("Open in Preview") { viewModel.openInPreview(document) }
                            .help("Open \(document.displayName) in Preview")
                            .accessibilityLabel("Open the PDF of receipt \(number) in Preview")
                        Button("Show in Documents") { document.id.map(showDocument) }
                            .help("Show \(document.displayName) on the Documents screen: its details and links")
                            .accessibilityLabel("Show the PDF of receipt \(number) in Documents")
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                if documents.count == 1 {
                    Button("Replace PDF…") { pick(replacing: documents.compactMap(\.id)) }
                        .help("Choose another file for this receipt; the current one is unlinked and stays in the library")
                        .accessibilityLabel("Replace the PDF of receipt \(number)")
                }
                Button("Add another PDF…") { pick(replacing: []) }
                    .help("Link one more file to this receipt")
                    .accessibilityLabel("Add another PDF to receipt \(number)")
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// A receipt's PDF in the Tenancies table (the tax sources' paperclip): one document — a
/// paperclip that previews it in Quick Look, right-click for Open in Preview and Show in
/// Documents; several — a paperclip and their count, a menu of them. Documents are read when
/// acted on (or when the menu opens), not when the table draws.
struct ReceiptPDFButton: View {
    let receiptNumber: String
    let count: Int
    let documents: () -> [EvidenceDocument]
    let preview: (EvidenceDocument) -> Void
    let openInPreview: (EvidenceDocument) -> Void
    let show: (EvidenceDocument) -> Void

    var body: some View {
        if count == 1 {
            Button { documents().first.map(preview) } label: {
                Image(systemName: "paperclip")
                    .frame(width: 24, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Preview the receipt PDF (Quick Look); right-click for Open in Preview and Show in Documents")
            .accessibilityLabel("Open the PDF of receipt \(receiptNumber)")
            .contextMenu {
                Button("View receipt PDF") { documents().first.map(preview) }
                Button("Open in Preview") { documents().first.map(openInPreview) }
                Button("Show in Documents") { documents().first.map(show) }
            }
        } else {
            Menu {
                let all = documents()
                ForEach(all) { document in
                    Button(document.displayName) { preview(document) }
                }
                if let first = all.first {
                    Divider()
                    Button("Open \(first.displayName) in Preview") { openInPreview(first) }
                    Button("Show \(first.displayName) in Documents") { show(first) }
                }
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: "paperclip")
                    Text("\(count)").monospacedDigit().figureText()
                }
                .font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(count) PDFs for this receipt: choose one to preview")
            .accessibilityLabel("Open one of the \(count) PDFs of receipt \(receiptNumber)")
        }
    }
}
