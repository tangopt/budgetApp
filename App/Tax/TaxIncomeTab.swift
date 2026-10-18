// App/Tax/TaxIncomeTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The person's income for the year (plan phase 4 Task 4, UI polish §4.2): the employments —
/// each with the figures the return uses (pay, tax, benefits) and its sources as a table (the
/// P60 / P45 / payslip rows and the P11D benefits, a pill for where each came from) — then
/// other income and pension contributions side by side, and the HMRC payments with their
/// proofs. A P60, P45 or P11D PDF is read and shown in a confirm sheet, editable before Save.
/// Changes in sheets are written by Save.
struct TaxIncomeTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var importing = false
    @State private var reading = false
    @State private var importDraft: TaxYearsViewModel.FormImportDraft?
    @State private var editingEmployment: Identified<Employment>?
    @State private var editingIncome: Identified<EmploymentIncome>?
    @State private var editingBenefit: Identified<BenefitInKind>?
    @State private var editingOther: Identified<OtherIncome>?
    @State private var editingPension: Identified<PensionContribution>?
    @State private var editingPayment: Identified<HMRCPayment>?
    @State private var deleting: Deletion?

    private var startYear: Int { page.row.year.startYear }
    private var personId: Int64 { page.row.person.id ?? 0 }
    private var income: SelfAssessmentOverview.IncomePage { page.income }

    struct Deletion: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let action: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if !income.hasEvidenceRules {
                InlineBanner(.info) {
                    Button("Set up evidence rules") { viewModel.seedIncomeEvidenceRules() }
                        .controlSize(.small)
                } content: {
                    Text("Missing evidence can ask for each P60, P45, P11D and HMRC payment proof.")
                }
            }
            employmentsPanel
            SplitRow(ratio: 0.56, stackBelow: 940) {
                otherIncomePanel
                pensionsPanel
            }
            paymentsPanel
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            reading = true
            Task {
                let outcome = await viewModel.readForm(url, kind: nil)
                reading = false
                switch outcome {
                case let .success(draft): importDraft = draft
                case let .failure(error): viewModel.errorMessage = "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $importDraft) { draft in
            PayrollFormConfirmSheet(viewModel: viewModel, draft: draft, personId: personId, defaultYear: startYear)
        }
        .sheet(item: $editingEmployment) { EmploymentSheet(viewModel: viewModel, employment: $0.value) }
        .sheet(item: $editingIncome) { EmploymentIncomeSheet(viewModel: viewModel, income: $0.value) }
        .sheet(item: $editingBenefit) { BenefitSheet(viewModel: viewModel, benefit: $0.value) }
        .sheet(item: $editingOther) { OtherIncomeSheet(viewModel: viewModel, income: $0.value) }
        .sheet(item: $editingPension) { PensionSheet(viewModel: viewModel, contribution: $0.value) }
        .sheet(item: $editingPayment) { HMRCPaymentSheet(viewModel: viewModel, payment: $0.value, yearStatus: page.row.status) }
        .confirmationDialog(deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                deleting?.action()
                deleting = nil
            }
        } message: {
            Text((deleting?.detail ?? "") + " This can't be undone.")
        }
    }

    // MARK: Employment

    private var employmentsPanel: some View {
        Panel("Employment", subtitle: "SA102: pay and tax from the P60, P45 or payslips; benefits from the P11D") {
            HStack(spacing: 8) {
                if reading {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(.callout).foregroundStyle(.secondary)
                }
                Button("Add employment…") {
                    editingEmployment = Identified(Employment(startYear: startYear, personId: personId, employerName: ""))
                }
                Button("Import P60, P45 or P11D…") { importing = true }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .disabled(reading)
                    .help("Read a P60, P45 or P11D (PDF or image) and confirm its figures before saving")
            }
            .controlSize(.small)
        } content: {
            if income.employments.isEmpty {
                // The panel's corner has Add employment… and Import P60, P45 or P11D….
                EmptyState(systemImage: "briefcase", title: "No employment for \(page.row.year.label)",
                           message: "Import the P60 (or P45) and the P11D, or add the employment by hand.")
                    .inPanel()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(income.employments.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        employmentBlock(row, number: index + 1)
                    }
                }
            }
        }
    }

    /// One employer: its name and reference with its documents and actions, the figures the
    /// return uses, then the rows they come from.
    private func employmentBlock(_ row: SelfAssessmentOverview.EmploymentRow, number: Int) -> some View {
        let employment = row.employment
        let name = employment.employerName
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.bold()).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(TaxIncomeFormat.employmentCaption(employment, number: number, of: income.employments.count))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if row.documentCount > 0 {
                    DocumentCountBadge(count: row.documentCount, keepsPlace: false)
                        .help("\(row.documentCount) document\(row.documentCount == 1 ? "" : "s") linked: the P11D on the employment, a P60 or P45 with its pay and tax")
                }
                HStack(spacing: 10) {
                    Button { editingEmployment = Identified(employment) } label: { Image(systemName: "pencil") }
                        .help("Edit the employment")
                        .accessibilityLabel("Edit \(name)")
                    Menu {
                        Button("Add pay and tax…") { addIncome(row) }
                        Button("Add benefit…") { addBenefit(row) }
                        Divider()
                        Button("Edit employment…") { editingEmployment = Identified(employment) }
                        Button("Delete employment…", role: .destructive) {
                            deleting = Deletion(title: "Delete “\(name)”?",
                                                detail: "Its pay and tax, benefits and document links go too; the documents stay in the library.") {
                                viewModel.deleteEmployment(row.id)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add pay and tax…, Add benefit…, Edit, Delete")
                    .accessibilityLabel("More actions for \(name)")
                }
                .buttonStyle(.borderless)
            }
            FigureStrip(TaxIncomeFormat.figures(row))
            if row.incomes.isEmpty {
                InlineBanner(.warning) {
                    Button("Add pay and tax…") { addIncome(row) }.controlSize(.small)
                } content: {
                    Text("No pay and tax yet: import the P60 or P45, or add it (or the payslips) by hand.")
                }
            }
            if !row.incomes.isEmpty || !row.benefits.isEmpty {
                DataTable(columns: sourceColumns, sections: sourceSections(row))
            }
        }
    }

    private func addIncome(_ row: SelfAssessmentOverview.EmploymentRow) {
        editingIncome = Identified(EmploymentIncome(employmentId: row.id, source: row.incomes.isEmpty ? .p60 : .payslip, payMinorUnits: 0,
                                                    taxDeductedMinorUnits: 0))
    }

    private func addBenefit(_ row: SelfAssessmentOverview.EmploymentRow) {
        editingBenefit = Identified(BenefitInKind(employmentId: row.id, kind: .medical, cashEquivalentMinorUnits: 0))
    }

    /// A row of an employment's sources: a pay-and-tax row or a benefit.
    private struct SourceRow: Identifiable {
        let id: String
        var income: EmploymentIncome?
        var benefit: BenefitInKind?
    }

    private func sourceSections(_ row: SelfAssessmentOverview.EmploymentRow) -> [DataTableSection<SourceRow>] {
        var sections: [DataTableSection<SourceRow>] = []
        if !row.incomes.isEmpty {
            sections.append(DataTableSection("Pay and tax", rows: row.incomes.map { SourceRow(id: "income-\($0.id ?? 0)", income: $0) }))
        }
        if !row.benefits.isEmpty {
            sections.append(DataTableSection("Benefits in kind", rows: row.benefits.map { SourceRow(id: "benefit-\($0.id ?? 0)", benefit: $0) }))
        }
        return sections
    }

    private var sourceColumns: [DataTableColumn<SourceRow>] {
        [
            DataTableColumn("From", width: .fixed(84), accessibilityValue: { TaxIncomeFormat.sourcePill($0.income, $0.benefit).title }) { row, _ in
                TaxIncomeFormat.sourcePill(row.income, row.benefit)
            },
            .text("Details", width: .fill(min: 180), { row in
                if let income = row.income { return [income.taxCode.map { "Tax code \($0)" }, income.entryMethod.displayName].compactMap { $0 }.joined(separator: " · ") }
                guard let benefit = row.benefit else { return "" }
                return "Box \(benefit.sa102Box) · \(benefit.kind.displayName)"
            }, detail: { row in
                let note = row.income?.notes ?? row.benefit?.description
                return note?.isEmpty == false ? note : nil
            }),
            .date("Date") { $0.income?.periodEnd },
            .money("Amount", role: .neutral, currency: { _ in .gbp }) { $0.income?.payMinorUnits ?? $0.benefit?.cashEquivalentMinorUnits },
            .money("Tax taken off", role: .neutral, currency: { _ in .gbp }) { $0.income?.taxDeductedMinorUnits },
            .actions { row in
                if let income = row.income {
                    let name = "\(income.source.displayName) pay and tax"
                    return [
                        DataTableAction("Edit \(name)", systemImage: "pencil", inline: true) { editingIncome = Identified(income) },
                        DataTableAction("Delete \(name)…", systemImage: "trash", role: .destructive, inline: true) {
                            deleting = Deletion(title: "Delete the \(name)?", detail: "Its document links go too; the documents stay in the library.") {
                                viewModel.deleteIncome(income.id ?? 0)
                            }
                        }
                    ]
                }
                guard let benefit = row.benefit else { return [] }
                return [
                    DataTableAction("Edit \(benefit.kind.displayName)", systemImage: "pencil", inline: true) { editingBenefit = Identified(benefit) },
                    DataTableAction("Delete \(benefit.kind.displayName)…", systemImage: "trash", role: .destructive, inline: true) {
                        deleting = Deletion(title: "Delete \(benefit.kind.displayName)?", detail: "It comes off box \(benefit.sa102Box) of the return.") {
                            viewModel.deleteBenefit(benefit.id ?? 0)
                        }
                    }
                ]
            }
        ]
    }

    // MARK: Other income and pensions

    private var otherIncomePanel: some View {
        Panel("Other income", subtitle: "Interest, dividends and other taxable income", fillsHeight: true) {
            Button("Add income…") {
                editingOther = Identified(OtherIncome(startYear: startYear, personId: personId, kind: .ukInterest, amountMinorUnits: 0))
            }
            .controlSize(.small)
        } content: {
            if income.otherIncomes.isEmpty {
                Text("No other income yet: UK and foreign interest, dividends and other taxable income go here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DataTable(columns: [
                    .text("Income", width: .fill(min: 130), { $0.kind.displayName }, detail: { $0.payer.flatMap { $0.isEmpty ? nil : $0 } }),
                    .money("Amount", role: .neutral, minWidth: 90, currency: { $0.currency }) { $0.amountMinorUnits },
                    .money("Tax off", role: .neutral, minWidth: 80, currency: { $0.currency }) { $0.taxDeductedMinorUnits == 0 ? nil : $0.taxDeductedMinorUnits },
                    .documents { income.documentCounts[.otherIncome($0.id)] ?? 0 },
                    .actions { item in recordActions(item.kind.displayName, edit: { editingOther = Identified(item.record) }) {
                        viewModel.deleteOtherIncome(item.id)
                    } }
                ], rows: income.otherIncomes.map(IdentifiedRecord.init))
            }
        }
    }

    private var pensionsPanel: some View {
        Panel("Pension contributions", subtitle: "Relief at source and others you claim on the return", fillsHeight: true) {
            Button("Add contribution…") {
                editingPension = Identified(PensionContribution(startYear: startYear, personId: personId, kind: .reliefAtSource, paidMinorUnits: 0))
            }
            .controlSize(.small)
        } content: {
            if income.pensions.isEmpty {
                Text("No contributions yet. Those taken from pay before tax (net pay) don't go on the return.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DataTable(columns: [
                    .text("Contribution", width: .fill(min: 130), { $0.kind.displayName }, detail: { $0.provider.flatMap { $0.isEmpty ? nil : $0 } }),
                    .money("You paid", role: .neutral, minWidth: 90, currency: { _ in .gbp }) { $0.paidMinorUnits },
                    .documents { income.documentCounts[.pensionContribution($0.id)] ?? 0 },
                    .actions { item in recordActions(item.kind.displayName, edit: { editingPension = Identified(item.record) }) {
                        viewModel.deletePension(item.id)
                    } }
                ], rows: income.pensions.map(IdentifiedRecord.init))
            }
        }
    }

    // MARK: Payments

    private var paymentsPanel: some View {
        Panel("HMRC payments", subtitle: "For \(page.row.year.label) and towards \(UKTaxYear(startYear: startYear + 1).label), with their proofs") {
            Button("Record payment…") {
                editingPayment = Identified(HMRCPayment(personId: personId, startYear: startYear, date: PayCalendar.utcDay(sameDayAs: AppClock.now, in: .current),
                                                        amountMinorUnits: 0, kind: .balancingPayment))
            }
            .controlSize(.small)
        } content: {
            if income.payments.isEmpty {
                Text("No payments for \(page.row.year.label) yet (or towards \(UKTaxYear(startYear: startYear + 1).label)): record each one with its proof.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HMRCPaymentsTable(payments: income.payments, counts: income.documentCounts, startYear: startYear,
                                  edit: { editingPayment = Identified($0) },
                                  delete: { payment in
                                      deleting = Deletion(title: "Delete this \(payment.kind.displayName.lowercased())?",
                                                          detail: "Its document links go too; the documents stay in the library.") {
                                          viewModel.deletePayment(payment.id ?? 0)
                                      }
                                  })
            }
        }
    }

    /// A record's edit and delete icons (delete asks first).
    private func recordActions(_ name: String, edit: @escaping () -> Void, delete: @escaping () -> Void) -> [DataTableAction] {
        [
            DataTableAction("Edit \(name)", systemImage: "pencil", inline: true, action: edit),
            DataTableAction("Delete \(name)…", systemImage: "trash", role: .destructive, inline: true) {
                deleting = Deletion(title: "Delete \(name)?", detail: "Its document links go too; the documents stay in the library.", action: delete)
            }
        ]
    }
}

