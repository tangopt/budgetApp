// App/Forecast/ForecastComparisonView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastComparisonView: View {
    @ObservedObject var viewModel: ForecastViewModel
    let categories: [Category]

    @State private var showNewEntrySheet = false
    @State private var editingEntry: ForecastEntry?

    private var futurePeriods: [PayPeriod] {
        viewModel.periods.filter { $0.type == .projected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            groupsSection
            Button("Add hypothetical forecast entry…") { showNewEntrySheet = true }
            Divider()
            comparisonTable
        }
        .padding()
        .sheet(isPresented: $showNewEntrySheet) {
            NewForecastEntryView(categories: categories) { newGroupName, categoryId, amountMinorUnits, frequency, interval, startDate in
                viewModel.addHypotheticalEntry(groupName: newGroupName, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate)
                showNewEntrySheet = false
            }
        }
        .sheet(item: $editingEntry) { entry in
            // Save closes the sheet here (success or failure — a failure's errorMessage
            // shows above the comparison table, which is hidden while the sheet is up);
            // Cancel closes it via EditForecastEntryView's own dismiss().
            EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval in
                viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval)
                editingEntry = nil
            }
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading) {
            Text("Forecast groups").font(.headline)
            ForEach(viewModel.groups) { group in
                HStack {
                    Toggle(group.name, isOn: Binding(
                        get: { group.isEnabled },
                        set: { _ in viewModel.toggleGroup(group) }
                    ))
                    if !group.isSystemManaged {
                        Text("custom").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                    HStack {
                        Toggle(categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { _ in viewModel.toggleEntry(entry) }
                        ))
                        .padding(.leading, 24)
                        Text(entry.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        Button("Edit…") { editingEntry = entry }
                            .buttonStyle(.plain)
                            .font(.caption)
                        if entry.status == .hypothetical {
                            Button("Confirm") { viewModel.confirm(entry) }
                        } else if entry.status == .confirmed {
                            Button("Un-confirm") { viewModel.unconfirm(entry) }
                        }
                    }
                }
            }
        }
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading) {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("Confirmed vs. Preview forecast").font(.headline)
                Spacer()
                Text("Through \(viewModel.horizon.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Extend to next year") { viewModel.extendHorizonToNextYear() }
                    .font(.caption)
            }
            ForEach(futurePeriods, id: \.startDate) { period in
                VStack(alignment: .leading) {
                    Text(period.startDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).bold()
                    ForEach(categories) { category in
                        let confirmed = viewModel.confirmedTotal(categoryId: category.id!, period: period)
                        let preview = viewModel.previewTotal(categoryId: category.id!, period: period)
                        if confirmed != 0 || preview != 0 {
                            HStack {
                                Text(category.name)
                                Spacer()
                                MoneyText(minorUnits: confirmed)
                                MoneyText(minorUnits: preview)
                                    .overlay(alignment: .topTrailing) {
                                        if preview != confirmed {
                                            Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 4, y: -2)
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

struct NewForecastEntryView: View {
    let categories: [Category]
    let onSave: (String, Int64, Int, ForecastFrequency, Int, Date) -> Void

    @State private var groupName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()

    var body: some View {
        Form {
            TextField("Group name", text: $groupName)
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Button("Save") {
                guard let categoryId, let pounds = Double(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = Int(pounds * 100) * (category?.type == .income ? 1 : -1)
                onSave(groupName, categoryId, signedMinorUnits, frequency, interval, startDate)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct EditForecastEntryView: View {
    let entry: ForecastEntry
    let onSave: (Int, ForecastFrequency, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amountPounds: String
    @State private var frequency: ForecastFrequency
    @State private var interval: Int

    init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _amountPounds = State(initialValue: String(format: "%.2f", Double(abs(entry.amountMinorUnits)) / 100))
        _frequency = State(initialValue: entry.frequency)
        _interval = State(initialValue: entry.interval)
    }

    /// Preserves the entry's existing sign (income positive, everything else negative) —
    /// the field only ever asks for a positive magnitude. nil if the field doesn't parse.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return nil }
        return entry.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    /// Save is a no-op unless something actually changed: saving an untouched `.auto`
    /// entry would otherwise promote it to `.manual` (via `updateEntry`) and permanently
    /// opt that category out of `AutoForecastGenerator.refresh` for no reason.
    private var hasChanges: Bool {
        guard let signedAmount else { return false }
        return signedAmount != entry.amountMinorUnits || frequency != entry.frequency || interval != entry.interval
    }

    var body: some View {
        Form {
            TextField("Amount (£)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard hasChanges, let signedAmount else { return }
                    onSave(signedAmount, frequency, interval)
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
