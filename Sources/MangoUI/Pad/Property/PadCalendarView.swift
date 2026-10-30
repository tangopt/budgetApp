import SwiftUI
import BudgetCore

/// Property ▸ Calendar on the iPad (step 10, Task 15): what falls due, as an agenda of the next twelve months grouped by month
/// (a pill for the kind, "≈" before an amount estimated from the history) or a small month grid with a dot for each day
/// something is due. Upcoming and Past switch the range; tapping a grid day narrows the list to it; a tapped obligation opens
/// its card (beside the list when there is room, above it otherwise). The Calendar reads and writes nothing else.
struct PadCalendarView: View {
    @ObservedObject var model: PadCalendarModel
    let syncStatus: SyncStatus
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let monthTitle = Date.FormatStyle(timeZone: MonthRange.calendar.timeZone).month(.wide).year()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.section) {
                    if model.isEmpty {
                        EmptyState(symbol: "calendar.badge.clock", title: "Nothing due",
                                   message: "Link the property's accounts and category groups in Profile so recurring costs and the mortgage show here.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        controls
                        switch model.layout {
                        case .agenda: agenda
                        case .month: monthGrid
                        }
                    }
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Calendar")
        }
        .padSidePanel(isPresented: model.selected != nil, onClose: model.closeCard) {
            if let obligation = model.selected {
                PadSidePanel(title: PadCalendarModel.shortTitle(obligation), subtitle: PhoneDateFormat.day(obligation.date),
                             onClose: model.closeCard) {
                    PadObligationCard(obligation: obligation, showsHeader: false)
                }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.property.reload()
            await model.reload()
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                layoutPicker.frame(maxWidth: 260)
                if model.layout == .agenda { rangePicker.frame(maxWidth: 260) }
                Spacer(minLength: 8)
                if model.selectedDay != nil { clearDay }
            }
            VStack(alignment: .leading, spacing: 10) {
                layoutPicker
                if model.layout == .agenda { rangePicker }
                if model.selectedDay != nil { clearDay }
            }
        }
    }

    private var layoutPicker: some View {
        Picker("View", selection: $model.layout) {
            ForEach(PadCalendarModel.Layout.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("View")
    }

    private var rangePicker: some View {
        Picker("Range", selection: $model.range) {
            ForEach(PadCalendarModel.Range.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Range")
    }

    private var clearDay: some View {
        Button { model.selectedDay = nil } label: {
            Label(PhoneDateFormat.day(model.selectedDay).unbroken, systemImage: "xmark.circle.fill")
        }
        .buttonStyle(.pad(.secondary, size: .small))
        .accessibilityLabel("Show every day again")
    }

    // MARK: Agenda

    @ViewBuilder
    private var agenda: some View {
        let months = model.agenda
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.range == .upcoming ? "The next twelve months" : "The last twelve months")
                    .mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
            }
            Text("≈ an estimate from the property's history").mangoFont(.footnote).foregroundStyle(.secondary)
        }
        if months.isEmpty {
            Text(model.selectedDay == nil ? "Nothing in this range." : "Nothing is due that day.")
                .mangoFont(.callout).foregroundStyle(.secondary)
        }
        ForEach(months) { month in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(month.start.formatted(Self.monthTitle)).mangoFont(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    ForEach(month.totals, id: \.currency) { total in
                        HStack(spacing: 3) {
                            if month.hasEstimates { Text("≈").foregroundStyle(.secondary).accessibilityHidden(true) }
                            MoneyText(minorUnits: total.minorUnits, currency: total.currency, role: .neutral, font: .subheadline.weight(.semibold))
                        }
                    }
                }
                obligationList(month.obligations)
            }
        }
    }

    private func obligationList(_ items: [PropertyObligation]) -> some View {
        Card {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, obligation in
                if index > 0 { Divider() }
                row(obligation)
            }
        }
    }

    /// One obligation as a list row: its icon and title, the day and kind pill, the amount.
    private func row(_ obligation: PropertyObligation) -> some View {
        let isSelected = obligation.id == model.selectedId
        return Button { model.select(obligation) } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: PadCalendarModel.symbol(obligation.kind)).foregroundStyle(.secondary)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PadCalendarModel.shortTitle(obligation)).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
                    Text(PhoneDateFormat.day(obligation.date).unbroken).mangoFont(.subheadline, figures: true).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PadStatusPill(text: PadCalendarModel.kindName(obligation.kind), tone: pillTone(obligation.kind))
                PadObligationAmount(obligation: obligation, font: .headline)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? theme.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Opens the details")
    }

    private func pillTone(_ kind: PropertyObligationKind) -> PadStatusPill.Tone {
        switch kind {
        case .ptIncomeTaxReturn, .ukSelfAssessmentJanuary, .ukSelfAssessmentJuly: .accent
        case .mortgageRateReset, .insuranceRenewal: .warning
        case .imiInstalment, .mortgageInstalment, .recurringCost: .neutral
        }
    }

    // MARK: Month grid

    @ViewBuilder
    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(model.shownMonth.formatted(Self.monthTitle)).mangoFont(.title3, weight: .semibold).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                PadIconButton(systemImage: "chevron.left", label: "Previous month", prominent: true) { model.shiftMonth(by: -1) }
                Button { model.showToday() } label: { Text("Today").mangoFont(.subheadline, weight: .semibold).frame(minHeight: 44) }
                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                PadIconButton(systemImage: "chevron.right", label: "Next month", prominent: true) { model.shiftMonth(by: 1) }
            }
            Card {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol).mangoFont(.footnote, weight: .semibold).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityHidden(true)
                    let days = model.gridDays
                    ForEach(0..<PropertyCalendarGrid.weeks, id: \.self) { week in
                        HStack(spacing: 2) {
                            ForEach(days[(week * 7)..<(week * 7 + 7)]) { day in cell(day) }
                        }
                    }
                }
            }
            let items = model.shownMonthItems
            Text(model.selectedDay.map { PhoneDateFormat.day($0).unbroken } ?? model.shownMonth.formatted(Self.monthTitle))
                .mangoFont(.headline)
            if items.isEmpty {
                Text("Nothing is due.").mangoFont(.callout).foregroundStyle(.secondary)
            }
            if !items.isEmpty { obligationList(items) }
        }
    }

    private var weekdaySymbols: [String] {
        let calendar = model.calendar
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func cell(_ day: PropertyCalendarGrid.GridDay) -> some View {
        let calendar = model.calendar
        let number = calendar.component(.day, from: day.date)
        let isToday = calendar.isDate(day.date, inSameDayAs: model.snapshot.today)
        let isSelected = model.selectedDay.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
        let weekend = calendar.isDateInWeekend(day.date)
        let amounts = day.items.compactMap { item in item.expectedMinorUnits.flatMap { amount in item.currency.map { (amount, $0) } } }
        let currencies = Set(amounts.map(\.1))
        return Button { model.tap(day) } label: {
            VStack(spacing: 2) {
                Text("\(number)").mangoFont(.subheadline, weight: isToday ? .bold : .regular, figures: true)
                    .foregroundStyle(isToday ? Color.white : (day.isInMonth ? Color.primary : Color.secondary.opacity(0.6)))
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Circle().fill(isToday ? theme.accent : .clear))
                if let currency = currencies.first, currencies.count == 1, dynamicTypeSize < .xLarge {
                    MoneyText(minorUnits: amounts.reduce(0) { $0 + $1.0 }, currency: currency, role: .neutral, fit: .shrink(), font: .caption2)
                        .opacity(day.isInMonth ? 1 : 0.5)
                } else if day.items.isEmpty {
                    Color.clear.frame(height: 12)
                } else {
                    Circle().fill(theme.accent).frame(width: 6, height: 6).frame(height: 12).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(weekend ? Color.secondary.opacity(0.07) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PhoneDateFormat.day(day.date) + (day.items.isEmpty ? "" : ", \(day.items.count) due"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An obligation's expected amount, "≈" before it when it's an estimate from the history; nothing for a deadline (its pill
/// says what it is).
struct PadObligationAmount: View {
    let obligation: PropertyObligation
    var font: PhoneTextStyle = .body

    var body: some View {
        if let amount = obligation.expectedMinorUnits, let currency = obligation.currency {
            HStack(spacing: 3) {
                if obligation.isEstimate { Text("≈").foregroundStyle(.secondary).accessibilityHidden(true) }
                MoneyText(minorUnits: amount, currency: currency, role: .neutral, font: font)
            }
            .mangoFont(font)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel((obligation.isEstimate ? "about " : "") + Money.format(amount, currency: currency))
        }
    }
}

/// The selected obligation: its kind and date, the expected amount (or that it is a deadline), what it is.
struct PadObligationCard: View {
    let obligation: PropertyObligation
    /// The title row (in the side panel the panel's own header says it).
    var showsHeader = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: PadCalendarModel.symbol(obligation.kind)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(PadCalendarModel.shortTitle(obligation)).mangoFont(.headline).lineLimit(3).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 8) {
                    PadStatusPill(text: PadCalendarModel.kindName(obligation.kind), tone: .neutral)
                    if obligation.isEstimate { PadStatusPill(text: "Estimate", tone: .accent) }
                }
                fact("Due", Text(PhoneDateFormat.day(obligation.date).unbroken))
                if obligation.expectedMinorUnits != nil {
                    fact("Expected", PadObligationAmount(obligation: obligation, font: .subheadline))
                } else {
                    Text("A deadline: no amount is expected.").mangoFont(.subheadline).foregroundStyle(.secondary)
                }
                if obligation.title != PadCalendarModel.shortTitle(obligation) {
                    Text(obligation.title).mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(PadCalendarModel.explanation(obligation)).mangoFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if obligation.isEstimate {
                    Text("An estimate from the property's history, not an invoice.").mangoFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func fact<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 12)
            value.lineLimit(1).fixedSize()
        }
        .mangoFont(.subheadline)
    }
}