/// A stored record as a table row, by its id (the records' own `id` is optional while new).
@dynamicMemberLookup
struct IdentifiedRecord<Record>: Identifiable {
    let record: Record
    let id: Int64

    init(_ record: Record) where Record: Identifiable, Record.ID == Int64? {
        self.record = record
        id = record.id ?? 0
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<Record, Value>) -> Value { record[keyPath: keyPath] }
}

/// HMRC payments with their proofs (Income and Filing): the day, the payment and the year it's
/// for (its reference beneath), the amount (a refund negative), the proof — a paperclip, or a
/// "No proof" pill — and edit and delete icons; by year with a total when they span two.
struct HMRCPaymentsTable: View {
    let payments: [HMRCPayment]
    let counts: [EvidenceEntity: Int]
    /// The page's year (its payments first; the payments on account towards the next after).
    let startYear: Int
    let edit: (HMRCPayment) -> Void
    let delete: (HMRCPayment) -> Void

    private struct Row: Identifiable {
        let id: String
        var payment: HMRCPayment?
        var amount: Int
        var proofs = 0
    }

    private var sections: [DataTableSection<Row>] {
        let years = Array(Set(payments.map(\.startYear))).sorted { ($0 == startYear ? 0 : 1, $0) < ($1 == startYear ? 0 : 1, $1) }
        return years.map { year in
            let rows = payments.filter { $0.startYear == year }.sorted { ($0.date, $0.id ?? 0) < ($1.date, $1.id ?? 0) }.map {
                Row(id: "\($0.id ?? 0)", payment: $0, amount: $0.signedMinorUnits, proofs: counts[.hmrcPayment($0.id ?? 0)] ?? 0)
            }
            let label = UKTaxYear(startYear: year).label
            return DataTableSection(years.count > 1 ? (year == startYear ? "For \(label)" : "Towards \(label)") : nil, rows: rows,
                                    total: rows.count > 1 ? Row(id: "total-\(year)", amount: rows.reduce(0) { $0 + $1.amount }) : nil)
        }
    }

