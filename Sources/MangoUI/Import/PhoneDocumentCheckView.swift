import SwiftUI
import BudgetCore

/// The document screen: page 1, the fields read from the file (each marked Read, or To check when low confidence),
/// and what it links to. Edits are held until "Save and link"; Not now discards.
struct PhoneDocumentCheckView: View {
    @Bindable var model: PhoneImportModel
    let file: PhoneImportBatch.File
    @State private var choosingPayment = false
    @State private var viewing = false
    @Environment(\.phoneTheme) private var theme

    private var review: CheckAndLinkModel? { model.review }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.m) {
                    if let review {
                        preview(review)
                        if let refusal = review.refusal { InlineBanner(tone: .amber, text: refusal) }
                        if let saved = model.alreadySavedAs {
                            InlineBanner(tone: .neutral, text: PhoneImportBatchCopy.alreadySaved(as: saved))
                        }
                        fields(review)
                        linkCard(review)
                        notes(review)
                    }
                }
                .padding(MangoSpacing.m)
            }
            bottom
        }
        .sheet(isPresented: $choosingPayment) {
            if let review { PhonePaymentChoiceSheet(review: review, isPresented: $choosingPayment) }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $viewing) {
            if let review { PadDocumentPreview(url: review.fileURL).ignoresSafeArea() }
        }
        #endif
    }

    // MARK: Parts

    private func preview(_ review: CheckAndLinkModel) -> some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            Group {
                #if canImport(UIKit)
                DocumentThumbnailImage(url: review.fileURL).padding(MangoSpacing.xs)
                #else
                Image(systemName: "doc.text").mangoFont(.largeTitle).foregroundStyle(.secondary)
                #endif
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 200)
            .background(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).fill(theme.surface))
            Text(file.name).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
            #if canImport(UIKit)
            Button("Open full view") { viewing = true }.buttonStyle(ImportTextButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
    }

    private func fields(_ review: CheckAndLinkModel) -> some View {
        Card {
            let rows = review.rows
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                if row.label == "Kind", case .document(let document) = review.proposal, document.needsKind {
                    kindMenu(document, review)
                } else {
                    ImportCheckRow(row)
                }
            }
        }
    }

    private func kindMenu(_ document: DocumentFields, _ review: CheckAndLinkModel) -> some View {
        Menu {
            ForEach(document.kindChoices, id: \.self) { choice in
                Button(choice.label) { Task { await review.chooseKind(choice) } }
            }
        } label: {
            ImportFieldRow(label: "Kind", pill: (PhoneImportCopy.toCheck, .waiting)) {
                HStack(spacing: 4) {
                    Text("Choose the kind").mangoFont(.body).foregroundStyle(theme.accent)
                    Image(systemName: "chevron.up.chevron.down").mangoFont(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkCard(_ review: CheckAndLinkModel) -> some View {
        switch review.proposal {
        case .utilityBill(let bill):
            Card(title: "Linked to") {
                if let payment = bill.paidBy {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.description).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                        Text("\(PhoneDateFormat.day(payment.date)) · \(Money.format(payment.amountMinorUnits, currency: payment.currency))".figuresUnbroken)
                            .mangoFont(.subheadline).foregroundStyle(.secondary)
                        Text(PhoneDocumentCopy.suggested).mangoFont(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text(CheckAndLinkSheetCopy.noPaymentFound).mangoFont(.body).foregroundStyle(.secondary)
                }
                if !bill.paymentChoices.isEmpty {
                    Button("Choose another") { choosingPayment = true }.buttonStyle(ImportTextButtonStyle())
                }
                if bill.paidBy != nil {
                    Button("No link") { Task { await review.choosePayment(nil) } }.buttonStyle(ImportTextButtonStyle())
                }
            }
        case .document(let document):
            if !document.links.isEmpty {
                Card(title: "Linked to") {
                    ForEach(document.links, id: \.self) { Text($0.figuresUnbroken).mangoFont(.body).lineLimit(2) }
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func notes(_ review: CheckAndLinkModel) -> some View {
        let proposal = review.proposal
        let lines = (proposal?.check.blockers ?? []) + (proposal?.check.notes ?? [])
            + (review.unshownChecks.isEmpty ? [] : [CheckAndLinkSheetCopy.checkBeforeSave(review.unshownChecks)])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                ForEach(lines, id: \.self) { InlineBanner(tone: .amber, text: $0) }
            }
        }
    }

    // MARK: Primary action

    private var bottom: some View {
        ImportBottomBar {
            if model.alreadySavedAs != nil {
                Button(PhoneImportBatchCopy.doneWithFile) { Task { await model.doneWithFile() } }
                    .buttonStyle(ImportPrimaryButtonStyle())
            } else {
                Button {
                    Task { await model.saveDocument() }
                } label: {
                    if model.isWorking { ProgressView().tint(theme.onAccent) } else { Text(PhoneDocumentCopy.saveAndLink) }
                }
                .buttonStyle(ImportPrimaryButtonStyle())
                .disabled(!model.canSaveDocument)
                Button(PhoneImportCopy.notNow) { Task { await model.skipCurrent() } }
                    .buttonStyle(ImportTextButtonStyle())
                    .disabled(model.isWorking)
            }
        }
    }
}

enum PhoneDocumentCopy {
    static let saveAndLink = "Save and link"
    static let suggested = "Suggested: the amount matches"
}

/// "Choose another": the payments the bill could have been, the current one first.
struct PhonePaymentChoiceSheet: View {
    let review: CheckAndLinkModel
    @Binding var isPresented: Bool
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            List(review.paymentChoices) { payment in
                Button {
                    Task {
                        await review.choosePayment(payment.transactionId)
                        isPresented = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.description).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                        Text("\(PhoneDateFormat.day(payment.date)) · \(Money.format(payment.amountMinorUnits, currency: payment.currency))".figuresUnbroken)
                            .mangoFont(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
            }
            .navigationTitle(CheckAndLinkSheetCopy.choosePayment)
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}
