// App/Budget/RecurrenceEndFields.swift
import SwiftUI
import BudgetCore

/// How a recurring item ends: never, on a picked date, or after N occurrences.
enum RecurrenceEndMode: Hashable {
    case never, onDate, after
}

/// The "Ends" fields shared by the add, edit-occurrence and reserve sheets: a segmented
/// Never / On a date / After picker, the date or the occurrence count (with a live
/// "Last: <date>" caption). `lastDate` is the date of the Nth occurrence for the sheet's
/// current schedule (`RecurrenceEnd.endDate`).
struct RecurrenceEndFields: View {
    @Binding var mode: RecurrenceEndMode
    @Binding var endDay: Date
    @Binding var count: Int
    /// Earliest pickable end day (local midnight of the start).
    let startDay: Date
    let lastDate: Date

    private static let lastFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        Picker("Ends", selection: $mode) {
            Text("Never").tag(RecurrenceEndMode.never)
            Text("On a date").tag(RecurrenceEndMode.onDate)
            Text("After").tag(RecurrenceEndMode.after)
        }
        .pickerStyle(.segmented)
        switch mode {
        case .never:
            EmptyView()
        case .onDate:
            DatePicker("Ends", selection: $endDay, in: startDay..., displayedComponents: .date)
        case .after:
            HStack {
                TextField("", value: $count, format: .number)
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: count) { _, new in
                        let clamped = Self.clamped(new)
                        if clamped != new { count = clamped }
                    }
                Stepper("", value: $count, in: 1...999)
                    .labelsHidden()
                Text(count == 1 ? "occurrence" : "occurrences")
                Spacer()
            }
            Text("Last: \(Self.lastFormatter.string(from: lastDate))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The stored end date for the chosen mode (nil = never). "On a date" ends at the last
    /// moment of its UTC day, so an occurrence on that day still counts.
    static func resolve(mode: RecurrenceEndMode, endDay: Date, count: Int, lastDate: Date) -> Date? {
        switch mode {
        case .never: return nil
        case .onDate: return PayCalendar.utcDay(sameDayAs: endDay, in: .current).addingTimeInterval(86_399)
        case .after: return lastDate
        }
    }

    /// Clamps a typed count to 1...999.
    static func clamped(_ count: Int) -> Int { min(max(count, 1), 999) }
}