    var body: some View {
        DataTable(columns: [
            .date("Date") { $0.payment?.date },
            DataTableColumn("Payment", width: .fill(min: 180), accessibilityValue: { row in
                row.payment.map { "\($0.kind.displayName) for \(UKTaxYear(startYear: $0.startYear).label)" }
            }) { row, kind in
                if let payment = row.payment {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(payment.kind.displayName) · \(UKTaxYear(startYear: payment.startYear).label)").lineLimit(1)
                        if let reference = payment.reference, !reference.isEmpty {
                            Text("Ref. \(reference)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text("Total").fontWeight(.semibold)
                }
            },
            // What was paid to HMRC (a refund negative): figures from the proofs, uncoloured.
            DataTableColumn("Amount", alignment: .trailing, width: .min(104),
                            accessibilityValue: { Money.format($0.amount, currency: .gbp) }) { row, kind in
                MoneyText(minorUnits: row.amount, currency: .gbp,
                          font: kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(), role: .neutral)
            },
            DataTableColumn("Proof", alignment: .center, width: .fit, accessibilityValue: { row in
                guard row.payment != nil else { return nil }
                return row.proofs == 0 ? "no proof" : (row.proofs == 1 ? "1 document" : "\(row.proofs) documents")
            }) { row, kind in
                if kind == .row {
                    if row.proofs > 0 {
                        DocumentCountBadge(count: row.proofs)
                    } else {
                        StatusPill("No proof", tone: .warning, help: "Edit the payment to add its proof (the bank's confirmation)")
                    }
                }
            },
            .actions { row in
                guard let payment = row.payment else { return [] }
                return [
                    DataTableAction("Edit \(payment.kind.displayName)", systemImage: "pencil", inline: true) { edit(payment) },
                    DataTableAction("Delete \(payment.kind.displayName)…", systemImage: "trash", role: .destructive, inline: true) { delete(payment) }
                ]
            }
        ], sections: sections)
    }
}

/// How the Income tab presents an employment.
enum TaxIncomeFormat {
    /// "PAYE 123/AB45678 · from 6 Apr 2025 · left 5 Jan 2026" ("Employment 2 of 3 · …" when several).
    static func employmentCaption(_ employment: Employment, number: Int, of count: Int) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("Employment \(number) of \(count)") }
        if let reference = employment.payeReference, !reference.isEmpty { parts.append("PAYE \(reference)") }
        if let start = employment.startDate { parts.append("from \(DocumentFormat.day(start))") }
        if let end = employment.endDate { parts.append("left \(DocumentFormat.day(end))") }
        return parts.isEmpty ? "No PAYE reference" : parts.joined(separator: " · ")
    }

