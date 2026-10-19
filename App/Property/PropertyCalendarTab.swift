// App/Property/PropertyCalendarTab.swift
import SwiftUI
import BudgetCore

/// The Calendar tab (spec 2026-10-16 §1 "Obligations calendar", UI polish §4.2): the next
/// twelve months as a grid of month panels — each a small table (day, what, expected amount;
/// "≈" for an estimate from the history, a pill for a deadline without an amount) with the
/// month's expected total.
struct PropertyCalendarTab: View {
    @ObservedObject var viewModel: PropertyViewModel

    private static let monthTitle = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()

    var body: some View {
        let months = PropertyCalendarMonth.months(viewModel.snapshot.obligations)
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if months.isEmpty {
                Panel("The next twelve months") {
                    Text("Nothing due. Link the property's accounts and category groups in Profile so recurring costs and the mortgage show here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Text("The next twelve months").font(.headline)
                    Spacer(minLength: 8)
                    Text("≈ an estimate from the property's history").font(.caption).foregroundStyle(.secondary)
                }
                PanelGrid(minColumnWidth: 380, maxColumns: 3) {
                    ForEach(months) { month in
                        Panel(month.start.formatted(Self.monthTitle), fillsHeight: true) {
                            monthTotal(month)
                        } content: {
                            DataTable(columns: PropertyObligationColumns.columns, rows: month.obligations, showsHeader: false)
                        }
                    }
                }
            }
        }
    }

    /// The month's expected amounts added up, per currency ("≈" when any is an estimate).
    @ViewBuilder
    private func monthTotal(_ month: PropertyCalendarMonth) -> some View {
        let totals = month.totals
        if !totals.isEmpty {
            HStack(spacing: 8) {
                ForEach(totals, id: \.currency) { total in
                    PropertyExpectedAmount(minorUnits: total.minorUnits, currency: total.currency, isEstimate: month.hasEstimates,
                                           font: .callout.monospacedDigit().weight(.semibold))
                }
            }
            .help("Expected in the month")
        }
    }
}

/// One month of the calendar.
struct PropertyCalendarMonth: Identifiable {
    let start: Date
    let obligations: [PropertyObligation]
    var id: Date { start }

    /// The obligations by month, in date order.
    static func months(_ obligations: [PropertyObligation]) -> [PropertyCalendarMonth] {
        let grouped = Dictionary(grouping: obligations) { obligation -> Date in
            let (year, month) = MonthRange.components(of: obligation.date)
            return MonthRange.of(year: year, month: month).start
        }
        return grouped.keys.sorted().map { PropertyCalendarMonth(start: $0, obligations: grouped[$0]!.sorted { $0.date < $1.date }) }
    }

    var hasEstimates: Bool { obligations.contains { $0.isEstimate && $0.expectedMinorUnits != nil } }

    /// What's expected, added up by currency.
    var totals: [(currency: Currency, minorUnits: Int)] {
        var sums: [Currency: Int] = [:]
        for obligation in obligations {
            guard let amount = obligation.expectedMinorUnits, let currency = obligation.currency else { continue }
            sums[currency, default: 0] += amount
        }
        return sums.keys.sorted { $0.rawValue < $1.rawValue }.map { (currency: $0, minorUnits: sums[$0]!) }
    }
}

/// The columns an obligation shows in (Calendar's months, Overview's Coming up): the day, the
/// kind's glyph with the title, and the expected amount — or, for a deadline, a pill.
enum PropertyObligationColumns {
    static var columns: [DataTableColumn<PropertyObligation>] {
        [
            .date("Date") { $0.date },
            DataTableColumn("What", width: .fill(min: 110), accessibilityValue: { $0.title }) { obligation, _ in
                HStack(spacing: 6) {
                    Image(systemName: PropertyFormat.obligation(obligation.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(PropertyFormat.shortTitle(obligation)).lineLimit(1).truncationMode(.tail)
                }
                .help(obligation.title)
            },
            DataTableColumn("Expected", alignment: .trailing, width: .min(84), accessibilityValue: accessibilityAmount) { obligation, _ in
                if let amount = obligation.expectedMinorUnits, let currency = obligation.currency {
                    PropertyExpectedAmount(minorUnits: amount, currency: currency, isEstimate: obligation.isEstimate)
                } else if let pill = PropertyFormat.obligationPill(obligation.kind) {
                    pill
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        ]
    }

    private static func accessibilityAmount(_ obligation: PropertyObligation) -> String? {
        if let amount = obligation.expectedMinorUnits, let currency = obligation.currency {
            return (obligation.isEstimate ? "about " : "") + Money.format(amount, currency: currency)
        }
        return PropertyFormat.obligationPill(obligation.kind)?.title
    }
}

/// An expected amount: "≈" before it when it's an estimate from the history. Neutral: every
/// row is a cost (spec §1.4).
struct PropertyExpectedAmount: View {
    let minorUnits: Int
    let currency: Currency
    let isEstimate: Bool
    var font: Font = .body.monospacedDigit()

    var body: some View {
        HStack(spacing: 3) {
            if isEstimate {
                Text("≈").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            MoneyText(minorUnits: minorUnits, currency: currency, font: font, role: .neutral)
        }
        .font(font)
        .fixedSize()
        .help(isEstimate ? "An estimate from the property's history" : "Expected")
    }
}

extension PropertyFormat {
    /// An obligation's title for a table row: the Self Assessment deadlines put shortly (their
    /// pill says they're tax deadlines; the full title is the row's tooltip).
    static func shortTitle(_ obligation: PropertyObligation) -> String {
        switch obligation.kind {
        case .ukSelfAssessmentJanuary:
            // The return due on 31 January of year Y is for the tax year 6 April Y−2 – 5 April Y−1
            // (it ended the April before the deadline).
            let year = MonthRange.components(of: obligation.date).year
            return "UK SA \(UKTaxYear(startYear: year - 2).label) return"
        case .ukSelfAssessmentJuly:
            return "UK SA 2nd payment"
        default:
            return obligation.title
        }
    }

    /// What an obligation without an amount is, as a pill: a tax return's deadline, a
    /// mortgage rate review, a renewal.
    static func obligationPill(_ kind: PropertyObligationKind) -> StatusPill? {
        switch kind {
        case .ptIncomeTaxReturn, .ukSelfAssessmentJanuary, .ukSelfAssessmentJuly: return StatusPill("Tax deadline", tone: .accent)
        case .mortgageRateReset: return StatusPill("Rate revision")
        case .insuranceRenewal: return StatusPill("Renewal")
        case .imiInstalment, .mortgageInstalment, .recurringCost: return nil
        }
    }
}
