// App/Forecast/ForecastComparisonView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastComparisonView: View {
    @ObservedObject var viewModel: ForecastViewModel
    let categories: [Category]

    @State private var showNewEntrySheet = false

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
                        if entry.status == .hypothetical {
                            Button("Confirm") { viewModel.confirm(entry) }
                        }
                    }
                }
            }
        }
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading) {
            Text("Confirmed vs. Preview forecast").font(.headline)
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