    /// The figures the return uses (`Employments.effectiveIncome`): pay and tax from the
    /// highest source, the benefits, and the total that goes in as employment income.
    static func figures(_ row: SelfAssessmentOverview.EmploymentRow) -> [FigureTile] {
        let benefits = row.benefits.reduce(0) { $0 + $1.cashEquivalentMinorUnits }
        let boxes = Array(Set(row.benefits.map(\.sa102Box))).sorted().map(String.init)
        let benefitTile = FigureTile(title: "Benefits", value: .money(benefits, .gbp, .neutral),
                                     caption: boxes.isEmpty ? "None" : "SA102 box\(boxes.count == 1 ? "" : "es") \(boxes.joined(separator: ", "))")
        guard let effective = Employments.effectiveIncome(row.incomes) else {
            return [
                FigureTile(title: "Pay", value: .text("—"), caption: "No pay and tax yet", captionIsWarning: true),
                FigureTile(title: "Tax taken off", value: .text("—")),
                benefitTile,
                FigureTile(title: "Employment income", value: .money(benefits, .gbp, .neutral), caption: "Benefits only so far")
            ]
        }
        let used = row.incomes.filter { $0.source == effective.source }
        let from: String
        switch effective.source {
        case .p60, .p45: from = "From the \(effective.source.displayName)"
        case .payslip: from = used.count == 1 ? "From 1 payslip" : "From \(used.count) payslips"
        case .other: from = used.count == 1 ? "From 1 other record" : "From \(used.count) other records"
        }
        let codes = Array(Set(used.compactMap(\.taxCode))).sorted()
        return [
            FigureTile(title: "Pay", value: .money(effective.payMinorUnits, .gbp, .neutral), caption: from),
            FigureTile(title: "Tax taken off", value: .money(effective.taxDeductedMinorUnits, .gbp, .neutral),
                       caption: codes.isEmpty ? nil : "Tax code \(codes.joined(separator: ", "))"),
            benefitTile,
            FigureTile(title: "Employment income", value: .money(effective.payMinorUnits + benefits, .gbp, .neutral), caption: "Pay and benefits, on the return")
        ]
    }

    /// Where a row came from: the form for pay and tax (P60, P45, payslip), the P11D or by hand
    /// for a benefit.
    static func sourcePill(_ income: EmploymentIncome?, _ benefit: BenefitInKind?) -> StatusPill {
        if let income {
            switch income.source {
            case .p60, .p45: return StatusPill(income.source.displayName, tone: .accent, systemImage: "doc.text", help: income.entryMethod.displayName)
            case .payslip, .other: return StatusPill(income.source.displayName, tone: .neutral, help: income.entryMethod.displayName)
            }
        }
        if benefit?.isFromP11DImport == true {
            return StatusPill("P11D", tone: .accent, systemImage: "doc.text", help: "Read from the P11D")
        }
        return StatusPill("By hand", tone: .neutral, help: "Entered by hand")
    }
}

