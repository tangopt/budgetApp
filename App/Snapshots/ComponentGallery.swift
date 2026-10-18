// App/Snapshots/ComponentGallery.swift
#if SNAPSHOTS
import SwiftUI
import BudgetCore

/// The shared components (`App/DesignSystem`) on two pages of their own, filled from the demo
/// database, so a change to one is reviewed in every theme and appearance before a screen
/// uses it: `gallery-components` (panels, figures, banners, pills, money roles, controls,
/// dates, badges, tabs, `BalanceLineChart`) and `gallery-tables` (`DataTable`,
/// `MonthlyFlowChart`, `ProgressRing`, `BreakdownBars`, `WaterfallChart`). Snapshot builds only; not reachable
/// from the app.
@MainActor
enum ComponentGallery {
    static var routes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "gallery-components", title: "Component gallery: panels, figures, banners, pills, money, controls") { context in
                let model = await context.propertyModel()
                return AnyView(GalleryPage { GalleryComponents(model: model) })
            },
            SnapshotRoute(name: "gallery-tables", title: "Component gallery: data tables and the monthly flow chart") { context in
                let model = await context.propertyModel()
                return AnyView(GalleryPage { GalleryTables(model: model) })
            }
        ]
    }
}

/// A gallery page: the window's colour, screen padding, content from the top left.
private struct GalleryPage<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .padding(ScreenMetrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.windowFill)
    }
}

// MARK: - Components

