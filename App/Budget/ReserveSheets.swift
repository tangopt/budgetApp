// App/Budget/ReserveSheets.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Creates a reserve with its first allowance, or adds another allowance to an existing
/// one (the Budget grid's Reserved header and reserve rows). A failed save keeps the sheet
/// open with `errorMessage` shown inline.
struct ReserveFormView: View {
    enum Mode { case newReserve; case addAmount(Category) }
    let mode: Mode
    /// The error from the last failed save, shown inline above the buttons.
    let errorMessage: String?
    /// Called when the user edits the name or amount, to clear a stale `errorMessage`.
    let onEdit: () -> Void
    let onSave: (_ name: String, _ amountMinorUnits: Int, ForecastFrequency, Int, Date, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    /// Local midnight of the picked days (a `DatePicker` works in the local time zone).
    @State private var startDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var hasEndDate = false
    @State private var endDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)

    private var parsedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds), minorUnits != 0 else { return nil }
        return minorUnits
    }

    /// Save needs a non-zero amount and, for a new reserve, a non-blank name.
    private var canSave: Bool {
        guard parsedAmount != nil else { return false }
        if case .newReserve = mode { return !name.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

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
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate { DatePicker("Ends", selection: $endDay, in: startDay..., displayedComponents: .date) }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard canSave, let minorUnits = parsedAmount else { return }
                    let start = PayCalendar.utcDay(sameDayAs: startDay, in: .current)
                    // The end is the last moment of its UTC day, so an occurrence on that day still counts.
                    let end = hasEndDate ? PayCalendar.utcDay(sameDayAs: endDay, in: .current).addingTimeInterval(86_399) : nil
                    onSave(name, -abs(minorUnits), frequency, frequency == .once ? 1 : interval, start, end)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
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