/// A value in a `sheet(item:)` (the records aren't `Identifiable` while new).
struct Identified<Value>: Identifiable {
    let id = UUID()
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The amount of a text field, in pence (nil when it doesn't parse).
private func pence(_ text: String) -> Int? { Money.parseMinorUnits(text) }
private func text(_ pence: Int, isNew: Bool) -> String { isNew && pence == 0 ? "" : Money.formatInput(pence) }

// MARK: - Sheets

struct EmploymentSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let employment: Employment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var name: String
    @State private var reference: String
    @State private var hasStart: Bool
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var notes: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, employment: Employment) {
        self.viewModel = viewModel
        self.employment = employment
        let year = employment.ukTaxYear
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: employment.id.map { .employment($0) }))
        _name = State(initialValue: employment.employerName)
        _reference = State(initialValue: employment.payeReference ?? "")
        _hasStart = State(initialValue: employment.startDate != nil)
        _start = State(initialValue: employment.startDate ?? year.start)
        _hasEnd = State(initialValue: employment.endDate != nil)
        _end = State(initialValue: employment.endDate ?? year.lastDay)
        _notes = State(initialValue: employment.notes ?? "")
    }

    var body: some View {
        SheetScaffold(title: employment.id == nil ? "Add employment" : "Edit employment", subtitle: employment.ukTaxYear.label, error: error,
                      width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Employer") { TextField("Employer", text: $name, prompt: Text("e.g. Example Ltd")) }
                LabeledContent("PAYE reference") { TextField("PAYE reference", text: $reference, prompt: Text("123/AB456")) }
                LabeledContent("Started") {
                    HStack(spacing: 10) {
                        NamedCheckbox(title: "During \(employment.ukTaxYear.label)", isOn: $hasStart)
                        if hasStart { DatePicker("Start", selection: utcDay($start), displayedComponents: .date).labelsHidden().fixedSize() }
                    }
                }
                LabeledContent("Left") {
                    HStack(spacing: 10) {
                        NamedCheckbox(title: "During \(employment.ukTaxYear.label)", isOn: $hasEnd)
                        if hasEnd { DatePicker("Leaving date", selection: utcDay($end), displayedComponents: .date).labelsHidden().fixedSize() }
                    }
                }
                LabeledContent("Note") { TextField("Note", text: $notes, prompt: Text("Optional")) }
                LabeledContent("Documents") { StagedDocumentsField(documents: documents) }
                SheetFormNote("Link the P11D here; a P60 or P45 goes with its pay and tax.")
            }
        }
    }

    private func save() {
        var employment = employment
        employment.employerName = name
        employment.payeReference = reference
        employment.startDate = hasStart ? start : nil
        employment.endDate = hasEnd ? end : nil
        employment.notes = notes
        error = viewModel.saveEmployment(employment, documents: documents.staging.changes)
        if error == nil { dismiss() }
    }
}

