// App/Property/PropertyView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// One property's page (spec 2026-10-16 §1): Overview, Tenancies, Money, Calendar, Checks and
/// Profile tabs over `PropertyViewModel`. The period picker (calendar year, UK tax year or a
/// custom range) drives Overview, Money and Checks.
struct PropertyView: View {
    @ObservedObject var viewModel: PropertyViewModel
    /// Shows a transaction: Search, on its day and account, with its row selected.
    let openTransaction: (Transaction) -> Void
    /// Missing evidence, narrowed to this property's rules.
    let openMissingEvidence: (Int64, String) -> Void
    /// Shows a library document selected on the Documents screen.
    let showDocument: (Int64) -> Void
    @State private var editingProperty: PropertyDraft?

    var body: some View {
        // Every side panel (a chart month, a statement, a receipt) docks beside the page, which
        // narrows to make room — its tables give way — so the panel never covers it.
        PropertyPanelDock(isOpen: viewModel.sidePanel != nil && viewModel.property != nil) {
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                if viewModel.property == nil {
                    if viewModel.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { emptyState }
                } else {
                    header
                    PropertyBanners(viewModel: viewModel)
                    ScrollViewReader { proxy in
                        ScrollView {
                            content
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.bottom, ScreenMetrics.padding)
                        }
                        // The page narrows when a panel opens (taller tiles, compact tables): the
                        // open row brings itself back into view once it has settled (`DataTable`).
                        .environment(\.selectedRowScroller, proxy)
                    }
                }
            }
            .padding([.horizontal, .top], ScreenMetrics.padding)
        } panel: {
            if let panel = viewModel.sidePanel { sidePanel(panel) }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .filedYearGate(viewModel.filedYearGate)
        .screenToolbar {
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
        EmptyState(systemImage: "house", title: "No property yet",
                   message: "Add a property to follow its tenancies, rent receipts, costs, mortgage and obligations.") {
            Button("Add property…") { editingProperty = PropertyDraft(nil) }
                .buttonStyle(.borderedProminent).prominentTint()
        }
        .fillingScreen()
    }

    /// The sections on the left; the period the figures cover on the right, on the tabs that
    /// use it (Overview, Money, Checks).
    private var header: some View {
        HStack(spacing: 12) {
            ScreenTabs("Property section", selection: $viewModel.tab, tabs: PropertyViewModel.Tab.allCases, label: \.rawValue)
                .equatable()
                .layoutPriority(1)
            Spacer(minLength: 8)
            if [.overview, .money, .checks].contains(viewModel.tab) {
                PropertyPeriodPicker(viewModel: viewModel)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private func sidePanel(_ panel: PropertyViewModel.SidePanel) -> some View {
        switch panel {
        case let .month(interval):
            PropertyMonthPanel(viewModel: viewModel, interval: interval, openTransaction: openTransaction)
                .id(interval)
        case let .rechargeStatement(id, tenancyId):
            RechargeStatementPanel(viewModel: viewModel, statementId: id, tenancyId: tenancyId, openTransaction: openTransaction)
                .id(id)
        case let .rechargeMonth(month, tenancyId):
            RechargeMonthPanel(viewModel: viewModel, month: month, tenancyId: tenancyId, openTransaction: openTransaction)
                .id(month)
        case let .receipt(id, tenancyId):
            // Kept (not rebuilt) from one receipt to the next: clicking down the table only
            // changes what it shows.
            RentReceiptPanel(viewModel: viewModel, receiptId: id, tenancyId: tenancyId, openTransaction: openTransaction,
                             showDocument: showDocument)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .overview: PropertyOverviewTab(viewModel: viewModel)
        case .tenancies: PropertyTenanciesTab(viewModel: viewModel, openTransaction: openTransaction, showDocument: showDocument)
        case .recharges: PropertyRechargesTab(viewModel: viewModel)
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

    var body: some View {
        if let error = viewModel.errorMessage {
            InlineBanner(.error, error) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            InlineBanner(.info, info) { viewModel.infoMessage = nil }
        }
    }
}

/// Label/value rows for a record's facts: labels trailing in secondary, values leading (the
/// `SheetForm` look, read-only), so values line up.
struct PropertyFacts<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
            content
        }
    }
}

/// One row of `PropertyFacts`.
struct PropertyFact<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The transactions behind a figure: date, description over account and category, documents,
/// amount, and Show as an icon.
struct PropertyDrillDownSheet: View {
    let title: String
    let rows: [EvidenceTransactionInfo]
    let openTransaction: (Transaction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: title, subtitle: "\(rows.count) transaction\(rows.count == 1 ? "" : "s")", width: SheetMetrics.listWidth,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            if rows.isEmpty {
                SheetEmptyState(systemImage: "list.bullet.rectangle", title: "No transactions", message: "None in this period.", minHeight: 130)
            } else {
                List(rows) { row in
                    HStack(spacing: 8) {
                        DateText(date: row.transaction.date)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.transaction.rawDescription).lineLimit(1)
                            Text([row.accountName, row.categoryName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        TransactionDocumentBadge(transactionId: row.transaction.id)
                        // A minimum width, so the amounts line up from row to row.
                        MoneyText(minorUnits: row.transaction.amountMinorUnits, currency: row.currency)
                            .frame(minWidth: 96, alignment: .trailing)
                        Button {
                            dismiss()
                            openTransaction(row.transaction)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Show the transaction: Search, on its day and account, with it selected")
                        .accessibilityLabel("Show \(row.transaction.rawDescription)")
                    }
                }
                .wrapProbeClips()
                .frame(minHeight: 320)
                .sheetListFrame()
            }
        }
    }
}
