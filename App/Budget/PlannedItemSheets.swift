// App/Budget/PlannedItemSheets.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Labels shared by the Budget grid's planned-item views.
enum PlanFormat {
    /// "One-off", "Monthly", "Every 2 weeks".
    static func frequency(_ frequency: ForecastFrequency, interval: Int) -> String {
        let (single, plural): (String, String)
        switch frequency {
        case .once: return "One-off"
        case .weekly: (single, plural) = ("Weekly", "weeks")
        case .monthly: (single, plural) = ("Monthly", "months")
        case .annually: (single, plural) = ("Annually", "years")
        }
        return interval <= 1 ? single : "Every \(interval) \(plural)"
    }

    static func unit(_ frequency: ForecastFrequency, interval: Int) -> String {
        switch frequency {
        case .once: return ""
        case .weekly: return interval == 1 ? "week" : "weeks"
        case .monthly: return interval == 1 ? "month" : "months"
        case .annually: return interval == 1 ? "year" : "years"
        }
    }

    /// Help text for a cell or Year Total with unconfirmed money (magnitudes, like the grid).
    static func pendingHelp(value: Int, pending: Int) -> String {
        let actual = value - pending
        let expected = Money.format(abs(pending), currency: .gbp)
        return actual == 0 ? "\(expected) expected" : "\(Money.format(abs(actual), currency: .gbp)) actual + \(expected) expected"
    }
}

/// The scope an occurrence edit applies to.
enum PlanEditScope {
    case onlyThis
    case thisAndFollowing
}

// MARK: - Drill-down: planned occurrences

/// The drill-down's "Planned" list for one category and calendar month: each occurrence's
/// date, amount, frequency and whether it's confirmed. Unconfirmed occurrences offer Edit…
/// and Remove…; the drill-down sheet owns the sheets and dialogs those open.
struct PlannedOccurrencesSection: View {
    let rows: [BudgetGridViewModel.PlannedRow]
    let errorMessage: String?
    let onEdit: (BudgetGridViewModel.PlannedRow) -> Void
    let onRemove: (BudgetGridViewModel.PlannedRow) -> Void

    var body: some View {
        Section("Planned") {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            if rows.isEmpty {
                Text("Nothing planned this month.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PayMonthFormat.longDay(row.occurrence.date))
                        Text(PlanFormat.frequency(row.entry.frequency, interval: row.entry.interval))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(minorUnits: row.occurrence.amountMinorUnits)
                    Text(row.isConfirmed ? "Confirmed" : "Unconfirmed")
                        .font(.caption)
                        .italic(!row.isConfirmed)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    if !row.isConfirmed {
                        Button("Edit…") { onEdit(row) }
                        Button("Remove…") { onRemove(row) }
                    }
                }
            }
        }
    }
}

// MARK: - Edit occurrence

/// Edits one unconfirmed occurrence: amount, date, category (same type; reserves for a
/// reserve) and the series' frequency. Save asks for the scope — "Only this occurrence" or
/// "This and all following"; a frequency change offers only the latter. Errors show inline
/// and keep the sheet open.
struct EditOccurrenceSheet: View {
    let row: BudgetGridViewModel.PlannedRow
    let categories: [Category]
    let onSave: (OccurrenceChange, PlanEditScope) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    /// Local midnight of the picked day (a `DatePicker` works in the local time zone).
    @State private var pickedDay: Date
    @State private var categoryId: Int64
    @State private var frequency: ForecastFrequency
    @State private var interval: Int
    @State private var choosingScope = false
    @State private var errorMessage: String?

    init(row: BudgetGridViewModel.PlannedRow, categories: [Category], onSave: @escaping (OccurrenceChange, PlanEditScope) -> SaveOutcome) {
        self.row = row
        self.categories = categories
        self.onSave = onSave
        _amountText = State(initialValue: Money.formatInput(abs(row.occurrence.amountMinorUnits)))
        _pickedDay = State(initialValue: PayCalendar.localDay(sameDayAs: row.occurrence.date, in: .current))
        _categoryId = State(initialValue: row.occurrence.categoryId)
        _frequency = State(initialValue: row.entry.frequency)
        _interval = State(initialValue: row.entry.interval)
    }

    private var current: Category? { categories.first { $0.id == row.occurrence.categoryId } }

    /// Non-reserved categories of the occurrence's type, or the reserves for a reserve.
    private var pickerCategories: [Category] {
        guard let current else { return [] }
        let options = current.isReserved
            ? categories.filter(\.isReserved)
            : categories.filter { !$0.isReserved && $0.type == current.type && $0.isAssignable }
        return options.contains(where: { $0.id == current.id }) ? options : [current] + options
    }

    /// The typed magnitude with the occurrence's sign kept; nil if empty, invalid or zero.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountText), minorUnits != 0 else { return nil }
        return row.occurrence.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    private var pickedDate: Date { PayCalendar.utcDay(sameDayAs: pickedDay, in: .current) }