private struct GalleryComponents: View {
    @ObservedObject var model: PropertyViewModel
    @State private var months = 2
    @State private var emptyQuery = ""
    @State private var query = "greenleaf"
    @State private var kind = "all"
    @State private var tab = TaxYearsViewModel.Tab.accounts

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    Panel("Panel", subtitle: "Title, caption subtitle and an accessory; padding 14, corner 12, stroked") {
                        PanelLink(title: "Property", action: {})
                    } content: {
                        Text("The stroke keeps a panel visible where its surface matches the window (Classic light).")
                            .foregroundStyle(.secondary)
                    }
                    if let summary = model.snapshot.summary {
                        Panel("FigureStrip · \(summary.period.label)") {
                            FigureStrip(figures(summary))
                        }
                    }
                    Panel("InlineBanner") {
                        VStack(alignment: .leading, spacing: 8) {
                            InlineBanner(.info, "Imported 12 receipts; 2 were already in.") {}
                            InlineBanner(.success, "Every 2025/26 receipt has its PDF.")
                            InlineBanner(.warning, action: { Button("Fetch rate") {} }) {
                                Text("No HMRC EUR rate for 2026/27 yet.")
                            }
                            InlineBanner(.error, "The statement couldn't be saved: September already has one.") {}
                        }
                    }
                    Panel("StatusPill") {
                        HStack(spacing: 8) {
                            StatusPill("Draft")
                            StatusPill("Sent", tone: .accent)
                            StatusPill("Paid", tone: .positive, systemImage: "checkmark")
                            StatusPill("Not matched", tone: .warning)
                            StatusPill("€100.00 short", tone: .negative, systemImage: "exclamationmark.triangle")
                        }
                    }
                    Panel("EmptyState", subtitle: "A screen's or a panel's nothing yet: icon, line, sentence and what to do") {
                        EmptyState(systemImage: "person.2", title: "No tenancies yet",
                                   message: "Import the portal's receipts export to create them, or add one by hand.") {
                            Button("New tenancy…") {}
                            Button("Import receipts…") {}.buttonStyle(.borderedProminent).prominentTint()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    Panel("MoneyText roles", subtitle: "signed: coloured by sign · cost: a magnitude shown negative, in red · neutral: as given") {
                        moneyRoles
                    }
                    Panel("SearchField · FilterChip") {
                        VStack(alignment: .leading, spacing: 8) {
                            SearchField("Search descriptions, notes, categories or an amount", text: $emptyQuery)
                            SearchField("Search", text: $query)
                            HStack(spacing: 8) {
                                FilterChip("All time", isActive: false) { Text("Date") }
                                FilterChip("This year", isActive: true) { Text("Date") }
                                FilterPickerChip("All kinds", name: "Kind", all: "all", selection: $kind,
                                                 options: [("receipt", "Rent receipt"), ("notice", "Tax notice")])
                                FilterPickerChip("All years", name: "Year", all: "all", selection: .constant("2025"),
                                                 options: [("2025", "2025"), ("2026", "2026")])
                            }
                        }
                    }
                    Panel("ValueStepper · DateText · DocumentCountBadge") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Deposit").foregroundStyle(.secondary)
                                ValueStepper("Deposit", value: $months, in: 0...24, text: ValueStepper.months)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(Array(model.snapshot.obligations.prefix(4).enumerated()), id: \.offset) { index, obligation in
                                    GridRow {
                                        DateText(date: obligation.date)
                                        DocumentCountBadge(count: [0, 1, 3, 0][index])
                                        Text(obligation.title).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    Panel("BalanceLineChart", subtitle: "A balance over time (the loan); the scale fitted to the values; hover readout") {
                        BalanceLineChart(points: model.snapshot.loanHistory.map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits) },
                                         currency: model.currency, title: "Outstanding loan", includesZero: false, height: 120)
                    }
                }
            }
            Panel("ScreenTabs", subtitle: "Every section when they fit; otherwise the first ones and a More menu (never wider than the page)") {
                VStack(alignment: .leading, spacing: 8) {
                    ScreenTabs("Section", selection: $tab, tabs: TaxYearsViewModel.Tab.allCases, label: \.rawValue)
                    ScreenTabs("Section", selection: $tab, tabs: TaxYearsViewModel.Tab.allCases, label: \.rawValue)
                        .frame(width: 520, alignment: .leading)
                    ScreenTabs("Section", selection: .constant(TaxYearsViewModel.Tab.export), tabs: TaxYearsViewModel.Tab.allCases,
                               label: \.rawValue)
                        .frame(width: 520, alignment: .leading)
                }
            }
        }
    }

    private func figures(_ summary: PropertySummary) -> [FigureTile] {
        let t = summary.totals, currency = summary.currency
        func gbp(_ amount: PropertyAmount) -> Int? { currency == .gbp ? nil : amount.gbp }
        return [
            FigureTile(title: "Rent per receipts", value: .money(t.rentPerReceipts.native, currency, .neutral), gbp: gbp(t.rentPerReceipts)),
            FigureTile(title: "Rent received", value: .money(t.rentReceived.native, currency, .signed), gbp: gbp(t.rentReceived)),
            FigureTile(title: "Costs", value: .money(t.costs.native, currency, .cost), gbp: gbp(t.costs)),
            FigureTile(title: "Net cash flow", value: .money(t.netCashFlow.native, currency, .signed), gbp: gbp(t.netCashFlow)),
            FigureTile(title: "Deposit held", value: .money(summary.depositHeld.native, currency, .neutral), gbp: gbp(summary.depositHeld),
                       caption: "€100.00 short", captionIsWarning: true),
            FigureTile(title: "Gross / net yield", value: .text("\(PropertyFormat.yield(summary.grossYield)) / \(PropertyFormat.yield(summary.netYield))"),
                       caption: "On the purchase price")
        ]
    }

    private var moneyRoles: some View {
        let examples: [(String, String, Int, MoneyRole)] = [
            (".signed", "a credit", 123_456, .signed),
            (".signed", "a debit", -123_456, .signed),
            (".cost", "a cost (given positive)", 123_456, .cost),
            (".cost", "a refund (given negative)", -4_500, .cost),
            (".neutral", "a balance, a box value, an all-costs breakdown", 123_456, .neutral)
        ]
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                GridRow {
                    Text(example.0).font(.body.monospaced())
                    Text(example.1).foregroundStyle(.secondary).lineLimit(1)
                    MoneyText(minorUnits: example.2, currency: .eur, role: example.3).gridColumnAlignment(.trailing)
                    MoneyText(minorUnits: example.2, currency: .gbp, font: .caption.monospacedDigit(), role: example.3, tint: .secondary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }
}

// MARK: - Tables

/// A rent receipt as the gallery's table shows it (or a year's total).
private struct GalleryReceipt: Identifiable {
    let id: String
    let number: String
    let period: String
    let date: Date?
    let rent: Int
    let withheld: Int
    let received: Int
    var status: Status?
    var documents = 0

    enum Status { case paid, notMatched, cancelled }
}

/// A figure of the property's period (or a group's total).
private struct GalleryFigure: Identifiable {
    let id: String
    let title: String
    var detail: String?
    let amount: PropertyAmount
    let role: MoneyRole
    var drillsDown = false
}

private struct GalleryTables: View {
    @ObservedObject var model: PropertyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            Panel("DataTable", subtitle: "Rent receipts grouped by year, each with a total; dates, neutral amounts, status pills, documents, row actions") {
                DataTable(columns: receiptColumns, sections: receiptSections)
            }
            if let summary = model.snapshot.summary {
                HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                    Panel("DataTable · figures", subtitle: "One role per row: rent signed, costs as costs, balances neutral; no zebra") {
                        DataTable(columns: figureColumns(summary.currency), sections: figureSections(summary), zebra: false)
                    }
                    VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                        Panel("MonthlyFlowChart · \(summary.period.label)", subtitle: "In above the axis, out below, net as a line; today rule; hover readout") {
                            MonthlyFlowChart(months: summary.months.map { month in
                                                 FlowMonth(start: month.start, inflowMinorUnits: month.figures.rentReceived.native,
                                                             outflowMinorUnits: month.figures.costs.native,
                                                             netMinorUnits: month.figures.netCashFlow.native)
                                             },
                                             currency: summary.currency, inflowLabel: "Rent received", outflowLabel: "Costs",
                                             netLabel: "Net cash flow", today: AppClock.now, height: 180)
                        }
                        Panel("ProgressRing · BreakdownBars", subtitle: "Done of total (income once complete); parts of a whole in money or counts") {
                            HStack(alignment: .center, spacing: 16) {
                                ProgressRing(done: 73, total: 79, size: 64)
                                ProgressRing(done: 21, total: 24, size: 40, caption: "Bank app")
                                ProgressRing(done: 3, total: 3, size: 40, caption: "Employer")
                                HStack(spacing: 6) {
                                    ProgressRing(done: 2, total: 3, size: 14, lineWidth: 3)
                                    Text("2 of 3").font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                                BreakdownBars(items: [BreakdownItem("Utilities", minorUnits: summary.totals.utilities.native),
                                                      BreakdownItem("Interest", minorUnits: summary.totals.mortgageInterest.native),
                                                      BreakdownItem("Capital", minorUnits: summary.totals.mortgageCapital.native)],
                                              currency: summary.currency, showsShare: false)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Panel("WaterfallChart · \(summary.period.label)",
                      subtitle: "A figure built up: levels from zero in the accent, rises and falls floating from the running level, dashed connectors; hover readout") {
                    let t = summary.totals
                    WaterfallChart(steps: [
                        WaterfallStep(label: "Rent received", kind: .start, minorUnits: t.rentReceived.native),
                        WaterfallStep(label: "Utilities", kind: .change, minorUnits: -t.utilities.native),
                        WaterfallStep(label: "Interest", kind: .change, minorUnits: -t.mortgageInterest.native),
                        WaterfallStep(label: "Before capital", kind: .total),
                        WaterfallStep(label: "Capital", kind: .change, minorUnits: -t.mortgageCapital.native),
                        WaterfallStep(label: "Left over", kind: .total)
                    ], currency: summary.currency, riseLabel: "In", fallLabel: "Out", totalLabel: "Level", height: 200)
                }
            }
        }
    }

    // MARK: Receipts

    private var receiptColumns: [DataTableColumn<GalleryReceipt>] {
        let currency = model.currency
        return [
            .text("No.", width: .fit, { $0.number }),
            .text("Rent period", width: .fill(min: 180), { $0.period }),
            .date("Received on") { $0.date },
            .money("Rent", role: .neutral, currency: { _ in currency }) { $0.rent },
            .money("Withheld", role: .neutral, currency: { _ in currency }) { $0.withheld },
            .money("Received", role: .neutral, currency: { _ in currency }) { $0.received },
            .status("Status") { row in
                switch row.status {
                case .paid: return StatusPill("Paid", tone: .positive)
                case .notMatched: return StatusPill("Not matched", tone: .warning)
                case .cancelled: return StatusPill("Cancelled")
                case nil: return nil
                }
            },
            .documents { $0.documents },
            .actions { _ in
                [DataTableAction("Show transaction", systemImage: "arrow.right.circle", inline: true) {},
                 DataTableAction("Add PDF…", systemImage: "paperclip") {},
                 DataTableAction("Documents…", systemImage: "doc.on.doc") {}]
            }
        ]
    }

    private var receiptSections: [DataTableSection<GalleryReceipt>] {
        guard let tenancy = model.snapshot.tenancies.first(where: { $0.referenceLabel == "Tenancy 2" }) ?? model.snapshot.tenancies.last,
              let rows = model.snapshot.receipts[tenancy.id!] else { return [] }
        // The latest three receipts of each of the last two years.
        let byYear = Dictionary(grouping: rows) { MonthRange.components(of: $0.receipt.periodStart).year }
        return byYear.keys.sorted(by: >).prefix(2).map { year in
            let latest = byYear[year]!.sorted { $0.receipt.periodStart > $1.receipt.periodStart }.prefix(3)
            let receipts = latest.map { row in
                GalleryReceipt(id: "\(row.id)", number: row.receipt.receiptNumber,
                               period: PropertyFormat.period(row.receipt.periodStart, row.receipt.periodEnd),
                               date: row.receipt.receiptDate, rent: row.receipt.amountMinorUnits,
                               withheld: row.receipt.withholdingMinorUnits, received: row.receipt.amountReceivedMinorUnits,
                               status: row.receipt.status == .cancelled ? .cancelled : (row.isPaid ? .paid : .notMatched),
                               documents: row.documentCount)
            }
            let total = GalleryReceipt(id: "total-\(year)", number: "Total \(year)", period: "", date: nil,
                                       rent: receipts.reduce(0) { $0 + $1.rent }, withheld: receipts.reduce(0) { $0 + $1.withheld },
                                       received: receipts.reduce(0) { $0 + $1.received })
            return DataTableSection(String(year), rows: receipts, total: total)
        }
    }

    // MARK: Figures

    private func figureColumns(_ currency: Currency) -> [DataTableColumn<GalleryFigure>] {
        [
            .text("", width: .fill(min: 200), { $0.title }, detail: { $0.detail }),
            .money(currency.rawValue.uppercased(), role: { $0.role }, currency: { _ in currency }) { $0.amount.native },
            .money("GBP", role: { $0.role }, currency: { _ in .gbp }) { $0.amount.gbp },
            .actions { row in
                row.drillsDown ? [DataTableAction("Transactions", systemImage: "list.bullet.rectangle", inline: true) {}] : []
            }
        ]
    }

    private func figureSections(_ summary: PropertySummary) -> [DataTableSection<GalleryFigure>] {
        let t = summary.totals
        let outgoings = [t.utilities, t.mortgageInterest, t.mortgageCapital]
        let outgoingsTotal = PropertyAmount(native: outgoings.reduce(0) { $0 + $1.native }, gbp: outgoings.reduce(0) { $0 + $1.gbp })
        return [
            DataTableSection("Rent", rows: [
                GalleryFigure(id: "per-receipts", title: "Rent per receipts", detail: "The receipts' rent over their periods",
                              amount: t.rentPerReceipts, role: .neutral),
                GalleryFigure(id: "received", title: "Rent received", amount: t.rentReceived, role: .signed, drillsDown: true)
            ]),
            DataTableSection("Outgoings", rows: [
                GalleryFigure(id: "utilities", title: "Utilities paid", amount: t.utilities, role: .cost, drillsDown: true),
                GalleryFigure(id: "interest", title: "Mortgage interest", amount: t.mortgageInterest, role: .cost, drillsDown: true),
                GalleryFigure(id: "capital", title: "Mortgage capital repaid", amount: t.mortgageCapital, role: .cost)
            ], total: GalleryFigure(id: "outgoings", title: "Total", amount: outgoingsTotal, role: .cost)),
            DataTableSection("Cash flow", rows: [
                GalleryFigure(id: "net", title: "Net cash flow", detail: "Income − costs − capital repaid", amount: t.netCashFlow, role: .signed)
            ]),
            DataTableSection("Balances", rows: [
                GalleryFigure(id: "loan", title: "Outstanding loan", amount: summary.outstandingLoan, role: .neutral),
                GalleryFigure(id: "deposit", title: "Deposit held", amount: summary.depositHeld, role: .neutral)
            ])
        ]
    }
}
#endif
