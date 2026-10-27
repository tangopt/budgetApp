import XCTest
@testable import BudgetCore

/// Step 10 Task 15: the Calendar's month grid and agenda are placements of the obligations: whole weeks on the calendar's first
/// weekday, items on their day, the next twelve months, the leap day and the year boundary.
final class PropertyCalendarGridTests: XCTestCase {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = MonthRange.calendar
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func item(_ date: Date, _ title: String = "Item", kind: PropertyObligationKind = .recurringCost) -> PropertyObligation {
        PropertyObligation(id: "\(kind.rawValue)/\(date.timeIntervalSince1970)/\(title)", date: date, kind: kind, title: title,
                           expectedMinorUnits: 10_000, currency: .eur, categoryId: nil, isEstimate: true)
    }

    func testGridHasWholeWeeksStartingOnLocaleFirstWeekday() {
        // 1 October 2026 is a Thursday.
        for firstWeekday in [1, 2, 7] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let days = PropertyCalendarGrid.month(day(2026, 10, 15), items: [], calendar: calendar)
            XCTAssertEqual(days.count, 42)
            XCTAssertEqual(calendar.component(.weekday, from: days[0].date), firstWeekday, "the grid starts on the first weekday")
            XCTAssertEqual(days.filter(\.isInMonth).count, 31)
            XCTAssertEqual(days.first { $0.isInMonth }.map { calendar.component(.day, from: $0.date) }, 1)
            // The month's days run on without a gap, and the flagged leading and trailing days sit outside it.
            let inside = days.indices.filter { days[$0].isInMonth }
            XCTAssertEqual(inside, Array(inside.first!...inside.last!))
            XCTAssertLessThan(inside.first!, 7, "at most a week of leading days")
        }
        // Monday start: Thursday 1 October has three leading days.
        let monday = PropertyCalendarGrid.month(day(2026, 10, 1), items: [], calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(monday.firstIndex { $0.isInMonth }, 3)
    }

    func testItemsLandOnTheirDay() {
        let calendar = calendar(firstWeekday: 2)
        let rate = item(day(2026, 10, 1), "Rate", kind: .mortgageRateReset)
        let imi = item(day(2026, 10, 31), "IMI", kind: .imiInstalment)
        let twice = [item(day(2026, 10, 15), "A"), item(day(2026, 10, 15), "B")]
        let spill = item(day(2026, 11, 2), "Spills into the grid")
        let days = PropertyCalendarGrid.month(day(2026, 10, 9), items: [rate, imi, spill] + twice, calendar: calendar)
        func items(on date: Date) -> [String] { days.first { $0.date == date }?.items.map(\.title) ?? [] }
        XCTAssertEqual(items(on: day(2026, 10, 1)), ["Rate"])
        XCTAssertEqual(items(on: day(2026, 10, 31)), ["IMI"])
        XCTAssertEqual(items(on: day(2026, 10, 15)).sorted(), ["A", "B"])
        XCTAssertEqual(items(on: day(2026, 11, 2)), ["Spills into the grid"])
        XCTAssertEqual(days.first { $0.date == day(2026, 11, 2) }?.isInMonth, false)
        XCTAssertEqual(days.flatMap(\.items).count, 5)
    }

    func testAgendaCoversNext12Months() {
        let calendar = MonthRange.calendar
        let today = day(2026, 10, 15)
        let items = [item(day(2026, 10, 1), "Earlier this month"), item(day(2026, 10, 31), "Month end"), item(day(2027, 9, 30), "Last month"),
                     item(day(2027, 11, 1), "Too far"), item(day(2026, 9, 30), "Before")]
        let agenda = PropertyCalendarGrid.agenda(items, from: today, months: 12, calendar: calendar)
        XCTAssertEqual(agenda.map(\.start), [day(2026, 10, 1), day(2027, 9, 1)], "months with nothing due are left out")
        XCTAssertEqual(agenda.first?.obligations.map(\.title), ["Earlier this month", "Month end"])
        XCTAssertEqual(agenda.flatMap(\.obligations).count, 3)
        XCTAssertTrue(agenda.flatMap(\.obligations).allSatisfy { $0.title != "Too far" && $0.title != "Before" })
        XCTAssertEqual(agenda.first?.totals.first?.minorUnits, 20_000)
        XCTAssertEqual(agenda.first?.hasEstimates, true)

        // The past: the 12 months back from this one, nearest first, latest first within a month.
        let past = PropertyCalendarGrid.agenda(items + [item(day(2025, 9, 30), "A year back"), item(day(2025, 10, 5), "Oldest month")],
                                               from: today, months: -12, calendar: calendar)
        XCTAssertEqual(past.map(\.start), [day(2026, 10, 1), day(2026, 9, 1), day(2025, 10, 1)])
        XCTAssertEqual(past.first?.obligations.map(\.title), ["Month end", "Earlier this month"])
    }

    func testLeapDayAndYearBoundary() {
        let calendar = calendar(firstWeekday: 2)
        // 29 February 2028 (a leap year) has its cell; February 2027 has none.
        let leap = PropertyCalendarGrid.month(day(2028, 2, 10), items: [item(day(2028, 2, 29), "Leap")], calendar: calendar)
        XCTAssertEqual(leap.filter(\.isInMonth).count, 29)
        XCTAssertEqual(leap.first { $0.date == day(2028, 2, 29) }?.items.map(\.title), ["Leap"])
        XCTAssertEqual(PropertyCalendarGrid.month(day(2027, 2, 10), items: [], calendar: calendar).filter(\.isInMonth).count, 28)
        // December's trailing days are January's, and the agenda runs across the year end.
        let december = PropertyCalendarGrid.month(day(2026, 12, 1), items: [item(day(2027, 1, 2), "New year")], calendar: calendar)
        XCTAssertEqual(december.last?.date, day(2027, 1, 10))
        XCTAssertEqual(december.first { $0.date == day(2027, 1, 2) }?.items.count, 1)
        let agenda = PropertyCalendarGrid.agenda([item(day(2026, 12, 31), "Dec"), item(day(2027, 1, 1), "Jan")], from: day(2026, 12, 20),
                                                 months: 12, calendar: calendar)
        XCTAssertEqual(agenda.map(\.start), [day(2026, 12, 1), day(2027, 1, 1)])
    }
}
