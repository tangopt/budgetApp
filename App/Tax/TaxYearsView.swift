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
        .filedYearGate(viewModel.filedYearGate)
    }

    private var emptyState: some View {
        EmptyState(systemImage: "doc.text", title: "No tax years yet",
                   message: "Add a property and its owners: each owner's UK tax years show here from the first year they own it.")
            .fillingScreen()
    }
}

/// The list of tax years, latest first: one section per year (its label, the online return
/// and balancing payment deadline, a pill when the year has no HMRC EUR rate), one row per
/// person with their status as a pill.
struct TaxYearsList: View {
    @ObservedObject var viewModel: TaxYearsViewModel

    /// The rows by year, in the list's order.
    private var years: [(year: UKTaxYear, rows: [TaxOverview.YearRow])] {
        var groups: [(year: UKTaxYear, rows: [TaxOverview.YearRow])] = []
        for row in viewModel.snapshot.rows {
            if let last = groups.indices.last, groups[last].year == row.year {
                groups[last].rows.append(row)
            } else {
                groups.append((row.year, [row]))
            }
        }
        return groups
    }

    var body: some View {
        List(selection: $viewModel.selection) {
            ForEach(Array(years.enumerated()), id: \.element.year.startYear) { index, group in
                // The year as a row of its own (not a section header, whose inset adds a gap
                // between the year and its people); it can't be selected.
                TaxYearHeaderView(year: group.year, rateMissing: group.rows.contains { $0.eurRate == nil })
                    .padding(.top, index == 0 ? 0 : 8)
                    .selectionDisabled()
                ForEach(group.rows) { row in
                    if let personId = row.person.id {
                        TaxYearRowView(row: row)
                            .tag(TaxYearsViewModel.Selection(personId: personId, startYear: row.year.startYear))
                    }
                }
            }
        }
        .wrapProbeClips()
        .listStyle(.inset)
        // On the window's colour like the page beside it (the list's own white or grey would
        // be a stripe of system colour in a theme with a background of its own).
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Tax years")
    }
}

/// A year's strip in the list: the year, "No EUR rate" when HMRC's average is missing, and
/// the online return and balancing payment deadline (every deadline in its tooltip).
struct TaxYearHeaderView: View {
    let year: UKTaxYear
    let rateMissing: Bool

