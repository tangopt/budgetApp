// App/Shared/CloseMonthView.swift
import SwiftUI
import BudgetCore

/// Labels for pay months, shared by the Budget grid and the Dashboard. All dates are UTC
/// (pay-month boundaries are UTC days).
enum PayMonthFormat {
    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let monthYearFormatter = utcFormatter("MMMM yyyy")
    private static let monthFormatter = utcFormatter("MMMM")
    private static let shortDayFormatter = utcFormatter("d MMM")
    private static let longDayFormatter = utcFormatter("d MMMM yyyy")

    private static func firstDay(_ month: PayMonth) -> Date { MonthRange.of(year: month.year, month: month.month).start }

    /// "October 2026"
    static func name(_ month: PayMonth) -> String { monthYearFormatter.string(from: firstDay(month)) }
    /// "October"
    static func monthName(_ month: PayMonth) -> String { monthFormatter.string(from: firstDay(month)) }
    /// "16 Sep"
    static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }
    /// "15 October 2026"
    static func longDay(_ date: Date) -> String { longDayFormatter.string(from: date) }
    /// "16 Sep – 15 Oct"
    static func range(_ range: (start: Date, end: Date)) -> String { "\(shortDay(range.start)) – \(shortDay(range.end))" }

    /// The inline error for `PayCalendarError.invalidCloseDate`.
    static func invalidCloseDateMessage(_ month: PayMonth, calendar: PayCalendar) -> String {
        "Pick a date inside \(name(month)) (from \(shortDay(calendar.range(of: month).start)))."
    }
}

/// The Close month sheet: picks the last day of a pay month. `onClose` receives the picked
/// day as 00:00 UTC and returns whether the close was saved; the sheet dismisses on success
/// and otherwise shows `errorMessage` (the caller's view model sets it) inline.
struct CloseMonthView: View {
    let month: PayMonth
    let calendar: PayCalendar
    let errorMessage: String?
    let onClose: (Date) -> Bool
    @Environment(\.dismiss) private var dismiss
    /// Local midnight of the picked day (a `DatePicker` works in the local time zone).
    @State private var pickedDay: Date

    init(month: PayMonth, calendar: PayCalendar, errorMessage: String?, onClose: @escaping (Date) -> Bool) {
        self.month = month
        self.calendar = calendar
        self.errorMessage = errorMessage
        self.onClose = onClose
        _pickedDay = State(initialValue: PayCalendar.localDay(sameDayAs: calendar.suggestedCloseDate(of: month), in: .current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Close \(PayMonthFormat.name(month))").font(.title3.bold())
            Text("Currently \(PayMonthFormat.range(calendar.range(of: month)))")
                .foregroundStyle(.secondary)
            DatePicker("Last day", selection: $pickedDay, in: PayCalendar.localDay(sameDayAs: calendar.range(of: month).start, in: .current)..., displayedComponents: .date)
            Text("Spending after this date counts in \(PayMonthFormat.name(month.next)).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Close month") {
                    if onClose(PayCalendar.utcDay(sameDayAs: pickedDay, in: .current)) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Identifies the month a Close month sheet is open for (`.sheet(item:)`).
struct CloseMonthTarget: Identifiable {
    let month: PayMonth
    var id: String { "\(month.year)-\(month.month)" }
}
