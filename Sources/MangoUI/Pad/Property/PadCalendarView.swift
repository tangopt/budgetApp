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

    private static let monthTitle = Date.FormatStyle(timeZone: MonthRange.calendar.timeZone).month(.wide).year()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let sideCard = geometry.size.width >= 860 && model.selected != nil
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if model.isEmpty {
                                EmptyState(symbol: "calendar.badge.clock", title: "Nothing due",
                                           message: "Link the property's accounts and category groups in Profile so recurring costs and the mortgage show here.")
                                    .frame(maxWidth: .infinity).padding(.top, 60)
                            } else {
                                controls
                                if !sideCard, let obligation = model.selected {
                                    PadObligationCard(obligation: obligation, onClose: model.closeCard)
                                }
                                switch model.layout {
                                case .agenda: agenda
                                case .month: monthGrid
                                }
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity)
                    if sideCard, let obligation = model.selected {
                        Divider()
                        ScrollView {
                            PadObligationCard(obligation: obligation, onClose: model.closeCard).padding(20)
                        }
                        .frame(width: 340)
                    }
                }
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayModeInline()
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(month.obligations) { obligation in row(obligation) }
                }
            }
        }
    }

    private func row(_ obligation: PropertyObligation) -> some View {
        let isSelected = obligation.id == model.selectedId
        return Button { model.select(obligation) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: PadCalendarModel.symbol(obligation.kind)).foregroundStyle(.secondary)
                        .frame(width: 22).accessibilityHidden(true)
                    Text(PadCalendarModel.shortTitle(obligation)).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(PhoneDateFormat.day(obligation.date).unbroken).mangoFont(.subheadline, figures: true).foregroundStyle(.secondary)
                    PadStatusPill(text: PadCalendarModel.kindName(obligation.kind), tone: pillTone(obligation.kind))
                    Spacer(minLength: 4)
                    PadObligationAmount(obligation: obligation, font: .headline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
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
                Button { model.shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.pad(.secondary)).accessibilityLabel("Previous month")
                Button { model.showToday() } label: { Text("Today") }
                    .buttonStyle(.pad(.secondary))
                Button { model.shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.pad(.secondary)).accessibilityLabel("Next month")
            }
            Card {
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol).mangoFont(.footnote, weight: .semibold).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityHidden(true)
                    let days = model.gridDays
                    ForEach(0..<PropertyCalendarGrid.weeks, id: \.self) { week in
                        HStack(spacing: 4) {
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(items) { row($0) }
            }
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
        return Button { model.tap(day) } label: {
            VStack(spacing: 3) {
                Text("\(number)").mangoFont(.body, weight: isToday ? .bold : .regular, figures: true)
                    .foregroundStyle(day.isInMonth ? Color.primary : Color.secondary.opacity(0.6))
                HStack(spacing: 3) {
                    ForEach(Array(day.items.prefix(3).enumerated()), id: \.offset) { _, item in
                        Circle().fill(theme.accent).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                            .opacity(item.id == model.selectedId ? 1 : 0.8)
                    }
                    if day.items.isEmpty { Circle().fill(Color.clear).frame(width: 6, height: 6) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isToday ? theme.accent.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
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
    let onClose: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: PadCalendarModel.symbol(obligation.kind)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(PadCalendarModel.shortTitle(obligation)).mangoFont(.headline).lineLimit(3).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").mangoFont(.title2).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Close")
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