    var body: some View {
        HStack(spacing: 5) {
            // The year never wraps: the pill and the deadline beside it are fixed too.
            Text(year.label).font(.subheadline.bold()).monospacedDigit().foregroundStyle(.primary)
                .figureText()
            Spacer(minLength: 0)
            if rateMissing {
                // HMRC's average is for the year to 31 March: missing only once the year is over.
                if AppClock.now >= year.end {
                    StatusPill("No EUR rate", tone: .warning,
                               help: "No HMRC average EUR rate for \(year.label) yet: fetch it or enter it in the year's Settings.")
                } else {
                    StatusPill("Rate after 31 Mar", tone: .neutral,
                               help: "HMRC's average EUR rate for \(year.label) is for the year to 31 March: it's fetched once the year is over.")
                }
            }
            // Beside a pill the row has no room for "Due" too: the day stays (every deadline on hover).
            if !rateMissing {
                Text("Due").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .accessibilityHidden(true)
            }
            DateText(date: year.deadlines.onlineReturnAndBalancingPayment, font: .caption, alignment: .trailing)
                .accessibilityLabel("Due \(DocumentFormat.day(year.deadlines.onlineReturnAndBalancingPayment))")
        }
        .help(TaxFormat.deadlines(year))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A person's year: their name (and properties when several) and the year's status.
struct TaxYearRowView: View {
    let row: TaxOverview.YearRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.person.name).lineLimit(1)
            if row.properties.count > 1 {
                Text("\(row.properties.count) properties").font(.caption).foregroundStyle(.secondary).figureText()
            }
            Spacer(minLength: 4)
            TaxStatusPill(status: row.status)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A tax year's status as a pill: preparing neutral, ready under way, filed and paid done.
struct TaxStatusPill: View {
    let status: TaxYearStatus

    var body: some View {
        StatusPill(TaxFormat.status(status), tone: TaxFormat.statusTone(status))
    }
}

/// One person's year.
struct TaxYearPage: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @ObservedObject var missingEvidenceViewModel: MissingEvidenceViewModel
    let openTransaction: (Transaction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            header
            TaxBanners(viewModel: viewModel)
            if viewModel.tab == .missingEvidence {
                TaxMissingEvidenceTab(viewModel: missingEvidenceViewModel, page: page, openTransaction: openTransaction)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.bottom, ScreenMetrics.padding)
                    }
                    .onChange(of: viewModel.focusedStep) { scroll(proxy) }
                    .onChange(of: page.selfAssessment != nil) { scroll(proxy) }
                }
            }
        }
        .padding([.horizontal, .top], ScreenMetrics.padding)
    }

    /// The year, person and property with the year's status on one line (a rate fetched
    /// automatically noted between them), the sections beneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(page.row.year.label) · \(page.row.person.name)")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .figureText()
                if page.row.properties.count > 1 {
                    Picker("Property", selection: Binding(get: { page.property?.id }, set: { viewModel.propertyId = $0 })) {
                        ForEach(page.row.properties) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Property")
                } else if let property = page.property {
                    Label(property.name, systemImage: "house")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(viewModel.automaticallyFetchedRates, id: \.currencyCode) { rate in
                    // The rate stays whole; the words after it truncate.
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text(rate.bothWaysText + ",").figureText()
                        Text("fetched automatically").lineLimit(1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .help("HMRC average rate fetched automatically. \(rate.notes ?? "HMRC's average for the year to 31 March")")
                }
                Spacer(minLength: 8)
                Text("Status").foregroundStyle(.secondary)
                Picker("Status", selection: Binding(get: { page.row.status }, set: { viewModel.setStatus($0) })) {
                    ForEach(TaxYearStatus.allCases, id: \.self) { status in
                        Label(TaxFormat.status(status), systemImage: TaxFormat.statusImage(status)).tag(status)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Preparing → Ready → Filed → Paid")
                .accessibilityLabel("Status")
            }
            .frame(minHeight: 24)
            // Never wider than the page (C6): the sections that fit, then a More menu.
            ScreenTabs("Tax year section", selection: $viewModel.tab, tabs: TaxYearsViewModel.Tab.allCases, label: \.rawValue)
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
        MissingEvidenceView(viewModel: viewModel, openTransaction: openTransaction, embedded: true)
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

    var body: some View {
        if let error = viewModel.errorMessage {
            InlineBanner(.error, error) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            InlineBanner(.info, info) { viewModel.infoMessage = nil }
        }
    }
}

// MARK: - Export

/// The year's exports as cards — the accountant's template, the rental accounts PDF and the
/// evidence pack — each saying what it holds and the name it's saved under, with one button.
struct TaxExportTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage

    private var personName: String { page.row.person.name }

    /// The documents behind the lines the pack copies (not-deductible items stay out).
    private var documentCount: Int {
        guard let accounts = page.accounts else { return 0 }
        return Set(accounts.allLines.filter { $0.expenseType != .notDeductible }.flatMap(\.sources).flatMap(\.documentIds)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if page.accounts == nil {
                InlineBanner(.info, "\(personName) owns no property in \(page.row.year.label): there are no rental accounts to export.")
            }
            PanelGrid(minColumnWidth: 250) {
                TaxExportCard(title: "Accountant template", systemImage: "tablecells",
                              text: "The accountant's workbook for \(personName): rental accounts by month and expense line in the property's currency, and the FTCR figures.",
                              fileName: AccountantTemplate.fileName(taxYear: page.row.year, personName: personName),
                              button: "Export workbook…", isEnabled: page.accounts != nil) { viewModel.exportTemplate() }
                TaxExportCard(title: "Rental accounts", systemImage: "doc.richtext",
                              text: "The year's rental accounts as a PDF: each line with its rule and share, in the property's currency and in GBP at HMRC's rate.",
                              fileName: TaxFileNames.rentalAccountsPDF(year: page.row.year, personName: personName),
                              button: "Export PDF…", isEnabled: page.accounts != nil) { viewModel.exportPDF() }
                TaxExportCard(title: "Evidence pack", systemImage: "folder",
                              text: "A folder with every document behind this year's figures, one subfolder per line, under their canonical names.",
                              detail: page.accounts == nil ? nil
                                  : documentCount == 0 ? "No documents linked to the lines yet"
                                  : "\(documentCount) document\(documentCount == 1 ? "" : "s") behind the lines",
                              fileName: TaxEvidencePack.folderName(year: page.row.year, personName: personName),
                              button: "Export folder…", isEnabled: page.accounts != nil) { viewModel.exportEvidencePack() }
            }
        }
    }
}

/// One export: an icon and title, what it holds, the name it's saved under, and its button.
struct TaxExportCard: View {
    let title: String
    let systemImage: String
    let text: String
    var detail: String? = nil
    let fileName: String
    let button: String
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Panel(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.title3).foregroundStyle(theme.accent)
                        .frame(width: 24).accessibilityHidden(true)
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                }
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    if let detail {
                        Label(detail, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help("\(detail), plus any linked to the tax year itself")
                    }
                    Label(fileName, systemImage: "doc")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Saved as “\(fileName)”")
                }
                Spacer(minLength: 0)
                Button(button, action: action)
                    .disabled(!isEnabled)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
