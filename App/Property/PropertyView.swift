// App/Property/PropertyView.swift
import SwiftUI
import Charts
import BudgetCore
import struct BudgetCore.Transaction

/// One property's page (spec 2026-10-16 §1): Overview, Tenancies, Money, Calendar, Checks and
/// Profile tabs over `PropertyViewModel`. The period picker (calendar year, UK tax year or a
/// custom range) drives Overview, Money and Checks.
struct PropertyView: View {
    @ObservedObject var viewModel: PropertyViewModel
    /// Shows a transaction where it lives (its Budget cell, or Uncategorized / Search).
    let openTransaction: (Transaction) -> Void
    /// Missing evidence, narrowed to this property's rules.
    let openMissingEvidence: (Int64, String) -> Void
    @Environment(\.theme) private var theme

    @State private var editingProperty: PropertyDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.property == nil {
                if viewModel.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { emptyState }
            } else {
                header
                PropertyBanners(viewModel: viewModel)
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 12)
                }
            }
        }
        .padding(12)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editingProperty = PropertyDraft(nil) } label: {
                    Label("New property…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add another property")
                .accessibilityLabel("New property")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: $editingProperty) { draft in
            PropertyFormSheet(viewModel: viewModel, draft: draft)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "house").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No property yet").font(.title3.weight(.semibold))
            Text("Add a property to follow its tenancies, rent receipts, costs, mortgage and obligations.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add property…") { editingProperty = PropertyDraft(nil) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Tab", selection: $viewModel.tab) {
                ForEach(PropertyViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Property section")
            if [.overview, .money, .checks].contains(viewModel.tab) {
                PropertyPeriodPicker(viewModel: viewModel)
            }
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .overview: PropertyOverviewTab(viewModel: viewModel)
        case .tenancies: PropertyTenanciesTab(viewModel: viewModel, openTransaction: openTransaction)
        case .money: PropertyMoneyTab(viewModel: viewModel, openTransaction: openTransaction)
        case .calendar: PropertyCalendarTab(viewModel: viewModel)
        case .checks: PropertyChecksTab(viewModel: viewModel, openTransaction: openTransaction, openMissingEvidence: openMissingEvidence)
        case .profile: PropertyProfileTab(viewModel: viewModel)
        }
    }
}

/// The period the money figures cover.
struct PropertyPeriodPicker: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Picker("Period", selection: $viewModel.periodChoice) {
                ForEach(viewModel.years, id: \.self) { year in
                    Text(String(year)).tag(PropertyViewModel.PeriodChoice.calendarYear(year))
                }
                Divider()
                ForEach(viewModel.years, id: \.self) { year in
                    Text("Tax year \(UKTaxYear(startYear: year).label)").tag(PropertyViewModel.PeriodChoice.taxYear(year))
                }
                Divider()
                Text("Custom range").tag(PropertyViewModel.PeriodChoice.custom)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Period")
            if viewModel.periodChoice == .custom {
                DatePicker("From", selection: utcDay($viewModel.customFirstDay), displayedComponents: .date).fixedSize()
                DatePicker("To", selection: utcDay($viewModel.customLastDay), displayedComponents: .date).fixedSize()
                if viewModel.period == nil {
                    Text("The range ends before it starts.").font(.callout).foregroundStyle(theme.expense)
                }
            }
        }
    }
}

/// A DatePicker's local midnight ↔ the stored UTC midnight of the same day.
func utcDay(_ binding: Binding<Date>) -> Binding<Date> {
    Binding(get: { PayCalendar.localDay(sameDayAs: binding.wrappedValue, in: .current) },
            set: { binding.wrappedValue = PayCalendar.utcDay(sameDayAs: $0, in: .current) })
}

/// An optional day for a DatePicker with an on/off toggle.
func utcOptionalDay(_ binding: Binding<Date?>, default fallback: Date) -> Binding<Date> {
    Binding(get: { PayCalendar.localDay(sameDayAs: binding.wrappedValue ?? fallback, in: .current) },
            set: { binding.wrappedValue = PayCalendar.utcDay(sameDayAs: $0, in: .current) })
}

