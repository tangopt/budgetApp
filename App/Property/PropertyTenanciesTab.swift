// App/Property/PropertyTenanciesTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import struct BudgetCore.Transaction

/// The Tenancies tab (spec 2026-10-16 §1, §2): each tenancy's terms, rent history, contract
/// documents and receipts — status, the credits that paid each one, its PDF — with New
/// tenancy…, Edit…, Import receipts… and Match credits.
struct PropertyTenanciesTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void

    @State private var editing: TenancyDraft?
    @State private var importing = false
    @State private var intakingInvoices = false
    @State private var deleting: Tenancy?
    /// The record Add document… adds to (kept until the importer completes).
    @State private var documentTarget: (entity: EvidenceEntity, role: String)?
    @State private var pickingDocument = false
    @State private var documentsOf: DocumentsTarget?

    struct DocumentsTarget: Identifiable {
        let entity: EvidenceEntity
        let title: String
        var id: String { "\(entity.type.rawValue)/\(entity.id)" }
    }

    var body: some View {
        let tenancies = viewModel.snapshot.tenancies
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if !tenancies.isEmpty {
                    Picker("Tenancy", selection: Binding(get: { viewModel.selectedTenancy?.id }, set: { viewModel.selectedTenancyId = $0 })) {
                        ForEach(tenancies.reversed()) { tenancy in
                            Text("\(tenancy.referenceLabel) · \(PropertyFormat.period(tenancy.startDate, tenancy.endDate))").tag(tenancy.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Tenancy")
                }
                Spacer()
                Button("New tenancy…") { editing = TenancyDraft(nil, rents: [], propertyId: viewModel.propertyId ?? 0) }
                Button("Import receipts…") { importing = true }
                    .help("Import the Portal das Finanças receipts export (ListaRecibos .xlsx)")
                Button("Match credits") { viewModel.matchCredits() }
                    .help("Link rent credits on the current account to the receipts they paid")
                Button("Utility invoices…") { intakingInvoices = true }
                    .help("Add utility invoices (to recharge to the tenant) and match them to their debits")
            }
            if let tenancy = viewModel.selectedTenancy {
                terms(tenancy)
                receipts(tenancy)
            } else {
                Text("No tenancies yet. Import the portal's receipts export to create them, or add one by hand.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { draft in
            TenancyFormSheet(viewModel: viewModel, draft: draft)
        }
        .sheet(isPresented: $importing) {
            ImportReceiptsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $intakingInvoices) {
            if let propertyId = viewModel.propertyId {
                UtilityInvoiceIntakeSheet(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId,
                                          currency: viewModel.property?.currency ?? .eur)
            }
        }
        .sheet(item: $documentsOf) { target in
            PropertyDocumentsSheet(viewModel: viewModel, entity: target.entity, title: target.title)
        }
        .confirmationDialog("Delete this tenancy?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { tenancy in
            Button("Delete tenancy and its receipts", role: .destructive) {
                viewModel.errorMessage = viewModel.deleteTenancy(tenancy.id!)
            }
        } message: { _ in
            Text("Its rent history, receipts and their credit links go too. Linked documents stay in the library.")
        }
        .fileImporter(isPresented: $pickingDocument, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            guard let target = documentTarget else { return }
            documentTarget = nil
            switch result {
            case .success(let urls): viewModel.addDocuments(urls, to: target.entity, role: target.role)
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func addDocument(_ entity: EvidenceEntity, role: String) {
        documentTarget = (entity, role)
        pickingDocument = true
    }

    // MARK: Terms

    private func terms(_ tenancy: Tenancy) -> some View {
        let rents = viewModel.snapshot.rents[tenancy.id!] ?? []
        let contracts = viewModel.snapshot.tenancyDocumentCounts[tenancy.id!] ?? 0
        return PropertySection(tenancy.referenceLabel, accessory: {
            HStack(spacing: 8) {
                Button("Edit…") { editing = TenancyDraft(tenancy, rents: rents, propertyId: tenancy.propertyId) }
                Button("Delete…", role: .destructive) { deleting = tenancy }
            }
            .buttonStyle(.borderless)
        }) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Tenant", tenancy.tenantName ?? "—")
                row("Contract no.", tenancy.contractNumber ?? "—")
                row("Runs", PropertyFormat.period(tenancy.startDate, tenancy.endDate))
                row("Held", "\(tenancy.depositMonths) month\(tenancy.depositMonths == 1 ? "" : "s") deposit, "
                    + "\(tenancy.advanceRentMonths) month\(tenancy.advanceRentMonths == 1 ? "" : "s") advance rent")
                GridRow {
                    Text("Rent").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    if rents.isEmpty {
                        Text("No rent history — add it with Edit…").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rents) { rent in
                                HStack(spacing: 4) {
                                    Text("From \(DocumentFormat.day(rent.fromDate))")
                                    PropertyMoney(minorUnits: rent.monthlyAmountMinorUnits, currency: viewModel.currency, neutral: true)
                                    Text("a month").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                GridRow {
                    Text("Contract").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        DocumentCountBadge(count: contracts)
                        if contracts == 0 { Text("No document").foregroundStyle(.secondary) }
                        Button("Add contract…") { addDocument(.tenancy(tenancy.id!), role: "Contract") }.buttonStyle(.borderless)
                        if contracts > 0 {
                            Button("Documents…") {
                                documentsOf = DocumentsTarget(entity: .tenancy(tenancy.id!), title: "\(tenancy.referenceLabel): documents")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let notes = tenancy.notes { row("Notes", notes) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Receipts

    private func receipts(_ tenancy: Tenancy) -> some View {
        let rows = viewModel.snapshot.receipts[tenancy.id!] ?? []
        let paid = rows.filter(\.isPaid).count, issued = rows.filter { $0.receipt.status == .issued }.count
        return PropertySection("Receipts", accessory: {
            Text("\(rows.count) · \(paid) of \(issued) issued paid").font(.callout).foregroundStyle(.secondary)
        }) {
            if rows.isEmpty {
                Text("No receipts yet. Use Import receipts… with the portal's export.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("No.")
                        Text("Rent period")
                        Text("Received on")
                        Text("Rent").gridColumnAlignment(.trailing)
                        Text("Withheld").gridColumnAlignment(.trailing)
                        Text("Received").gridColumnAlignment(.trailing)
                        Text("Status")
                        Text("Paid by")
                        Text("PDF")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { row in receiptRow(row) }
                }
            }
        }
    }

    private func receiptRow(_ row: TenancyReceiptRow) -> some View {
        let receipt = row.receipt
        let cancelled = receipt.status == .cancelled
        return GridRow {
            Text(receipt.receiptNumber).monospacedDigit()
            Text(PropertyFormat.period(receipt.periodStart, receipt.periodEnd)).lineLimit(1).fixedSize()
            Text(receipt.receiptDate.map(DocumentFormat.day) ?? "—").lineLimit(1).fixedSize()
            PropertyMoney(minorUnits: receipt.amountMinorUnits, currency: viewModel.currency, neutral: true)
            PropertyMoney(minorUnits: receipt.withholdingMinorUnits, currency: viewModel.currency, neutral: true)
            PropertyMoney(minorUnits: receipt.amountReceivedMinorUnits, currency: viewModel.currency, neutral: true)
            Text(cancelled ? "Cancelled" : "Issued").foregroundStyle(cancelled ? .secondary : .primary)
            payments(row)
            HStack(spacing: 4) {
                DocumentCountBadge(count: row.documentCount)
                Menu {
                    Button("Add PDF…") { addDocument(.rentReceipt(receipt.id!), role: "Receipt") }
                    if row.documentCount > 0 {
                        Button("Documents…") {
                            documentsOf = DocumentsTarget(entity: .rentReceipt(receipt.id!), title: "Receipt \(receipt.receiptNumber): documents")
                        }
                    }
                } label: {
                    Image(systemName: row.documentCount == 0 ? "paperclip.badge.ellipsis" : "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(row.documentCount == 0 ? "Add the receipt PDF" : "The receipt's documents")
                .accessibilityLabel("Receipt \(receipt.receiptNumber) documents")
            }
        }
        .opacity(cancelled ? 0.6 : 1)
    }

    @ViewBuilder
    private func payments(_ row: TenancyReceiptRow) -> some View {
        if row.payments.isEmpty {
            Text(row.receipt.status == .cancelled ? "" : "Not matched").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(row.payments, id: \.payment.id) { info in
                    HStack(spacing: 4) {
                        Text(DocumentFormat.day(info.transaction.date)).lineLimit(1).fixedSize()
                        PropertyMoney(minorUnits: info.transaction.amountMinorUnits, currency: viewModel.currency)
                        if info.payment.otherMinorUnits > 0 {
                            Text("incl.").foregroundStyle(.secondary)
                            PropertyMoney(minorUnits: info.payment.otherMinorUnits, currency: viewModel.currency, neutral: true)
                            Text("other").foregroundStyle(.secondary)
                        }
                        Menu {
                            Button("Show transaction") { openTransaction(info.transaction) }
                            Button("Unlink") { viewModel.unlinkPayment(info.payment) }
                        } label: { Image(systemName: "chevron.down.circle") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Credit of \(DocumentFormat.day(info.transaction.date)) actions")
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// The documents linked to a property record: open or unlink each.
struct PropertyDocumentsSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    let entity: EvidenceEntity
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [EvidenceDocument] = []

    var body: some View {
        SheetScaffold(title: title, width: 520, cancelTitle: "Done", onCancel: { dismiss() }) {
            if documents.isEmpty {
                Text("No documents.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(documents) { document in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(document.displayName).lineLimit(1)
                                Text(DocumentFormat.caption(kind: document.kind, date: document.docDate, amountMinorUnits: document.amountMinorUnits,
                                                            currency: document.currency))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { viewModel.open(document) }.buttonStyle(.borderless)
                            Button("Unlink") {
                                viewModel.unlinkDocument(document, from: entity)
                                documents = viewModel.documents(for: entity)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .onAppear { documents = viewModel.documents(for: entity) }
    }
}