struct EmploymentIncomeSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let income: EmploymentIncome
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var source: EmploymentIncomeSource
    @State private var payText: String
    @State private var taxText: String
    @State private var taxCode: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var notes: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, income: EmploymentIncome) {
        self.viewModel = viewModel
        self.income = income
        let isNew = income.id == nil
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: income.id.map { .employmentIncome($0) }))
        _source = State(initialValue: income.source)
        _payText = State(initialValue: text(income.payMinorUnits, isNew: isNew))
        _taxText = State(initialValue: text(income.taxDeductedMinorUnits, isNew: isNew))
        _taxCode = State(initialValue: income.taxCode ?? "")
        _hasDate = State(initialValue: income.periodEnd != nil)
        _date = State(initialValue: income.periodEnd ?? PayCalendar.utcDay(sameDayAs: AppClock.now, in: .current))
        _notes = State(initialValue: income.notes ?? "")
    }

    var body: some View {
        SheetScaffold(title: income.id == nil ? "Add pay and tax" : "Edit pay and tax", subtitle: "SA102 boxes 1 and 2", error: error, width: SheetMetrics.formWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: pence(payText) != nil && pence(taxText) != nil && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("From") {
                    Picker("From", selection: $source) {
                        ForEach(EmploymentIncomeSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Pay") { MoneyField("Pay", text: $payText, currency: .gbp, width: 140) }
                LabeledContent("Tax taken off") { MoneyField("Tax taken off", text: $taxText, currency: .gbp, width: 140) }
                SheetFormNote("A refund (marked R on the P60) is a negative amount.")
                LabeledContent("Tax code") { TextField("Tax code", text: $taxCode, prompt: Text("e.g. 1257L")).frame(width: 120) }
                LabeledContent("Date") {
                    HStack(spacing: 10) {
                        NamedCheckbox(title: "Dated", isOn: $hasDate)
                        if hasDate { DatePicker("Date", selection: utcDay($date), displayedComponents: .date).labelsHidden().fixedSize() }
                    }
                }
                SheetFormNote("The leaving date of a P45, or a payslip's date.")
                LabeledContent("Note") { TextField("Note", text: $notes, prompt: Text("Optional")) }
                LabeledContent("Documents") { StagedDocumentsField(documents: documents) }
            }
        }
    }

    private func save() {
        guard let pay = pence(payText), let tax = pence(taxText) else { return }
        var income = income
        income.source = source
        income.payMinorUnits = pay
        income.taxDeductedMinorUnits = tax
        income.taxCode = taxCode
        income.periodEnd = hasDate ? date : nil
        income.notes = notes
        error = viewModel.saveIncome(income, documents: documents.staging.changes)
        if error == nil { dismiss() }
    }
}

struct BenefitSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let benefit: BenefitInKind
    @Environment(\.dismiss) private var dismiss
    @State private var kind: BenefitKind
    @State private var amountText: String
    @State private var details: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, benefit: BenefitInKind) {
        self.viewModel = viewModel
        self.benefit = benefit
        _kind = State(initialValue: benefit.kind)
        _amountText = State(initialValue: text(benefit.cashEquivalentMinorUnits, isNew: benefit.id == nil))
        _details = State(initialValue: benefit.description ?? "")
    }

    var body: some View {
        SheetScaffold(title: benefit.id == nil ? "Add benefit" : "Edit benefit", subtitle: "P11D cash equivalent, SA102 box \(kind.sa102Box)",
                      error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(amountText) ?? -1) >= 0) { save() }) {
            SheetForm {
                LabeledContent("Benefit") {
                    Picker("Benefit", selection: $kind) {
                        ForEach(BenefitKind.allCases, id: \.self) { Text("\($0.p11dSection.map { "\($0) · " } ?? "")\($0.displayName)").tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Cash equivalent") { MoneyField("Cash equivalent", text: $amountText, currency: .gbp, width: 140) }
                LabeledContent("Description") { TextField("Description", text: $details, prompt: Text("As on the P11D")) }
                SheetFormNote(benefit.isFromP11DImport ? "Read from the P11D: a new P11D import replaces it." : "Entered by hand: a P11D import leaves it as it is.")
            }
        }
    }

    private func save() {
        guard let amount = pence(amountText) else { return }
        var benefit = benefit
        if benefit.kind != kind { benefit.sa102Box = kind.sa102Box }
        benefit.kind = kind
        benefit.cashEquivalentMinorUnits = amount
        benefit.description = details
        error = viewModel.saveBenefit(benefit)
        if error == nil { dismiss() }
    }
}

struct OtherIncomeSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let income: OtherIncome
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var kind: OtherIncomeKind
    @State private var payer: String
    @State private var amountText: String
    @State private var taxText: String
    @State private var currency: Currency
    @State private var notes: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, income: OtherIncome) {
        self.viewModel = viewModel
        self.income = income
        let isNew = income.id == nil
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: income.id.map { .otherIncome($0) }))
        _kind = State(initialValue: income.kind)
        _payer = State(initialValue: income.payer ?? "")
        _amountText = State(initialValue: text(income.amountMinorUnits, isNew: isNew))
        _taxText = State(initialValue: text(income.taxDeductedMinorUnits, isNew: isNew))
        _currency = State(initialValue: income.currency)
        _notes = State(initialValue: income.notes ?? "")
    }

    var body: some View {
        SheetScaffold(title: income.id == nil ? "Add other income" : "Edit other income", subtitle: UKTaxYear(startYear: income.startYear).label,
                      error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(amountText) ?? -1) >= 0 && (taxText.isEmpty || (pence(taxText) ?? -1) >= 0)
                                           && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Kind") {
                    Picker("Kind", selection: $kind) { ForEach(OtherIncomeKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.fixedSize()
                }
                LabeledContent("From") { TextField("From", text: $payer, prompt: Text("Bank, company or fund")) }
                LabeledContent("Amount") {
                    HStack {
                        // The picker beside it names the currency: the field doesn't repeat it.
                        MoneyField("Amount", text: $amountText, currency: currency, width: 140, showsCurrency: false)
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                LabeledContent("Tax taken off") { MoneyField("Tax taken off", text: $taxText, currency: currency, width: 140) }
                LabeledContent("Note") { TextField("Note", text: $notes, prompt: Text("Optional")) }
                LabeledContent("Documents") { StagedDocumentsField(documents: documents) }
            }
        }
    }

    private func save() {
        guard let amount = pence(amountText) else { return }
        var income = income
        income.kind = kind
        income.payer = payer
        income.amountMinorUnits = amount
        income.taxDeductedMinorUnits = pence(taxText) ?? 0
        income.currency = currency
        income.notes = notes
        error = viewModel.saveOtherIncome(income, documents: documents.staging.changes)
        if error == nil { dismiss() }
    }
}

struct PensionSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let contribution: PensionContribution
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var kind: PensionContributionKind
    @State private var provider: String
    @State private var paidText: String
    @State private var notes: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, contribution: PensionContribution) {
        self.viewModel = viewModel
        self.contribution = contribution
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: contribution.id.map { .pensionContribution($0) }))
        _kind = State(initialValue: contribution.kind)
        _provider = State(initialValue: contribution.provider ?? "")
        _paidText = State(initialValue: text(contribution.paidMinorUnits, isNew: contribution.id == nil))
        _notes = State(initialValue: contribution.notes ?? "")
    }

    var body: some View {
        SheetScaffold(title: contribution.id == nil ? "Add pension contribution" : "Edit pension contribution",
                      subtitle: UKTaxYear(startYear: contribution.startYear).label, error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(paidText) ?? -1) >= 0 && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Kind") {
                    Picker("Kind", selection: $kind) { ForEach(PensionContributionKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.fixedSize()
                }
                LabeledContent("Provider") { TextField("Provider", text: $provider) }
                LabeledContent("You paid") { MoneyField("You paid", text: $paidText, currency: .gbp, width: 140) }
                SheetFormNote("For relief at source, what you paid: the provider's 20% is added to it.")
                LabeledContent("Note") { TextField("Note", text: $notes, prompt: Text("Optional")) }
                LabeledContent("Documents") { StagedDocumentsField(documents: documents) }
            }
        }
    }

    private func save() {
        guard let paid = pence(paidText) else { return }
        var contribution = contribution
        contribution.kind = kind
        contribution.provider = provider
        contribution.paidMinorUnits = paid
        contribution.notes = notes
        error = viewModel.savePension(contribution, documents: documents.staging.changes)
        if error == nil { dismiss() }
    }
}

