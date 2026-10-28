import SwiftUI
import BudgetCore

// MARK: - The form

/// A tenancy's terms and rent history (the Mac's tenancy form): the reference, contract, tenant and where the statement is
/// emailed, its days, advance rent and deposit, notes, and the rent history. Saved only with Save; a refusal shows inside.
struct PadTenancyFormSheet: View {
    @ObservedObject var model: PadTenanciesModel
    @ObservedObject var write: PadWriteModel
    @State var draft: PadTenancyDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var saving = false

    private var calendar: Calendar { MonthRange.calendar }

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: write.message(for: PadTenanciesModel.formRow)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section("Tenancy") {
                    TextField("Reference", text: $draft.reference, prompt: Text("The portal's Referência"))
                        .frame(minHeight: 44).accessibilityIdentifier("tenancy-reference")
                    TextField("Contract no.", text: $draft.contract, prompt: Text("Optional")).frame(minHeight: 44)
                }
                Section {
                    TextField("Tenant", text: $draft.tenant, prompt: Text("Optional")).frame(minHeight: 44)
                    TextField("Email", text: $draft.email, prompt: Text("Optional"))
                        #if os(iOS)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        #endif
                        .frame(minHeight: 44)
                } header: {
                    Text("Tenant")
                } footer: {
                    Text("The email is for the monthly utilities statement. Separate several with commas.")
                }
                Section("Dates") {
                    DatePicker("Start", selection: $draft.start, displayedComponents: .date).frame(minHeight: 44)
                    Toggle("Ended", isOn: Binding(get: { draft.end != nil }, set: { draft.end = $0 ? max(draft.start, calendar.startOfDay(for: Date())) : nil }))
                        .frame(minHeight: 44)
                    if draft.end != nil {
                        DatePicker("End", selection: Binding(get: { draft.end ?? draft.start }, set: { draft.end = $0 }), displayedComponents: .date)
                            .frame(minHeight: 44)
                    }
                }
                Section("Held") {
                    Stepper(value: $draft.advanceMonths, in: 0...24) { Text("Advance rent: \(months(draft.advanceMonths))") }.frame(minHeight: 44)
                    Stepper(value: $draft.depositMonths, in: 0...24) { Text("Deposit: \(months(draft.depositMonths))") }.frame(minHeight: 44)
                }
                Section {
                    ForEach($draft.rents) { $rent in
                        HStack(spacing: 12) {
                            DatePicker("From", selection: $rent.from, displayedComponents: .date).labelsHidden()
                            Spacer(minLength: 4)
                            TextField("Monthly rent", text: $rent.amountText, prompt: Text("Monthly rent"))
                                #if os(iOS)
                                .keyboardType(.numbersAndPunctuation)
                                #endif
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 90, maxWidth: 130, minHeight: 44)
                            Button { draft.rents.removeAll { $0.id == rent.id } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.red).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove the rent from \(PhoneDateFormat.day(rent.from))")
                        }
                    }
                    Button { draft.rents.append(.init(from: draft.rents.isEmpty ? draft.start : calendar.startOfDay(for: Date()), amountText: "")) } label: {
                        Label("Add rent", systemImage: "plus")
                    }
                    .frame(minHeight: 44)
                } header: {
                    Text("Rent history")
                } footer: {
                    if draft.rents.isEmpty { Text("No rent yet: add the monthly rent and the day it starts.") }
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4)
                }
            }
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(draft.existing == nil ? "New tenancy" : "Edit tenancy")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.existing == nil ? "Add tenancy" : "Save") {
                        saving = true
                        Task {
                            let saved = await model.save(draft)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!draft.canSave || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func months(_ count: Int) -> String { "\(count) month\(count == 1 ? "" : "s")" }
}

// MARK: - Linked documents

/// A record's linked documents (a tenancy's contract, a receipt's PDFs): View opens the document at full size, Unlink (with Edit
/// on Property) takes it off the record; the document stays in the library.
struct PadLinkedDocumentsSheet: View {
    let title: String
    let canEdit: Bool
    let write: PadWriteModel
    let rowId: String
    let load: () async -> [EvidenceDocument]
    let unlink: (Int64) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var documents: [EvidenceDocument] = []
    @State private var loaded = false
    @State private var viewing: Viewing?

    struct Viewing: Identifiable { let id: Int64 }

    var body: some View {
        NavigationStack {
            List {
                PadRefusalBanner(message: write.message(for: rowId)).listRowBackground(Color.clear)
                if loaded, documents.isEmpty {
                    Text("Nothing is linked to this record yet. Unlinked documents stay in the library.").foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.displayName).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 8) {
                                DateText(document.docDate, font: .subheadline)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let id = document.id {
                            RowIconButton(.view, item: document.displayName) { viewing = Viewing(id: id) }
                            if canEdit {
                                RowIconButton(.unlink, item: document.displayName) {
                                    Task {
                                        if await unlink(id) { documents = await load() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                documents = await load()
                loaded = true
            }
        }
        .sheet(item: $viewing) { DocumentFullView(documentId: $0.id, showsDetails: true) }
    }
}

// MARK: - The receipt panel

/// The selected receipt's block under the document's details: ONE line saying what paid it, "Rent paid: tenant transfer of €X
/// on <date> · BBVA", with a small Change link (and the credit's own Show and Unlink); or what it is waiting for. Then the
/// actions its state offers (icon buttons, the rest as text links) and a refusal under them.
struct PadReceiptPanelExtra: View {
    @ObservedObject var model: PadTenanciesModel
    @ObservedObject var write: PadWriteModel
    let receipt: PadTenanciesModel.Receipt
    let run: (PadTenanciesAction, Int64?) -> Void

    var body: some View {
        let offered = model.actions(for: receipt)
        VStack(alignment: .leading, spacing: 12) {
            paid(offered)
            let icons = offered.filter { [.linkPayment, .addDocument, .fetchFromPortal].contains($0) && ($0 != .addDocument || receipt.row.documentCount == 0) }
            if !icons.isEmpty {
                HStack(spacing: 4) {
                    ForEach(icons, id: \.self) { action in
                        if let row = action.rowAction {
                            RowIconButton(row, item: "receipt \(receipt.receipt.receiptNumber)") { run(action, nil) }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            let links = offered.filter { [.showInDocuments, .receiptDocuments, .replaceDocument].contains($0) || ($0 == .addDocument && receipt.row.documentCount > 0) }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(links, id: \.self) { action in
                        Button((action == .addDocument ? "Add another PDF" : action.title) + (action == .showInDocuments ? "" : "…")) { run(action, nil) }
                            .buttonStyle(.pad(.textLink, size: .small))
                    }
                }
            }
            PadRefusalBanner(message: write.message(for: receipt.rowId))
        }
        .accessibilityIdentifier("pad-receipt-panel-\(receipt.id)")
    }

    @ViewBuilder
    private func paid(_ offered: [PadTenanciesAction]) -> some View {
        let lines = receipt.paidLines
        if lines.isEmpty {
            Text(receipt.status == .cancelled ? "Cancelled: no payment expected." : "No payment linked yet.")
                .mangoFont(.subheadline).foregroundStyle(.secondary)
        } else {
            ForEach(lines, id: \.transactionId) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Button { run(.showCredit, line.transactionId) } label: {
                        Text(line.text.figuresUnbroken).mangoFont(.subheadline).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the credit")
                    HStack(spacing: 4) {
                        if offered.contains(.changePayment) {
                            Button("Change") { run(.changePayment, line.transactionId) }.buttonStyle(.pad(.textLink, size: .small))
                        }
                        Spacer(minLength: 0)
                        if offered.contains(.unlinkPayment) {
                            RowIconButton(.unlink, item: "payment of receipt \(receipt.receipt.receiptNumber)", size: .small) {
                                run(.unlinkPayment, line.transactionId)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The panel for the selected receipt on the right of the screen (the shared `DocumentPanel` on its PDF, or a plain panel of
/// the same width when it has none), beside the content when it keeps `DocumentPanelLayout`'s minimum width, else over its
/// trailing edge. Closing clears the selection.
struct PadReceiptPanelHost<PanelExtra: View>: ViewModifier {
    @ObservedObject var model: PadTenanciesModel
    let extra: (PadTenanciesModel.Receipt) -> PanelExtra
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let placement = DocumentPanelLayout.placement(containerWidth: geometry.size.width)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let receipt = model.selectedReceipt, placement == .beside {
                        Divider()
                        panel(receipt)
                    }
                }
                if let receipt = model.selectedReceipt, placement == .overlay {
                    HStack(spacing: 0) {
                        Divider()
                        panel(receipt)
                    }
                    .frame(maxHeight: .infinity)
                    .background(theme.background)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }

    @ViewBuilder
    private func panel(_ receipt: PadTenanciesModel.Receipt) -> some View {
        if let documentId = receipt.row.documentIds.first {
            DocumentPanel(documentId: documentId, onClose: { model.closePanel() }) { extra(receipt) }
                .id(documentId)
        } else {
            PadReceiptPlainPanel(receipt: receipt, onClose: { model.closePanel() }) { extra(receipt) }
        }
    }
}

/// The panel of a receipt with no PDF: its title, its figures, a note, and the screen's block.
struct PadReceiptPlainPanel<Extra: View>: View {
    let receipt: PadTenanciesModel.Receipt
    let onClose: () -> Void
    @ViewBuilder let extra: Extra
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Receipt \(receipt.receipt.receiptNumber)").mangoFont(.headline).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").mangoFont(.title2).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Close")
            }
            .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(receipt.receipt.status == .cancelled ? "Cancelled: no PDF needed." : "No receipt PDF yet.")
                        .foregroundStyle(.secondary)
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            fact("Period", Text("\(PhoneDateFormat.day(receipt.receipt.periodStart)) – \(PhoneDateFormat.day(receipt.receipt.periodEnd))".unbroken))
                            fact("Rent", MoneyText(minorUnits: receipt.receipt.amountMinorUnits, currency: receipt.currency, role: .neutral, font: .subheadline))
                            if receipt.receipt.withholdingMinorUnits != 0 {
                                fact("Tax withheld", MoneyText(minorUnits: receipt.receipt.withholdingMinorUnits, currency: receipt.currency, role: .neutral, font: .subheadline))
                            }
                            fact("Received", MoneyText(minorUnits: receipt.receipt.amountReceivedMinorUnits, currency: receipt.currency, role: .neutral, font: .subheadline))
                            if let day = receipt.receipt.receiptDate {
                                fact("Received on", Text(PhoneDateFormat.day(day).unbroken))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    extra
                }
                .padding(16)
            }
        }
        .frame(width: DocumentPanelLayout.width)
        .background(theme.background)
    }

    private func fact<Value: View>(_ label: String, _ value: Value) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                value.lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                value.fixedSize(horizontal: false, vertical: true)
            }
        }
        .mangoFont(.subheadline)
    }
}
