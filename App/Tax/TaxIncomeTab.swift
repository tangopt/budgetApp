// App/Tax/TaxIncomeTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The person's income for the year (plan phase 4 Task 4): employments with their pay and tax
/// (P60 / P45 / payslips) and P11D benefits, other income, pension contributions and HMRC
/// payments, each with its documents. A P60, P45 or P11D PDF is read and shown in a confirm
/// sheet, editable before Save. Changes in sheets are written by Save.
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
        VStack(alignment: .leading, spacing: 12) {
            if !income.hasEvidenceRules {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Missing evidence can ask for each P60, P45, P11D and HMRC payment proof.").foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Set up evidence rules") { viewModel.seedIncomeEvidenceRules() }
                }
                .font(.callout)
            }
            employmentsSection
            otherIncomeSection
            pensionsSection
            paymentsSection
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
            Text(deleting?.detail ?? "")
        }
    }

    // MARK: Sections

    private var employmentsSection: some View {
        PropertySection("Employment · \(page.row.year.label)", accessory: {
            HStack(spacing: 10) {
                if reading { ProgressView().controlSize(.small) }
                Button("Import P60, P45 or P11D…") { importing = true }.disabled(reading)
                Button("Add employment…") { editingEmployment = Identified(Employment(startYear: startYear, personId: personId, employerName: "")) }
            }
            .buttonStyle(.borderless)
        }) {
            if income.employments.isEmpty {
                Text("None. Import the P60 (or P45) and P11D, or add the employment by hand.").foregroundStyle(.secondary)
            }
            ForEach(income.employments) { row in
                employmentRow(row)
                if row.id != income.employments.last?.id { Divider() }
            }
        }
    }

    private func employmentRow(_ row: SelfAssessmentOverview.EmploymentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.employment.employerName).font(.body.weight(.semibold)).lineLimit(1)
                    Text([row.employment.payeReference, row.employment.endDate.map { "left \(DocumentFormat.day($0))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                DocumentCountBadge(count: row.documentCount)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Button("Add pay and tax…") {
                        editingIncome = Identified(EmploymentIncome(employmentId: row.id, source: row.incomes.isEmpty ? .p60 : .payslip, payMinorUnits: 0,
                                                         taxDeductedMinorUnits: 0))
                    }
                    .accessibilityLabel("Add pay and tax for \(row.employment.employerName)")
                    Button("Add benefit…") { editingBenefit = Identified(BenefitInKind(employmentId: row.id, kind: .medical, cashEquivalentMinorUnits: 0)) }
                        .accessibilityLabel("Add a benefit for \(row.employment.employerName)")
                    Button("Edit…") { editingEmployment = Identified(row.employment) }
                        .accessibilityLabel("Edit \(row.employment.employerName)")
                    Button("Delete…", role: .destructive) {
                        deleting = Deletion(title: "Delete “\(row.employment.employerName)”?",
                                            detail: "Its pay and tax, benefits and document links go too; the documents stay in the library.") {
                            viewModel.deleteEmployment(row.id)
                        }
                    }
                    .accessibilityLabel("Delete \(row.employment.employerName)")
                }
                .buttonStyle(.borderless)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(row.incomes, id: \.id) { income in
                    GridRow {
                        Text(income.source.displayName).lineLimit(1)
                        Text("Pay").foregroundStyle(.secondary)
                        PropertyMoney(minorUnits: income.payMinorUnits, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                        Text("Tax").foregroundStyle(.secondary)
                        PropertyMoney(minorUnits: income.taxDeductedMinorUnits, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                        Text([income.taxCode, income.entryMethod.displayName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        rowButtons(edit: { editingIncome = Identified(income) }, name: "\(income.source.displayName) pay and tax") {
                            viewModel.deleteIncome(income.id ?? 0)
                        }
                    }
                }
                ForEach(row.benefits, id: \.id) { benefit in
                    GridRow {
                        Text("Box \(benefit.sa102Box)").lineLimit(1)
                        Text(benefit.kind.displayName).foregroundStyle(.secondary).lineLimit(1).gridCellColumns(3)
                        PropertyMoney(minorUnits: benefit.cashEquivalentMinorUnits, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                        Text(benefit.isFromP11DImport ? "From the P11D" : "Entered by hand").font(.caption).foregroundStyle(.secondary)
                        rowButtons(edit: { editingBenefit = Identified(benefit) }, name: benefit.kind.displayName) { viewModel.deleteBenefit(benefit.id ?? 0) }
                    }
                }
            }
        }
    }

    private var otherIncomeSection: some View {
        PropertySection("Other income", accessory: {
            Button("Add income…") { editingOther = Identified(OtherIncome(startYear: startYear, personId: personId, kind: .ukInterest, amountMinorUnits: 0)) }
                .buttonStyle(.borderless)
        }) {
            if income.otherIncomes.isEmpty {
                Text("None: UK and foreign interest, dividends or other taxable income go here.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(income.otherIncomes, id: \.id) { item in
                        GridRow {
                            Text(item.kind.displayName).lineLimit(1)
                            Text(item.payer ?? "—").foregroundStyle(.secondary).lineLimit(1)
                            PropertyMoney(minorUnits: item.amountMinorUnits, currency: item.currency, neutral: true).gridColumnAlignment(.trailing)
                            DocumentCountBadge(count: income.documentCounts[.otherIncome(item.id ?? 0)] ?? 0)
                            rowButtons(edit: { editingOther = Identified(item) }, name: item.kind.displayName) { viewModel.deleteOtherIncome(item.id ?? 0) }
                        }
                    }
                }
            }
        }
    }

    private var pensionsSection: some View {
        PropertySection("Pension contributions", accessory: {
            Button("Add contribution…") {
                editingPension = Identified(PensionContribution(startYear: startYear, personId: personId, kind: .reliefAtSource, paidMinorUnits: 0))
            }
            .buttonStyle(.borderless)
        }) {
            if income.pensions.isEmpty {
                Text("None. Contributions taken from pay before tax (net pay) don't go on the return.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(income.pensions, id: \.id) { item in
                        GridRow {
                            Text(item.kind.displayName).lineLimit(1)
                            Text(item.provider ?? "—").foregroundStyle(.secondary).lineLimit(1)
                            PropertyMoney(minorUnits: item.paidMinorUnits, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                            DocumentCountBadge(count: income.documentCounts[.pensionContribution(item.id ?? 0)] ?? 0)
                            rowButtons(edit: { editingPension = Identified(item) }, name: item.kind.displayName) { viewModel.deletePension(item.id ?? 0) }
                        }
                    }
                }
            }
        }
    }

    private var paymentsSection: some View {
        PropertySection("HMRC payments", accessory: {
            Button("Record payment…") {
                editingPayment = Identified(HMRCPayment(personId: personId, startYear: startYear, date: PayCalendar.utcDay(sameDayAs: Date(), in: .current), amountMinorUnits: 0,
                                             kind: .balancingPayment))
            }
            .buttonStyle(.borderless)
        }) {
            if income.payments.isEmpty {
                Text("None recorded for \(page.row.year.label) (or towards \(UKTaxYear(startYear: startYear + 1).label)).").foregroundStyle(.secondary)
            } else {
                HMRCPaymentsGrid(payments: income.payments, counts: income.documentCounts,
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

    private func rowButtons(edit: @escaping () -> Void, name: String, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("Edit…", action: edit).accessibilityLabel("Edit \(name)")
            Button("Delete…", role: .destructive) {
                deleting = Deletion(title: "Delete \(name)?", detail: "Its document links go too; the documents stay in the library.", action: delete)
            }
            .accessibilityLabel("Delete \(name)")
        }
        .buttonStyle(.borderless)
    }
}

/// HMRC payments with their proofs.
struct HMRCPaymentsGrid: View {
    let payments: [HMRCPayment]
    let counts: [EvidenceEntity: Int]
    let edit: (HMRCPayment) -> Void
    let delete: (HMRCPayment) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(payments, id: \.id) { payment in
                GridRow {
                    Text(DocumentFormat.day(payment.date)).monospacedDigit().lineLimit(1).fixedSize()
                    Text("\(payment.kind.displayName) · \(UKTaxYear(startYear: payment.startYear).label)").lineLimit(1)
                    PropertyMoney(minorUnits: payment.signedMinorUnits, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                    DocumentCountBadge(count: counts[.hmrcPayment(payment.id ?? 0)] ?? 0)
                    HStack(spacing: 8) {
                        Button("Edit…") { edit(payment) }.accessibilityLabel("Edit \(payment.kind.displayName)")
                        Button("Delete…", role: .destructive) { delete(payment) }.accessibilityLabel("Delete \(payment.kind.displayName)")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
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
                      width: 520, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Employer") { TextField("Employer", text: $name, prompt: Text("e.g. Example Ltd")) }
                LabeledContent("PAYE reference") { TextField("PAYE reference", text: $reference, prompt: Text("123/AB456")) }
                LabeledContent("Started in the year") {
                    HStack {
                        Toggle("Started in the year", isOn: $hasStart).labelsHidden()
                        if hasStart { DatePicker("Start", selection: utcDay($start), displayedComponents: .date).labelsHidden() }
                    }
                }
                LabeledContent("Left in the year") {
                    HStack {
                        Toggle("Left in the year", isOn: $hasEnd).labelsHidden()
                        if hasEnd { DatePicker("Leaving date", selection: utcDay($end), displayedComponents: .date).labelsHidden() }
                    }
                }
                LabeledContent("Note") { TextField("Note", text: $notes) }
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
        _date = State(initialValue: income.periodEnd ?? PayCalendar.utcDay(sameDayAs: Date(), in: .current))
        _notes = State(initialValue: income.notes ?? "")
    }

    var body: some View {
        SheetScaffold(title: income.id == nil ? "Add pay and tax" : "Edit pay and tax", subtitle: "SA102 boxes 1 and 2", error: error, width: 520,
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
                    HStack {
                        Toggle("Dated", isOn: $hasDate).labelsHidden()
                        if hasDate { DatePicker("Date", selection: utcDay($date), displayedComponents: .date).labelsHidden() }
                    }
                }
                SheetFormNote("The leaving date of a P45, or a payslip's date.")
                LabeledContent("Note") { TextField("Note", text: $notes) }
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
                      error: error, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(amountText) ?? -1) >= 0) { save() }) {
            SheetForm {
                LabeledContent("Benefit") {
                    Picker("Benefit", selection: $kind) {
                        ForEach(BenefitKind.allCases, id: \.self) { Text("\($0.p11dSection.map { "\($0) · " } ?? "")\($0.displayName)").tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Cash equivalent") { MoneyField("Cash equivalent", text: $amountText, currency: .gbp, width: 140) }
                LabeledContent("Description") { TextField("Description", text: $details) }
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
                      error: error, width: 520, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(amountText) ?? -1) >= 0 && (taxText.isEmpty || (pence(taxText) ?? -1) >= 0)
                                           && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Kind") {
                    Picker("Kind", selection: $kind) { ForEach(OtherIncomeKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.fixedSize()
                }
                LabeledContent("From") { TextField("From", text: $payer, prompt: Text("Bank, company or fund")) }
                LabeledContent("Amount") {
                    HStack {
                        MoneyField("Amount", text: $amountText, currency: currency, width: 140)
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                LabeledContent("Tax taken off") { MoneyField("Tax taken off", text: $taxText, currency: currency, width: 140) }
                LabeledContent("Note") { TextField("Note", text: $notes) }
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
                      subtitle: UKTaxYear(startYear: contribution.startYear).label, error: error, width: 520, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (pence(paidText) ?? -1) >= 0 && documents.addingCount == 0) { save() }) {
            SheetForm {
                LabeledContent("Kind") {
                    Picker("Kind", selection: $kind) { ForEach(PensionContributionKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.fixedSize()
                }
                LabeledContent("Provider") { TextField("Provider", text: $provider) }
                LabeledContent("You paid") { MoneyField("You paid", text: $paidText, currency: .gbp, width: 140) }
                SheetFormNote("For relief at source, what you paid: the provider's 20% is added to it.")
                LabeledContent("Note") { TextField("Note", text: $notes) }
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
        SheetScaffold(title: payment.id == nil ? "Record HMRC payment" : "Edit HMRC payment", error: error, width: 520, onCancel: { dismiss() },
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
                LabeledContent("Note") { TextField("Note", text: $notes) }
                if kind == .balancingPayment {
                    if yearStatus == .filed || yearStatus == .paid || startYear != payment.startYear {
                        LabeledContent("Status") { Toggle("Mark \(UKTaxYear(startYear: startYear).label) as paid", isOn: $markPaid) }
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
        SheetScaffold(title: "Confirm \(kind.displayName)", subtitle: "\(draft.fileName) · \(draft.extraction.entryMethod.displayName)", error: error,
                      width: 600, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: problems.isEmpty && !hasInvalidBenefit) { save() }) {
            SheetForm {
                LabeledContent("Form") {
                    Picker("Form", selection: $kind) { ForEach(PayrollFormKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        .pickerStyle(.segmented).fixedSize()
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
                    LabeledContent("Leaving date") { DatePicker("Leaving date", selection: utcDay($leaving), displayedComponents: .date).labelsHidden() }
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

    private var benefitsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($benefits) { $benefit in
                HStack(spacing: 6) {
                    Picker("Benefit", selection: $benefit.kind) {
                        ForEach(BenefitKind.allCases, id: \.self) { Text("Box \($0.sa102Box) · \($0.displayName)").tag($0) }
                    }
                    .labelsHidden().frame(width: 280)
                    MoneyField("Cash equivalent", text: $benefit.amountText, currency: .gbp, width: 110)
                    Button { benefits.removeAll { $0.id == benefit.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(benefit.kind.displayName)")
                }
            }
            Button("Add benefit") { benefits.append(BenefitDraft(kind: .medical, amountText: "")) }.controlSize(.small)
            Text("Saving replaces the benefits of an earlier P11D import; benefits typed in by hand stay.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messages: some View {
        let warnings = draft.personWarnings + draft.extraction.warnings
        if !warnings.isEmpty || !problems.isEmpty || hasInvalidBenefit {
            VStack(alignment: .leading, spacing: 3) {
                if hasInvalidBenefit {
                    Label("Enter each benefit's cash equivalent (or remove the row).", systemImage: "xmark.octagon").foregroundStyle(theme.expense)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(TaxIncomeMessages.text(problem), systemImage: "xmark.octagon").foregroundStyle(theme.expense)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
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
