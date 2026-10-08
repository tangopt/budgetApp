// App/Budget/ReserveSheets.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Which reserve an allowance goes to: an existing one, or one created with it.
enum ReserveTarget {
    case existing(Category)
    case new(name: String)
}

/// Creates a reserve with its first allowance, adds another allowance to an existing one
/// (the Budget grid's Reserved header and reserve rows), or — in a scenario — adds an
/// allowance to a reserve picked from `reserves` or created with it. A failed save keeps the
/// sheet open with `errorMessage` shown inline.
struct ReserveFormView: View {
    enum Mode {
        case newReserve
        case addAmount(Category)
        /// A scenario's "+ Add allowance…": pick a reserve or "+ New reserve…".
        case chooseReserve(reserves: [Category], scenarioName: String)
    }
    let mode: Mode
    /// The error from the last failed save, shown inline above the buttons.
    let errorMessage: String?
    /// Called when the user edits the name, amount or end, to clear a stale `errorMessage`.
    let onEdit: () -> Void
    let onSave: (ReserveTarget, _ amountMinorUnits: Int, ForecastFrequency, Int, Date, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Sentinel for "+ New reserve…" (real ids are positive rowids).
    private static let newReserveSentinel: Int64 = -1

    @State private var name = ""
    @State private var pickedReserveId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    /// Local midnight of the picked days (a `DatePicker` works in the local time zone).
    @State private var startDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var endMode: RecurrenceEndMode = .never
    @State private var occurrenceCount = 12
    @State private var endDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)

    private var parsedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds), minorUnits != 0 else { return nil }
        return minorUnits
    }

    /// Where the allowance goes, once the form says (nil while a name or pick is missing).
    private var target: ReserveTarget? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .newReserve:
            return trimmed.isEmpty ? nil : .new(name: name)
        case .addAmount(let reserve):
            return .existing(reserve)
        case .chooseReserve(let reserves, _):
            guard let pickedReserveId else { return nil }
            if pickedReserveId == Self.newReserveSentinel { return trimmed.isEmpty ? nil : .new(name: name) }
            return reserves.first { $0.id == pickedReserveId }.map { .existing($0) }
        }
    }

    /// The date of the Nth occurrence for "After N" (the Nth, from the start, of the form's schedule).
    private var lastDate: Date {
        RecurrenceEnd.endDate(start: PayCalendar.utcDay(sameDayAs: startDay, in: .current), frequency: frequency, interval: interval, anchorDay: nil, occurrences: RecurrenceEndFields.clamped(occurrenceCount))
    }

    /// Save needs a non-zero amount and a reserve (a non-blank name for a new one).
    private var canSave: Bool { parsedAmount != nil && target != nil }

    var body: some View {
        Form {
            switch mode {
            case .newReserve:
                TextField("Reserve name", text: $name)
                    .onChange(of: name) { _, _ in onEdit() }
                Text("A forecast-only allowance for spending you expect but don't plan line by line. It never holds transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            case .addAmount(let reserve):
                Text("Add an amount to \(reserve.name)").font(.headline)
            case .chooseReserve(let reserves, let scenarioName):
                Text("Add a reserve allowance to “\(scenarioName)”").font(.headline)
                Picker("Reserve", selection: $pickedReserveId) {
                    Text("Select…").tag(Int64?.none)
                    ForEach(reserves) { reserve in Text(reserve.name).tag(Int64?.some(reserve.id!)) }
                    Text("+ New reserve…").tag(Int64?.some(Self.newReserveSentinel))
                }
                .onChange(of: pickedReserveId) { _, _ in onEdit() }
                if pickedReserveId == Self.newReserveSentinel {
                    TextField("New reserve name", text: $name)
                        .onChange(of: name) { _, _ in onEdit() }
                    Text("The reserve itself is shared with the budget and every scenario; this allowance stays in the scenario.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            MoneyField("Amount", text: $amountPounds, currency: .gbp)
                .onChange(of: amountPounds) { _, _ in onEdit() }
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(PlanFormat.frequency(freq, interval: 1)).tag(freq) }
            }
            if frequency != .once {
                Stepper("Every \(interval) \(PlanFormat.unit(frequency, interval: interval))", value: $interval, in: 1...12)
            }
            DatePicker("Starting", selection: $startDay, displayedComponents: .date)
            if frequency != .once {
                RecurrenceEndFields(mode: $endMode, endDay: $endDay, count: $occurrenceCount, startDay: startDay, lastDate: lastDate)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let target, let minorUnits = parsedAmount else { return }
                    let start = PayCalendar.utcDay(sameDayAs: startDay, in: .current)
                    let end = frequency == .once ? nil : RecurrenceEndFields.resolve(mode: endMode, endDay: endDay, count: occurrenceCount, lastDate: lastDate)
                    onSave(target, -abs(minorUnits), frequency, frequency == .once ? 1 : interval, start, end)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: endMode) { _, _ in onEdit() }
        .onChange(of: endDay) { _, _ in onEdit() }
        .onChange(of: occurrenceCount) { _, _ in onEdit() }
        .padding()
        .frame(width: 420)
    }
}

/// Renames a reserve. A sheet rather than an alert so a failed rename (duplicate or
/// blank name) can stay open with the typed name kept and the error shown inline.
struct RenameReserveView: View {
    let reserve: Category
    let errorMessage: String?
    let onEdit: () -> Void
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(reserve: Category, errorMessage: String?, onEdit: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.reserve = reserve
        self.errorMessage = errorMessage
        self.onEdit = onEdit
        self.onSave = onSave
        _name = State(initialValue: reserve.name)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Text("Rename reserve").font(.headline)
            TextField("Name", text: $name)
                .onChange(of: name) { _, _ in onEdit() }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard canSave else { return }
                    onSave(name)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
