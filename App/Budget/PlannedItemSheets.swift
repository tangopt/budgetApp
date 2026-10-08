// App/Budget/PlannedItemSheets.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Whose plan an edit applies to: the budget, or one scenario (the Forecast screen's lab).
/// Editing an occurrence is scoped by its entry; adding needs the scope.
enum PlanScope: Equatable {
    case budget
    case scenario(id: Int64, name: String)

    var scenarioId: Int64? {
        if case .scenario(let id, _) = self { return id }
        return nil
    }
}

/// Labels shared by the Budget grid's and the scenario lab's planned-item views.
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

    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let shortMonthYear = utcFormatter("MMM yyyy")
    private static let shortDayMonthYear = utcFormatter("d MMM yyyy")

    /// An existing planned series in one line (magnitude, like the grid): "£2,171.08 monthly
    /// from Feb 2026", "£45.00 every 2 weeks from Nov 2026 until Oct 2027", "£1,000.00
    /// one-off on 20 Dec 2026". Dates are UTC days.
    static func series(_ entry: ForecastEntry) -> String {
        let amount = Money.format(abs(entry.amountMinorUnits), currency: .gbp)
        if entry.frequency == .once { return "\(amount) one-off on \(shortDayMonthYear.string(from: entry.startDate))" }
        var line = "\(amount) \(frequency(entry.frequency, interval: entry.interval).lowercased()) from \(shortMonthYear.string(from: entry.startDate))"
        if let end = entry.endDate { line += " until \(shortMonthYear.string(from: end))" }
        return line
    }

    /// A plan edit's error in words, for the sheets (budget and scenario edits alike).
    static func errorMessage(for error: Error) -> String {
        switch error {
        case PlannedItemEditError.occurrenceConfirmed: return "This occurrence has already happened."
        case PlannedItemEditError.invalidDate: return "Pick a date in an open month."
        case PlannedItemEditError.frequencyNeedsFollowing: return "A frequency change applies to this and all following occurrences."
        case PlannedItemEditError.invalidInterval: return "Repeat every 1 or more."
        case PlannedItemEditError.notFound: return "This planned item no longer exists."
        case PlannedItemsError.reservedCategory: return "Reserves get allowances from the Reserved section, not planned items."
        case PlannedItemsError.categoryNotFound: return "That category no longer exists."
        case PlannedItemsError.plannedGroupDisabled: return "The budget's “Planned” group is switched off. Add a planned item in the Budget grid to switch it back on."
        case ReservedCategoryError.reservedGroupDisabled: return "The budget's “Reserved” group is switched off, so a scenario allowance would count for nothing."
        case ReservedCategoryError.notReserved: return "That category isn't a reserve."
        case PlannedItemsError.emptyCategoryName, ReservedCategoryError.emptyName, ScenarioError.emptyName: return "Enter a name."
        case PlannedItemsError.duplicateCategoryName, ReservedCategoryError.duplicateName: return "A category with that name already exists."
        case ScenarioError.duplicateName: return "A scenario with that name already exists."
        case ScenarioError.notFound: return "This scenario no longer exists."
        case ScenarioApplyError.nothingToUndo: return "There's no apply to undo."
        case ScenarioApplyError.notADifference: return "One of the ticked items is no longer a difference. Refresh the list and try again."
        default: return "Couldn't save: \(error.localizedDescription)"
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

/// One planned occurrence in a drill-down, with whether it can still be edited
/// (`PlannedItemEditing.isLocked`: confirmed in the budget, a closed month in a scenario)
/// and its series.
struct PlannedRow: Identifiable {
    let occurrence: PlannedOccurrence
    let isConfirmed: Bool
    let entry: ForecastEntry
    var id: String { occurrence.id }

    /// The occurrences of `plan` (a plan's effective entries, `ForecastCalculator.planEntries`)
    /// filed under `categoryId` (after any re-file) whose date falls in the calendar month
    /// `year`/`month`, each with `isLocked`.
    static func rows(categoryId: Int64, year: Int, month: Int, plan: [ForecastEntry], exceptions: [PlannedOccurrenceException], isLocked: (ForecastEntry, PlannedOccurrence) -> Bool) -> [PlannedRow] {
        let range = MonthRange.of(year: year, month: month)
        let byId = Dictionary(plan.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        return PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: PayPeriod(startDate: range.start, endDate: range.end, type: .projected))
            .filter { $0.categoryId == categoryId }
            .compactMap { occurrence in
                guard let entry = byId[occurrence.entryId] else { return nil }
                return PlannedRow(occurrence: occurrence, isConfirmed: isLocked(entry, occurrence), entry: entry)
            }
    }
}

/// The two occurrence edits, bound to a plan's view model (`PlannedItemEditing`; the entry
/// decides whether the budget or a scenario is edited).
struct PlanEditActions {
    let editOccurrence: (PlannedOccurrence, OccurrenceChange) -> SaveOutcome
    let editFollowing: (PlannedOccurrence, OccurrenceChange) -> SaveOutcome

    func save(_ row: PlannedRow, _ change: OccurrenceChange, _ scope: PlanEditScope) -> SaveOutcome {
        switch scope {
        case .onlyThis: return editOccurrence(row.occurrence, change)
        case .thisAndFollowing: return editFollowing(row.occurrence, change)
        }
    }
}

/// The "Planned" list's Edit… sheet and Remove… dialog, shared by the Budget grid's and the
/// scenario grid's drill-downs: `editing` / `removing` open them; a failed remove lands in
/// `planError` (a failed edit shows in its own sheet).
struct PlannedOccurrenceEditing: ViewModifier {
    @Binding var editing: PlannedRow?
    @Binding var removing: PlannedRow?
    @Binding var planError: String?
    let categories: [Category]
    let actions: PlanEditActions

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { row in
                EditOccurrenceSheet(row: row, categories: categories) { change, scope in actions.save(row, change, scope) }
            }
            .confirmationDialog("Remove this planned occurrence?", isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ), presenting: removing) { row in
                Button("Only this occurrence", role: .destructive) { remove(row, .onlyThis) }
                Button("This and all following", role: .destructive) { remove(row, .thisAndFollowing) }
                Button("Cancel", role: .cancel) { removing = nil }
            }
    }

    private func remove(_ row: PlannedRow, _ scope: PlanEditScope) {
        let outcome = actions.save(row, OccurrenceChange(remove: true), scope)
        removing = nil
        if case .failed(let message) = outcome { planError = message }
    }
}