/// Error and info lines under the header.
struct PropertyBanners: View {
    @ObservedObject var viewModel: PropertyViewModel
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

/// A titled block of the page.
struct PropertySection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
            }
            content
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface))
    }
}

/// An amount that never wraps.
struct PropertyMoney: View {
    let minorUnits: Int
    let currency: Currency
    var font: Font = .body.monospacedDigit()
    var neutral = false
    @Environment(\.theme) private var theme

    var body: some View {
        MoneyText(minorUnits: minorUnits, currency: currency, font: font, tint: neutral ? theme.neutralMoney : nil)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A key figure: title, the amount in the property's currency, and GBP beneath.
struct PropertyFigureTile: View {
    let title: String
    let amount: PropertyAmount
    let currency: Currency
    var neutral = false
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            PropertyMoney(minorUnits: amount.native, currency: currency, font: .title3.monospacedDigit().weight(.semibold), neutral: neutral)
            if currency != .gbp {
                PropertyMoney(minorUnits: amount.gbp, currency: .gbp, font: .caption.monospacedDigit(), neutral: true)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(minWidth: 130, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overview

struct PropertyOverviewTab: View {
    @ObservedObject var viewModel: PropertyViewModel

    var body: some View {
        let snapshot = viewModel.snapshot
        VStack(alignment: .leading, spacing: 12) {
            if let summary = snapshot.summary {
                PropertySection("Key figures · \(summary.period.label)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                        PropertyFigureTile(title: "Rent per receipts", amount: summary.totals.rentPerReceipts, currency: summary.currency)
                        PropertyFigureTile(title: "Rent received", amount: summary.totals.rentReceived, currency: summary.currency)
                        PropertyFigureTile(title: "Costs", amount: -summary.totals.costs, currency: summary.currency)
                        PropertyFigureTile(title: "Net cash flow", amount: summary.totals.netCashFlow, currency: summary.currency)
                        PropertyFigureTile(title: "Outstanding loan", amount: summary.outstandingLoan, currency: summary.currency, neutral: true)
                        PropertyFigureTile(title: "Deposit held", amount: summary.depositHeld, currency: summary.currency, neutral: true,
                                           detail: depositDetail)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gross / net yield").font(.caption).foregroundStyle(.secondary)
                            Text("\(PropertyFormat.yield(summary.grossYield)) / \(PropertyFormat.yield(summary.netYield))")
                                .font(.title3.monospacedDigit().weight(.semibold)).lineLimit(1).fixedSize()
                            Text(summary.purchasePrice == nil ? "Set a purchase price in Profile" : "On the purchase price, annualised")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                PropertySection("By month") {
                    PropertyMonthlyChart(summary: summary)
                        .frame(height: 200)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                PropertySection("Tenancy") {
                    if let tenancy = viewModel.currentTenancy {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tenancy.referenceLabel).fontWeight(.semibold)
                            if let tenant = tenancy.tenantName { Text(tenant).foregroundStyle(.secondary) }
                            Text(PropertyFormat.period(tenancy.startDate, tenancy.endDate)).foregroundStyle(.secondary)
                            if let rent = viewModel.rentInForce(tenancy) {
                                HStack(spacing: 4) {
                                    Text("Rent")
                                    PropertyMoney(minorUnits: rent.monthlyAmountMinorUnits, currency: viewModel.currency, neutral: true)
                                    Text("a month")
                                }
                            }
                        }
                    } else {
                        Text("No tenancy yet.").foregroundStyle(.secondary)
                    }
                }
                PropertySection("Coming up") {
                    let upcoming = Array(snapshot.obligations.prefix(6))
                    if upcoming.isEmpty {
                        Text("Nothing in the next twelve months.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(upcoming) { PropertyObligationRow(obligation: $0) }
                        }
                    }
                }
                PropertySection("Checks") {
                    let count = snapshot.checks?.issueCount ?? 0
                    VStack(alignment: .leading, spacing: 6) {
                        Text(count == 0 ? "Nothing to look at." : "\(count) thing\(count == 1 ? "" : "s") to look at.")
                        Button("Open Checks") { viewModel.tab = .checks }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var depositDetail: String? {
        guard let deposit = viewModel.snapshot.checks?.deposit else { return nil }
        switch deposit.matchedInterpretation {
        case .depositAndAdvanceRent: return "Matches deposit + advance rent"
        case .depositOnly: return "Matches the deposit alone"
        case nil: return "Off by \(Money.format(deposit.differenceMinorUnits, currency: viewModel.currency))"
        }
    }
}

/// Rent received and costs by month (bars), net cash flow (line).
struct PropertyMonthlyChart: View {
    let summary: PropertySummary
    @Environment(\.theme) private var theme

    private struct Point: Identifiable {
        let id = UUID()
        let month: Date
        let series: String
        let value: Double
    }

    private var points: [Point] {
        summary.months.flatMap { month -> [Point] in
            [Point(month: month.start, series: "Rent received", value: Double(month.figures.rentReceived.native) / 100),
             Point(month: month.start, series: "Costs", value: -Double(month.figures.costs.native) / 100)]
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Month", point.month, unit: .month), y: .value("Amount", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
            }
            ForEach(summary.months, id: \.start) { month in
                LineMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.figures.netCashFlow.native) / 100))
                    .foregroundStyle(by: .value("Series", "Net cash flow"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Rent received": theme.income, "Costs": theme.expense, "Net cash flow": theme.accent])
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow), centered: true) } }
        .accessibilityLabel("Rent received, costs and net cash flow by month")
    }
}

// MARK: - Calendar

struct PropertyObligationRow: View {
    let obligation: PropertyObligation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: PropertyFormat.obligation(obligation.kind)).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(DocumentFormat.day(obligation.date)).monospacedDigit().lineLimit(1).fixedSize()
            Text(obligation.title).lineLimit(1)
            Spacer(minLength: 8)
            if let amount = obligation.expectedMinorUnits, let currency = obligation.currency {
                PropertyMoney(minorUnits: amount, currency: currency, neutral: true)
            }
            if obligation.isEstimate {
                Text("estimate").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PropertyCalendarTab: View {
    @ObservedObject var viewModel: PropertyViewModel

    var body: some View {
        let byMonth = Dictionary(grouping: viewModel.snapshot.obligations) { MonthRange.components(of: $0.date).year * 12 + MonthRange.components(of: $0.date).month }
        PropertySection("The next twelve months") {
            if byMonth.isEmpty {
                Text("Nothing due. Link the property's accounts and category groups in Profile so recurring costs and the mortgage show here.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(byMonth.keys.sorted(), id: \.self) { key in
                        let items = byMonth[key]!
                        VStack(alignment: .leading, spacing: 6) {
                            Text(items[0].date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()))
                                .font(.subheadline.weight(.semibold))
                            ForEach(items) { PropertyObligationRow(obligation: $0) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Checks

struct PropertyChecksTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void
    let openMissingEvidence: (Int64, String) -> Void

    var body: some View {
        let checks = viewModel.snapshot.checks
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(checks.map { $0.issueCount == 0 ? "Nothing to look at." : "\($0.issueCount) thing\($0.issueCount == 1 ? "" : "s") to look at." } ?? "")
                Spacer()
                if let property = viewModel.property, let id = property.id {
                    if !viewModel.snapshot.hasEvidenceRules {
                        Button("Add evidence rules") { viewModel.seedEvidenceRules() }
                            .help("Ask for one PDF per rent receipt and one contract per tenancy in Missing evidence")
                    }
                    Button("Missing evidence for \(property.name)") { openMissingEvidence(id, property.name) }
                }
            }
            if let checks {
                PropertySection("Months without a receipt") {
                    if checks.monthsWithoutReceipt.isEmpty { none } else {
                        ForEach(checks.monthsWithoutReceipt, id: \.self) { item in
                            HStack {
                                Text(item.month.start.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()))
                                Text(tenancyName(item.tenancyId)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                PropertySection("Receipts without a matched credit") {
                    if checks.receiptsWithoutCredit.isEmpty { none } else {
                        ForEach(checks.receiptsWithoutCredit) { receipt in
                            HStack {
                                Text("Receipt \(receipt.receiptNumber)")
                                Text(PropertyFormat.period(receipt.periodStart, receipt.periodEnd)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                PropertyMoney(minorUnits: receipt.amountReceivedMinorUnits, currency: viewModel.currency, neutral: true)
                            }
                        }
                        Button("Match credits") { viewModel.matchCredits() }
                    }
                }
                PropertySection("Rent credits without a receipt") {
                    if checks.creditsWithoutReceipt.isEmpty { none } else {
                        ForEach(checks.creditsWithoutReceipt) { credit in
                            HStack {
                                Text(DocumentFormat.day(credit.date)).monospacedDigit().lineLimit(1).fixedSize()
                                Text(credit.rawDescription).lineLimit(1)
                                Spacer()
                                PropertyMoney(minorUnits: credit.amountMinorUnits, currency: viewModel.currency)
                                Button("Show") { openTransaction(credit) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                PropertySection("Deposit") {
                    if let deposit = checks.deposit {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Held on \(DocumentFormat.day(deposit.date)):")
                                PropertyMoney(minorUnits: deposit.heldMinorUnits, currency: viewModel.currency, neutral: true)
                            }
                            HStack(spacing: 4) {
                                Text("Deposit months:")
                                PropertyMoney(minorUnits: deposit.expectedDepositMinorUnits, currency: viewModel.currency, neutral: true)
                                Text("· with advance rent:")
                                PropertyMoney(minorUnits: deposit.expectedWithAdvanceMinorUnits, currency: viewModel.currency, neutral: true)
                            }
                            .foregroundStyle(.secondary)
                            switch deposit.matchedInterpretation {
                            case .depositAndAdvanceRent: Label("Matches the deposit plus advance rent", systemImage: "checkmark.circle")
                            case .depositOnly: Label("Matches the deposit alone", systemImage: "checkmark.circle")
                            case nil:
                                Label("Off by \(Money.format(deposit.differenceMinorUnits, currency: viewModel.currency))",
                                      systemImage: "exclamationmark.triangle")
                            }
                        }
                    } else {
                        Text("Link a deposit account in Profile (and set the tenancy's deposit months) to check it.").foregroundStyle(.secondary)
                    }
                }
                PropertySection("Recurring costs overdue") {
                    if checks.missingRecurringCosts.isEmpty { none } else {
                        ForEach(checks.missingRecurringCosts, id: \.pattern.key) { item in
                            HStack {
                                Text(item.pattern.title)
                                Text("expected around \(DocumentFormat.day(item.expectedDate))").foregroundStyle(.secondary)
                                Spacer()
                                PropertyMoney(minorUnits: item.pattern.lastAmountMinorUnits, currency: item.pattern.currency, neutral: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var none: some View { Text("None.").foregroundStyle(.secondary) }

    private func tenancyName(_ id: Int64) -> String {
        viewModel.snapshot.tenancies.first { $0.id == id }?.referenceLabel ?? ""
    }
}

/// The transactions behind a figure, each with Show.
struct PropertyDrillDownSheet: View {
    let title: String
    let rows: [EvidenceTransactionInfo]
    let openTransaction: (Transaction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: title, subtitle: "\(rows.count) transaction\(rows.count == 1 ? "" : "s")", width: 640,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            if rows.isEmpty {
                Text("None in this period.").foregroundStyle(.secondary)
            } else {
                List(rows) { row in
                    HStack(spacing: 8) {
                        Text(DocumentFormat.day(row.transaction.date)).monospacedDigit().lineLimit(1).fixedSize()
                        VStack(alignment: .leading) {
                            Text(row.transaction.rawDescription).lineLimit(1)
                            Text([row.accountName, row.categoryName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        TransactionDocumentBadge(transactionId: row.transaction.id)
                        PropertyMoney(minorUnits: row.transaction.amountMinorUnits, currency: row.currency)
                        Button("Show") {
                            dismiss()
                            openTransaction(row.transaction)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Show \(row.transaction.rawDescription)")
                    }
                }
                .frame(minHeight: 320)
            }
        }
    }
}
