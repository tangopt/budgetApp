import SwiftUI
import BudgetCore

/// One thing coming up, from any source (a planned bill, a property obligation, a calendar item), as the one
/// `UpcomingList` draws it (design review D1).
struct UpcomingEntry: Identifiable, Equatable {
    enum Figure: Equatable {
        /// A cost still to come, a positive magnitude (`MoneyRole.due`).
        case due(minorUnits: Int, currency: Currency)
        /// An expected amount, with "≈" when it is an estimate.
        case expected(minorUnits: Int, currency: Currency, isEstimate: Bool)
        /// "Amount not known" and the like.
        case words(String)
        case none
    }

    let id: String
    let title: String
    /// The line under the title: the day and where it comes from.
    let caption: String
    let symbol: String?
    let figure: Figure
    /// A status pill (the calendar's kind), if the source has one.
    let pill: (text: String, status: StatusPill.Status)?

    init(id: String, title: String, caption: String, symbol: String? = nil, figure: Figure,
         pill: (text: String, status: StatusPill.Status)? = nil) {
        self.id = id
        self.title = title
        self.caption = caption
        self.symbol = symbol
        self.figure = figure
        self.pill = pill
    }

    static func == (lhs: UpcomingEntry, rhs: UpcomingEntry) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.caption == rhs.caption && lhs.symbol == rhs.symbol
            && lhs.figure == rhs.figure && lhs.pill?.text == rhs.pill?.text && lhs.pill?.status == rhs.pill?.status
    }

    /// Home's upcoming bill or property obligation.
    init(_ item: HomeSummary.UpcomingItem) {
        self.init(id: item.id, title: item.title, caption: HomeCopy.upcomingSource(item), figure: item.amountMinorUnits.map {
            Figure.due(minorUnits: $0, currency: item.currency)
        } ?? .words("Amount not known"))
    }

    /// A property obligation on the Property tab's Coming up.
    init(_ obligation: PropertyObligation, currency: Currency) {
        self.init(id: obligation.id, title: obligation.title, caption: PropertyCopy.comingUpCaption(obligation),
                  figure: obligation.expectedMinorUnits.map { Figure.due(minorUnits: $0, currency: obligation.currency ?? currency) }
                      ?? .words(PropertyCopy.amountNotKnown))
    }
}

/// The one upcoming list (design review D1): Home's Upcoming, the Property tab's Coming up and the Calendar's agenda all
/// draw their entries here, as `ListRow`s on the card, hairlines between them (none in Flat). With `select` a row
/// can be chosen (the iPad's Calendar opens a panel); `selectedId` marks the chosen one.
struct UpcomingList: View {
    let entries: [UpcomingEntry]
    let emptyText: String
    var selectedId: String?
    var select: ((String) -> Void)?

    var body: some View {
        if entries.isEmpty {
            Text(emptyText.figuresUnbroken)
                .mangoFont(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { MangoDivider() }
            row(entry)
        }
    }

    private func row(_ entry: UpcomingEntry) -> some View {
        ListRow(entry.title, detail: entry.caption, isSelected: entry.id == selectedId, pill: entry.pill,
                select: select.map { choose in { choose(entry.id) } },
                leading: { if let symbol = entry.symbol { RowGlyph(systemName: symbol) } },
                trailing: { figure(entry.figure) })
            .accessibilityHint(select == nil ? "" : "Opens the details")
    }

    @ViewBuilder
    private func figure(_ figure: UpcomingEntry.Figure) -> some View {
        switch figure {
        case let .due(minorUnits, currency):
            MoneyText(minorUnits: minorUnits, currency: currency, role: .due)
        case let .expected(minorUnits, currency, isEstimate):
            HStack(spacing: 3) {
                if isEstimate { Text("≈").foregroundStyle(.secondary).accessibilityHidden(true) }
                MoneyText(minorUnits: minorUnits, currency: currency, role: .neutral)
            }
            .mangoFont(.body)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel((isEstimate ? "about " : "") + Money.format(minorUnits, currency: currency))
        case let .words(text):
            Text(text).mangoFont(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        case .none:
            EmptyView()
        }
    }
}