extension View {
    func plannedOccurrenceEditing(editing: Binding<PlannedRow?>, removing: Binding<PlannedRow?>, planError: Binding<String?>, categories: [Category], actions: PlanEditActions) -> some View {
        modifier(PlannedOccurrenceEditing(editing: editing, removing: removing, planError: planError, categories: categories, actions: actions))
    }
}

/// The drill-down's "Planned" list for one category and calendar month: each occurrence's
/// date, amount, frequency and whether it's confirmed. Unconfirmed occurrences offer Edit…
/// and Remove…; the drill-down sheet owns the sheets and dialogs those open
/// (`plannedOccurrenceEditing`).
struct PlannedOccurrencesSection: View {
    let rows: [PlannedRow]
    /// A scenario's occurrences are only locked by a closed month: labelled "Open" /
    /// "Closed month" rather than "Unconfirmed" / "Confirmed".
    var inScenario = false
    let errorMessage: String?
    let onEdit: (PlannedRow) -> Void
    let onRemove: (PlannedRow) -> Void

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
                    Text(inScenario ? (row.isConfirmed ? "Closed month" : "Open") : (row.isConfirmed ? "Confirmed" : "Unconfirmed"))
                        .font(.caption)
                        .italic(!row.isConfirmed)
                        .foregroundStyle(row.isConfirmed ? Color.secondary : Color.pending)
                        .frame(width: 90, alignment: .trailing)
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
    let row: PlannedRow
    let categories: [Category]
    let onSave: (OccurrenceChange, PlanEditScope) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    /// Local midnight of the picked day (a `DatePicker` works in the local time zone).
    @State private var pickedDay: Date
    @State private var categoryId: Int64
    @State private var frequency: ForecastFrequency
    @State private var interval: Int
    @State private var endMode: RecurrenceEndMode
    @State private var occurrenceCount = 12
    /// Local midnight of the picked end day.
    @State private var endDay: Date
    @State private var choosingScope = false
    @State private var errorMessage: String?

