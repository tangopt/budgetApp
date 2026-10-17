// App/Tax/TaxYearsView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// Tax years (plan phase 3 Task 4, phase 4 Task 4): the people's UK tax years on the left
/// (status, deadlines, whether the HMRC rate is in), and the chosen year's page on the right —
/// Income, Rental accounts, Return, Calculation, Filing, Settings, Manual items, Missing
/// evidence and Export tabs over `TaxYearsViewModel`.
struct TaxYearsView: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    /// The shared Missing evidence model: its tab shows the year's checklist.
    @ObservedObject var missingEvidenceViewModel: MissingEvidenceViewModel
    let openTransaction: (Transaction) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            TaxYearsList(viewModel: viewModel)
                .frame(width: 280)
            Divider()
            Group {
                if let page = viewModel.page {
                    TaxYearPage(viewModel: viewModel, page: page, missingEvidenceViewModel: missingEvidenceViewModel,
                                openTransaction: openTransaction)
                } else if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No tax years yet").font(.title3.weight(.semibold))
            Text("Add a property and its owners: each owner's UK tax years show here from the first year they own it.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list of tax years, latest first.
struct TaxYearsList: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        List(selection: $viewModel.selection) {
            ForEach(viewModel.snapshot.rows) { row in
                if let personId = row.person.id {
                    TaxYearRowView(row: row)
                        .tag(TaxYearsViewModel.Selection(personId: personId, startYear: row.year.startYear))
                }
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("Tax years")
    }
}

struct TaxYearRowView: View {
    let row: TaxOverview.YearRow
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.year.label).font(.headline).monospacedDigit()
                Text(row.person.name).lineLimit(1)
                Spacer(minLength: 4)
                Label(TaxFormat.status(row.status), systemImage: TaxFormat.statusImage(row.status))
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(row.status == .preparing ? .secondary : theme.income)
                    .lineLimit(1).fixedSize()
            }
            Text("Return and payment \(DocumentFormat.day(row.deadlines.onlineReturnAndBalancingPayment)) · 2nd payment \(DocumentFormat.day(row.deadlines.secondPaymentOnAccount))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if row.eurRate == nil {
                Label("No HMRC EUR rate", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(theme.expense)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One person's year.
struct TaxYearPage: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @ObservedObject var missingEvidenceViewModel: MissingEvidenceViewModel
    let openTransaction: (Transaction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TaxBanners(viewModel: viewModel)
            if viewModel.tab == .missingEvidence {
                TaxMissingEvidenceTab(viewModel: missingEvidenceViewModel, page: page, openTransaction: openTransaction)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.bottom, 12)
                    }
                    .onChange(of: viewModel.focusedStep) { scroll(proxy) }
                    .onChange(of: page.selfAssessment != nil) { scroll(proxy) }
                }
            }
        }
        .padding(12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(page.row.year.label) · \(page.row.person.name)").font(.title3.weight(.semibold)).lineLimit(1)
                if page.row.properties.count > 1 {
                    Picker("Property", selection: Binding(get: { page.property?.id }, set: { viewModel.propertyId = $0 })) {
                        ForEach(page.row.properties) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Property")
                } else if let property = page.property {
                    Text(property.name).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("Status", selection: Binding(get: { page.row.status }, set: { viewModel.setStatus($0) })) {
                    ForEach(TaxYearStatus.allCases, id: \.self) { status in
                        Label(TaxFormat.status(status), systemImage: TaxFormat.statusImage(status)).tag(status)
                    }
                }
                .fixedSize()
                .help("Preparing → Ready → Filed → Paid")
                .accessibilityLabel("Status")
            }
            Picker("Section", selection: $viewModel.tab) {
                ForEach(TaxYearsViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Tax year section")
        }
    }

    /// Scrolls to the requested step on the next run loop, once the Calculation tab's rows exist.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let step = viewModel.focusedStep?.title, viewModel.tab == .calculation else { return }
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(step, anchor: .top) } }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .income: TaxIncomeTab(viewModel: viewModel, page: page)
        case .accounts: TaxAccountsTab(viewModel: viewModel, page: page, openTransaction: openTransaction)
        case .taxReturn: TaxReturnTab(viewModel: viewModel, page: page)
        case .calculation: TaxCalculationTab(viewModel: viewModel, page: page)
        case .filing: TaxFilingTab(viewModel: viewModel, page: page)
        case .settings: TaxSettingsTab(viewModel: viewModel, page: page)
        case .manualItems: TaxManualItemsTab(viewModel: viewModel, page: page)
        case .missingEvidence: EmptyView()
        case .export: TaxExportTab(viewModel: viewModel, page: page)
        }
    }
}

/// The Missing evidence checklist for the year on show (and its property), following the page
/// as the year changes; the standalone screen's period and filter are put back on leaving.
struct TaxMissingEvidenceTab: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    let page: TaxOverview.YearPage
    let openTransaction: (Transaction) -> Void
    @State private var saved: (MissingEvidenceViewModel.PeriodChoice, MissingEvidenceViewModel.PropertyFilter?)?

    private var key: String { "\(page.row.year.startYear)-\(page.property?.id ?? 0)" }

    var body: some View {
        MissingEvidenceView(viewModel: viewModel, openTransaction: openTransaction)
            .onAppear {
                if saved == nil { saved = (viewModel.periodChoice, viewModel.propertyFilter) }
                follow()
            }
            .onChange(of: key) { follow() }
            .onDisappear {
                if let saved {
                    viewModel.periodChoice = saved.0
                    viewModel.propertyFilter = saved.1
                }
                saved = nil
            }
    }

    private func follow() {
        viewModel.periodChoice = .taxYear(page.row.year.startYear)
        viewModel.propertyFilter = page.property.flatMap { property in
            property.id.map { MissingEvidenceViewModel.PropertyFilter(propertyId: $0, name: property.name) }
        }
    }
}

/// Error and info lines under the header.
struct TaxBanners: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        if let error = viewModel.errorMessage {
            banner(error, systemImage: "exclamationmark.triangle.fill", color: theme.expense) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            banner(info, systemImage: "info.circle", color: .secondary) { viewModel.infoMessage = nil }
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
    }
}

// MARK: - Export

struct TaxExportTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PropertySection("Accountant") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The accountant's template for \(page.row.person.name): rental accounts by month and expense line in the property's currency, and the FTCR figures.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Accountant template (.xlsx)…") { viewModel.exportTemplate() }
                        Button("Rental accounts (PDF)…") { viewModel.exportPDF() }
                    }
                    .disabled(page.accounts == nil)
                }
            }
            PropertySection("Evidence pack") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A folder with every document behind this year's figures, one subfolder per line, under their canonical names.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Export evidence folder…") { viewModel.exportEvidencePack() }
                        .disabled(page.accounts == nil)
                }
            }
            if page.accounts == nil {
                Text("\(page.row.person.name) owns no property in \(page.row.year.label): there are no rental accounts to export.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