/// Records a payment to (or refund from) HMRC with its proof, optionally marking the year.
struct HMRCPaymentSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let payment: HMRCPayment
    let yearStatus: TaxYearStatus
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var kind: HMRCPaymentKind
    @State private var startYear: Int
    @State private var date: Date
    @State private var amountText: String
    @State private var reference: String
    @State private var notes: String
    @State private var markPaid: Bool
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, payment: HMRCPayment, yearStatus: TaxYearStatus, markPaid: Bool = false) {
        self.viewModel = viewModel
        self.payment = payment
        self.yearStatus = yearStatus
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: payment.id.map { .hmrcPayment($0) }))
        _kind = State(initialValue: payment.kind)
        _startYear = State(initialValue: payment.startYear)
        _date = State(initialValue: payment.date)
        _amountText = State(initialValue: text(payment.amountMinorUnits, isNew: payment.id == nil))
        _reference = State(initialValue: payment.reference ?? "")
        _notes = State(initialValue: payment.notes ?? "")
        _markPaid = State(initialValue: markPaid)
    }

    var body: some View {
        SheetScaffold(title: payment.id == nil ? "Record HMRC payment" : "Edit HMRC payment",
                      subtitle: "A payment to HMRC, or a refund from it, with its proof", error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(amountText) ?? 0) > 0 && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Kind") {
                    Picker("Kind", selection: $kind) { ForEach(HMRCPaymentKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.fixedSize()
                }
                LabeledContent("For tax year") {
                    Picker("For tax year", selection: $startYear) {
                        ForEach((payment.startYear - 2)...(payment.startYear + 2), id: \.self) { Text(UKTaxYear(startYear: $0).label).tag($0) }
                    }
                    .fixedSize()
                }
                SheetFormNote("A payment on account counts towards the year it's for (January's first payment is for the year after the return).")
                LabeledContent("Date") { DatePicker("Date", selection: utcDay($date), displayedComponents: .date).labelsHidden() }
                LabeledContent("Amount") { MoneyField("Amount", text: $amountText, currency: .gbp, width: 140) }
                LabeledContent("Reference") { TextField("Reference", text: $reference, prompt: Text("UTR followed by K")) }
                LabeledContent("Note") { TextField("Note", text: $notes, prompt: Text("Optional")) }
                if kind == .balancingPayment {
                    if yearStatus == .filed || yearStatus == .paid || startYear != payment.startYear {
                        LabeledContent("Status") { NamedCheckbox(title: "Mark \(UKTaxYear(startYear: startYear).label) as paid", isOn: $markPaid) }
                    } else {
                        SheetFormNote("Mark the return as filed first; then a balancing payment can mark the year as paid.")
                    }
                }
                LabeledContent("Proof") { StagedDocumentsField(documents: documents) }
            }
        }
    }

    private func save() {
        guard let amount = pence(amountText) else { return }
        var payment = payment
        payment.kind = kind
        payment.startYear = startYear
        payment.date = date
        payment.amountMinorUnits = amount
        payment.reference = reference
        payment.notes = notes
        let canMark = yearStatus == .filed || yearStatus == .paid || startYear != self.payment.startYear
        error = viewModel.savePayment(payment, documents: documents.staging.changes, markYear: markPaid && canMark && kind == .balancingPayment ? .paid : nil)
        if error == nil { dismiss() }
    }
}

// MARK: - Form import