    init(row: PlannedRow, categories: [Category], onSave: @escaping (OccurrenceChange, PlanEditScope) -> SaveOutcome) {
        self.row = row
        self.categories = categories
        self.onSave = onSave
        _amountText = State(initialValue: Money.formatInput(abs(row.occurrence.amountMinorUnits)))
        _pickedDay = State(initialValue: PayCalendar.localDay(sameDayAs: row.occurrence.date, in: .current))
        _categoryId = State(initialValue: row.occurrence.categoryId)
        _frequency = State(initialValue: row.entry.frequency)
        _interval = State(initialValue: row.entry.interval)
        _endMode = State(initialValue: row.entry.endDate == nil ? .never : .onDate)
        _endDay = State(initialValue: PayCalendar.localDay(sameDayAs: row.entry.endDate ?? row.occurrence.date, in: .current))
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

    /// The anchor day the new series would inherit (as `PlannedItemEditing.editFollowing`):
    /// kept only between day-of-month schedules when the date doesn't move.
    private var inheritedAnchorDay: Int? {
        let dayOfMonth: Set<ForecastFrequency> = [.monthly, .annually]
        guard pickedDate == row.occurrence.date, dayOfMonth.contains(row.entry.frequency), dayOfMonth.contains(frequency) else { return nil }
        return row.entry.anchorDay ?? MonthRange.calendar.component(.day, from: row.entry.startDate)
    }

    /// The Nth occurrence counted from the new series' start: the occurrence's original date
    /// unless the date is moved (exactly the start `PlannedItemEditing.editFollowing` uses).
    private var lastDate: Date {
        let start = pickedDate == row.occurrence.date ? row.occurrence.originalDate : pickedDate
        return RecurrenceEnd.endDate(start: start, frequency: frequency, interval: interval, anchorDay: inheritedAnchorDay, occurrences: RecurrenceEndFields.clamped(occurrenceCount))
    }

    /// The series' end after the edit, as an `OccurrenceChange.endDate` (nil = unchanged).
    private var endChange: Date?? {
        guard frequency != .once else { return nil }
        let resolved = RecurrenceEndFields.resolve(mode: endMode, endDay: endDay, count: occurrenceCount, lastDate: lastDate)
        guard let current = row.entry.endDate else { return resolved.map { .some($0) } }
        guard let resolved else { return .some(nil) }
        // Same UTC day counts as unchanged (the stored end may be midnight or end of day).
        return MonthRange.calendar.isDate(resolved, inSameDayAs: current) ? nil : .some(resolved)
    }

    /// Only what changed; nil fields stay as they are.
    private var change: OccurrenceChange? {
        guard let signedAmount else { return nil }
        var change = OccurrenceChange()
        if signedAmount != row.occurrence.amountMinorUnits { change.amountMinorUnits = signedAmount }
        if pickedDate != row.occurrence.date { change.date = pickedDate }
        if categoryId != row.occurrence.categoryId { change.categoryId = categoryId }
        if frequency != row.entry.frequency { change.frequency = frequency }
        if interval != row.entry.interval { change.interval = interval }
        if let endChange { change.endDate = endChange }
        return change == OccurrenceChange() ? nil : change
    }

    /// A frequency, interval or end change applies to the series, so only "This and all following".
    private var changesFrequency: Bool { frequency != row.entry.frequency || interval != row.entry.interval || endChange != nil }

    var body: some View {
        Form {
            Text("Edit planned occurrence").font(.headline)
            MoneyField("Amount", text: $amountText, currency: .gbp)
            DatePicker("Date", selection: $pickedDay, displayedComponents: .date)
            Picker("Category", selection: $categoryId) {
                ForEach(pickerCategories) { category in Text(category.name).tag(category.id!) }
            }
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in
                    Text(freq == .once ? "One-off (ends the series here)" : PlanFormat.frequency(freq, interval: 1)).tag(freq)
                }
            }
            if frequency != .once {
                Stepper("Every \(interval) \(PlanFormat.unit(frequency, interval: interval))", value: $interval, in: 1...12)
            }
            if frequency != .once {
                RecurrenceEndFields(mode: $endMode, endDay: $endDay, count: $occurrenceCount, startDay: pickedDay, lastDate: lastDate)
            }
            if changesFrequency {
                Text("A frequency or end change applies to this and all following occurrences.")
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
        .onChange(of: endMode) { _, _ in errorMessage = nil }
        .onChange(of: endDay) { _, _ in errorMessage = nil }
        .onChange(of: occurrenceCount) { _, _ in errorMessage = nil }
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

/// The category a new planned item goes to: an existing one, or one created with it.
enum PlannedItemCategory {
    case existing(Int64)
    case new(name: String)
}

/// "+ Add planned item" from an Income / Expenses / Transfers header (the Budget grid, or a
/// scenario's grid in the lab): a category of that
/// section (or "+ New category…" of the section's type, created with the item), an amount, one-off or recurring (weekly / monthly / annually, every N), a start
/// and an optional end. Saved through `PlannedItems.add`; errors show inline. Once a
/// category is picked, its existing planned series are listed: the new item adds to them
/// (nothing is replaced), so a category planned twice is visible before saving.
struct AddPlannedItemSheet: View {
    let type: CategoryType
    /// The budget, or the scenario the item is added to (named in the title).
    let scope: PlanScope
    let categories: [Category]
    /// The scope's planned items (`ForecastCalculator.planEntries`), for the "Already planned" lines.
    let plannedEntries: [ForecastEntry]
    let onSave: (PlannedItemCategory, _ amountMinorUnits: Int, ForecastFrequency, _ interval: Int, _ start: Date, _ end: Date?) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    /// Sentinel for "+ New category…" (real ids are positive rowids).
    private static let newCategorySentinel: Int64 = -1

    @State private var categoryId: Int64?
    @State private var newCategoryName = ""
    @State private var amountText = ""
    @State private var isRecurring = true
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var endMode: RecurrenceEndMode = .never
    @State private var occurrenceCount = 12
    @State private var endDay = PayCalendar.localDay(sameDayAs: PayCalendar.utcDay(sameDayAs: Date(), in: .current), in: .current)
    @State private var errorMessage: String?

    /// The date of the Nth occurrence for "After N", from the picked start.
    private var lastDate: Date {
        RecurrenceEnd.endDate(start: PayCalendar.utcDay(sameDayAs: startDay, in: .current), frequency: frequency, interval: interval, anchorDay: nil, occurrences: RecurrenceEndFields.clamped(occurrenceCount))
    }

    private var pickerCategories: [Category] {
        categories.filter { $0.type == type && !$0.isReserved && $0.isAssignable }.sorted { $0.name < $1.name }
    }

    private var title: String {
        let base: String
        switch type {
        case .income: base = "Add planned income"
        case .expense: base = "Add planned expense"
        case .transfer: base = "Add planned transfer"
        }
        if case .scenario(_, let name) = scope { return "\(base) to “\(name)”" }
        return base
    }

    /// Income inward (positive); expenses and transfers outward (negative), as the Forecast
    /// screen's planned items always were.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountText), minorUnits != 0 else { return nil }
        return type == .income ? abs(minorUnits) : -abs(minorUnits)
    }

    private var isCreatingNewCategory: Bool { categoryId == Self.newCategorySentinel }

    private var category: PlannedItemCategory? {
        guard let categoryId else { return nil }
        guard isCreatingNewCategory else { return .existing(categoryId) }
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : .new(name: name)
    }

    private var canSave: Bool { category != nil && signedAmount != nil }

    /// The picked existing category's planned series, oldest first.
    private var alreadyPlanned: [ForecastEntry] {
        guard let categoryId, !isCreatingNewCategory else { return [] }
        return plannedEntries.filter { $0.categoryId == categoryId }.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        Form {
            Text(title).font(.headline)
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(pickerCategories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
                Text("+ New category…").tag(Int64?.some(Self.newCategorySentinel))
            }
            if isCreatingNewCategory {
                // Created together with the item on Save, in the same write — Cancel or a
                // failed save leaves no orphaned category behind.
                TextField("New category name", text: $newCategoryName)
            }
            if !alreadyPlanned.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(alreadyPlanned) { entry in
                        Text("Already planned: \(PlanFormat.series(entry))").font(.callout)
                    }
                    Text("This adds to what's already planned. To change an existing item, edit it from the grid.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                RecurrenceEndFields(mode: $endMode, endDay: $endDay, count: $occurrenceCount, startDay: startDay, lastDate: lastDate)
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
        .onChange(of: newCategoryName) { _, _ in errorMessage = nil }
        .onChange(of: endMode) { _, _ in errorMessage = nil }
        .onChange(of: endDay) { _, _ in errorMessage = nil }
        .onChange(of: occurrenceCount) { _, _ in errorMessage = nil }
        .padding()
        .frame(width: 420)
    }

    private func save() {
        guard let category, let amount = signedAmount else { return }
        let start = PayCalendar.utcDay(sameDayAs: startDay, in: .current)
        let end = isRecurring ? RecurrenceEndFields.resolve(mode: endMode, endDay: endDay, count: occurrenceCount, lastDate: lastDate) : nil
        switch onSave(category, amount, isRecurring ? frequency : .once, isRecurring ? interval : 1, start, end) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}