    /// Only what changed; nil fields stay as they are.
    private var change: OccurrenceChange? {
        guard let signedAmount else { return nil }
        var change = OccurrenceChange()
        if signedAmount != row.occurrence.amountMinorUnits { change.amountMinorUnits = signedAmount }
        if pickedDate != row.occurrence.date { change.date = pickedDate }
        if categoryId != row.occurrence.categoryId { change.categoryId = categoryId }
        if frequency != row.entry.frequency { change.frequency = frequency }
        if interval != row.entry.interval { change.interval = interval }
        return change == OccurrenceChange() ? nil : change
    }

    private var changesFrequency: Bool { frequency != row.entry.frequency || interval != row.entry.interval }

    var body: some View {
        Form {
            Text("Edit planned occurrence").font(.headline)
            MoneyField("Amount", text: $amountText, currency: .gbp)
            DatePicker("Date", selection: $pickedDay, displayedComponents: .date)
            Picker("Category", selection: $categoryId) {
                ForEach(pickerCategories) { category in Text(category.name).tag(category.id!) }
            }
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(PlanFormat.frequency(freq, interval: 1)).tag(freq) }
            }
            if frequency != .once {
                Stepper("Every \(interval) \(PlanFormat.unit(frequency, interval: interval))", value: $interval, in: 1...12)
            }
            if changesFrequency {
                Text("A frequency change applies to this and all following occurrences.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save…") { errorMessage = nil; choosingScope = true }
                    .disabled(change == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: amountText) { _, _ in errorMessage = nil }
        .onChange(of: pickedDay) { _, _ in errorMessage = nil }
        .confirmationDialog("Apply this change to", isPresented: $choosingScope) {
            if !changesFrequency {
                Button("Only this occurrence") { save(.onlyThis) }
            }
            Button("This and all following") { save(.thisAndFollowing) }
            Button("Cancel", role: .cancel) {}
        }
        .padding()
        .frame(width: 420)
    }

    private func save(_ scope: PlanEditScope) {
        guard let change else { return }
        switch onSave(change, scope) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}

// MARK: - Add planned item

/// "+ Add planned item" from an Income / Expenses / Transfers header: a category of that
/// section, an amount, one-off or recurring (weekly / monthly / annually, every N), a start
/// and an optional end. Saved through `PlannedItems.add`; errors show inline.
struct AddPlannedItemSheet: View {
    let type: CategoryType
    let categories: [Category]
    let onSave: (_ categoryId: Int64, _ amountMinorUnits: Int, ForecastFrequency, _ interval: Int, _ start: Date, _ end: Date?) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: Int64?
    @State private var amountText = ""
    @State private var isRecurring = true
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var hasEndDate = false
    @State private var endDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var errorMessage: String?

    private var pickerCategories: [Category] {
        categories.filter { $0.type == type && !$0.isReserved && $0.isAssignable }.sorted { $0.name < $1.name }
    }

    private var title: String {
        switch type {
        case .income: return "Add planned income"
        case .expense: return "Add planned expense"
        case .transfer: return "Add planned transfer"
        }
    }

    /// Income inward (positive); expenses and transfers outward (negative), as the Forecast
    /// screen's planned items always were.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountText), minorUnits != 0 else { return nil }
        return type == .income ? abs(minorUnits) : -abs(minorUnits)
    }

    private var canSave: Bool { categoryId != nil && signedAmount != nil }

    var body: some View {
        Form {
            Text(title).font(.headline)
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(pickerCategories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            MoneyField("Amount", text: $amountText, currency: .gbp)
            Picker("Repeats", selection: $isRecurring) {
                Text("One-off").tag(false)
                Text("Recurring").tag(true)
            }
            .pickerStyle(.segmented)
            if isRecurring {
                Picker("Frequency", selection: $frequency) {
                    ForEach([ForecastFrequency.weekly, .monthly, .annually], id: \.self) { freq in Text(PlanFormat.frequency(freq, interval: 1)).tag(freq) }
                }
                Stepper("Every \(interval) \(PlanFormat.unit(frequency, interval: interval))", value: $interval, in: 1...12)
            }
            DatePicker(isRecurring ? "Starting" : "Date", selection: $startDay, displayedComponents: .date)
            if isRecurring {
                Toggle("Ends on a specific date", isOn: $hasEndDate)
                if hasEndDate {
                    DatePicker("Ends", selection: $endDay, in: startDay..., displayedComponents: .date)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: amountText) { _, _ in errorMessage = nil }
        .onChange(of: categoryId) { _, _ in errorMessage = nil }
        .padding()
        .frame(width: 420)
    }

    private func save() {
        guard let categoryId, let amount = signedAmount else { return }
        let start = PayCalendar.utcDay(sameDayAs: startDay, in: .current)
        // The end is the last moment of its UTC day, so an occurrence on that day still counts.
        let end = isRecurring && hasEndDate
            ? PayCalendar.utcDay(sameDayAs: endDay, in: .current).addingTimeInterval(86_399)
            : nil
        switch onSave(categoryId, amount, isRecurring ? frequency : .once, isRecurring ? interval : 1, start, end) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}