/// What was read from a P60, P45 or P11D, editable before Save; the problems that stop it
/// and the reader's warnings show as you go.
struct PayrollFormConfirmSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let draft: TaxYearsViewModel.FormImportDraft
    let personId: Int64
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var kind: PayrollFormKind
    @State private var startYear: Int
    @State private var employer: String
    @State private var reference: String
    @State private var taxCode: String
    @State private var payText: String
    @State private var taxText: String
    @State private var leaving: Date
    @State private var benefits: [BenefitDraft]
    @State private var error: String?

    struct BenefitDraft: Identifiable {
        let id = UUID()
        var kind: BenefitKind
        var amountText: String
    }

    init(viewModel: TaxYearsViewModel, draft: TaxYearsViewModel.FormImportDraft, personId: Int64, defaultYear: Int) {
        self.viewModel = viewModel
        self.draft = draft
        self.personId = personId
        let e = draft.extraction
        _kind = State(initialValue: e.kind ?? .p60)
        _startYear = State(initialValue: e.startYear ?? defaultYear)
        _employer = State(initialValue: e.employerName ?? "")
        _reference = State(initialValue: e.payeReference ?? "")
        _taxCode = State(initialValue: e.taxCode ?? "")
        _payText = State(initialValue: e.payMinorUnits.map(Money.formatInput) ?? "")
        _taxText = State(initialValue: e.taxDeductedMinorUnits.map(Money.formatInput) ?? "")
        _leaving = State(initialValue: e.leavingDate ?? UKTaxYear(startYear: e.startYear ?? defaultYear).lastDay)
        _benefits = State(initialValue: e.benefits.map { BenefitDraft(kind: $0.kind, amountText: Money.formatInput($0.cashEquivalentMinorUnits)) })
    }

    private var confirmed: PayrollFormImport.Confirmed {
        PayrollFormImport.Confirmed(kind: kind, personId: personId, startYear: startYear, employerName: employer, payeReference: reference,
                                    taxCode: taxCode, payMinorUnits: pence(payText), taxDeductedMinorUnits: pence(taxText),
                                    leavingDate: kind == .p45 ? leaving : nil,
                                    benefits: benefits.compactMap { b in pence(b.amountText).map { .init(kind: b.kind, cashEquivalentMinorUnits: $0) } },
                                    entryMethod: draft.extraction.entryMethod)
    }

    private var problems: [PayrollFormImport.Problem] { PayrollFormImport.problems(confirmed) }
    /// Benefit rows whose amount doesn't read (Save stays off until they do).
    private var hasInvalidBenefit: Bool { kind == .p11d && benefits.contains { pence($0.amountText).map { $0 < 0 } ?? true } }
    @State private var saved = false

    var body: some View {
        sheet.onDisappear { if !saved { viewModel.discardImport(draft) } }
    }

    private var sheet: some View {
        SheetScaffold(title: "Confirm \(kind.displayName)",
                      subtitle: "Check what was read, then Save." + (draft.isNewDocument ? " Cancel takes the file out of the library again." : ""),
                      error: error, width: SheetMetrics.listWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: problems.isEmpty && !hasInvalidBenefit) { save() }) {
            // The form's file, and how it was read (text recognition: check every figure).
            HStack(spacing: 8) {
                Label(draft.fileName, systemImage: "doc.text")
                    .lineLimit(1).truncationMode(.middle)
                    .help(draft.fileName)
                StatusPill(draft.extraction.entryMethod.displayName, tone: draft.extraction.entryMethod == .ocr ? .warning : .neutral,
                           help: draft.extraction.entryMethod == .ocr ? "Read by text recognition: check every figure" : nil)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.sectionHeaderTint))
            SheetForm {
                LabeledContent("Form") {
                    Picker("Form", selection: $kind) { ForEach(PayrollFormKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        .pickerStyle(.segmented).prominentTint().fixedSize()
                }
                LabeledContent("Tax year") {
                    Picker("Tax year", selection: $startYear) {
                        ForEach(UKTaxRules.knownYears.reversed(), id: \.self) { Text(UKTaxYear(startYear: $0).label).tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Employer") { TextField("Employer", text: $employer) }
                LabeledContent("PAYE reference") { TextField("PAYE reference", text: $reference, prompt: Text("123/AB456")) }
                if kind != .p11d {
                    LabeledContent("Pay") { MoneyField("Pay", text: $payText, currency: .gbp, width: 140) }
                    LabeledContent("Tax taken off") { MoneyField("Tax taken off", text: $taxText, currency: .gbp, width: 140) }
                    LabeledContent("Tax code") { TextField("Tax code", text: $taxCode).frame(width: 120) }
                }
                if kind == .p45 {
                    LabeledContent("Leaving date") { DatePicker("Leaving date", selection: utcDay($leaving), displayedComponents: .date).labelsHidden().fixedSize() }
                }
                if kind == .p11d {
                    LabeledContent("Benefits") { benefitsEditor }
                }
                if let total = draft.extraction.totalPayMinorUnits, kind == .p60, draft.extraction.previousPayMinorUnits ?? 0 != 0 {
                    SheetFormNote("Total for the year \(Money.format(total, currency: .gbp)) includes previous employments.")
                }
            }
            messages
        }
    }

    /// The P11D's benefits as a small table: the benefit (with its SA102 box), its cash
    /// equivalent and a remove icon per row, then Add benefit.
    private var benefitsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if benefits.isEmpty {
                Text("None read: add each benefit the P11D lists.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Benefit")
                        Text("Cash equivalent").gridColumnAlignment(.trailing)
                        Text(verbatim: "")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    ForEach($benefits) { $benefit in
                        GridRow {
                            Picker("Benefit", selection: $benefit.kind) {
                                ForEach(BenefitKind.allCases, id: \.self) { Text("Box \($0.sa102Box) · \($0.displayName)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MoneyField("Cash equivalent", text: $benefit.amountText, currency: .gbp, width: 100)
                            Button { benefits.removeAll { $0.id == benefit.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this benefit")
                                .accessibilityLabel("Remove \(benefit.kind.displayName)")
                        }
                    }
                }
            }
            Button { benefits.append(BenefitDraft(kind: .medical, amountText: "")) } label: { Label("Add benefit", systemImage: "plus") }
                .controlSize(.small)
            SheetCaption("Saving replaces the benefits of an earlier P11D import; benefits typed in by hand stay.")
        }
    }

    /// What stops Save (red), then the reader's warnings (amber), each as one banner.
    @ViewBuilder
    private var messages: some View {
        let warnings = draft.personWarnings + draft.extraction.warnings
        let blocking = (hasInvalidBenefit ? ["Enter each benefit's cash equivalent (or remove the row)."] : []) + problems.map(TaxIncomeMessages.text)
        if !blocking.isEmpty {
            InlineBanner(.error) {
                VStack(alignment: .leading, spacing: 3) { ForEach(blocking, id: \.self) { Text($0) } }
            }
        }
        if !warnings.isEmpty {
            InlineBanner(.warning) {
                VStack(alignment: .leading, spacing: 3) { ForEach(warnings, id: \.self) { Text($0) } }
            }
        }
    }

    private func save() {
        error = viewModel.applyForm(confirmed, documentId: draft.documentId)
        if error == nil {
            saved = true
            dismiss()
        }
    }
}
