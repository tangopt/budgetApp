// App/Tax/TaxSettingsTab.swift
import SwiftUI
import BudgetCore

/// The year's settings: the HMRC average rate (fetch, or enter by hand), the person's splits,
/// the attribution rules (every year, or this year only) and the category → tax type map.
struct TaxSettingsTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var editingRate = false
    @State private var editingSplit: SplitDraft?
    @State private var editingRule: TaxOverview.RuleRow?

    struct SplitDraft: Identifiable {
        let id = UUID()
        let expenseType: TaxExpenseType?
        let shareBasisPoints: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            rateSection
            if page.property != nil {
                splitsSection
            }
            rulesSection
            if page.property != nil {
                typesSection
            }
        }
        .sheet(isPresented: $editingRate) {
            TaxRateSheet(viewModel: viewModel, year: page.row.year, current: page.rates.first { $0.currencyCode == "EUR" })
        }
        .sheet(item: $editingSplit) { draft in
            TaxSplitSheet(viewModel: viewModel, page: page, draft: draft)
        }
        .sheet(item: $editingRule) { row in
            TaxRuleSheet(viewModel: viewModel, year: page.row.year, row: row)
        }
    }

    private var rateSection: some View {
        PropertySection("HMRC average rate") {
            VStack(alignment: .leading, spacing: 8) {
                if page.rates.isEmpty {
                    Text("No rate for \(page.row.year.label) yet.").foregroundStyle(.secondary)
                }
                ForEach(page.rates, id: \.currencyCode) { rate in
                    HStack {
                        Text(TaxFormat.rate(rate)).monospacedDigit()
                        Text(TaxFormat.source(of: rate)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { viewModel.removeRate(currencyCode: rate.currencyCode) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove the \(rate.currencyCode) rate")
                    }
                }
                HStack {
                    Button("Fetch from HMRC") { viewModel.fetchRate(replace: false) }
                        .help("HMRC's average for the year to 31 March; keeps a rate entered by hand or from a filed return")
                    Button("Enter by hand…") { editingRate = true }
                    if viewModel.isFetchingRate { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var splitsSection: some View {
        PropertySection("\(page.row.person.name)'s share", accessory: {
            Button("Add split…") { editingSplit = SplitDraft(expenseType: nil, shareBasisPoints: nil) }
                .buttonStyle(.borderless)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ownership over the year (weighted by days owned): \(PropertyFormat.percent(page.ownershipShareBasisPoints)). A split overrides it for this year.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(page.splits, id: \.id) { split in
                    HStack {
                        Text(split.expenseType?.displayName ?? "Every type")
                        Text(PropertyFormat.percent(split.shareBasisPoints)).monospacedDigit()
                        Spacer()
                        Button("Edit…") { editingSplit = SplitDraft(expenseType: split.expenseType, shareBasisPoints: split.shareBasisPoints) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit the split for \(split.expenseType?.displayName ?? "every type")")
                        Button("Remove") {
                            viewModel.errorMessage = viewModel.setSplit(expenseType: split.expenseType, shareBasisPoints: nil)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove the split for \(split.expenseType?.displayName ?? "every type")")
                    }
                }
            }
        }
    }

    private var rulesSection: some View {
        PropertySection("Attribution rules") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(page.rules) { row in
                    GridRow {
                        Text(row.expenseType.displayName).lineLimit(1)
                        Text(ruleText(row)).lineLimit(1)
                        Text(scopeText(row.scope)).foregroundStyle(.secondary).lineLimit(1)
                        Button("Change…") { editingRule = row }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Change the rule for \(row.expenseType.displayName)")
                    }
                }
            }
        }
    }

    private var typesSection: some View {
        PropertySection("Categories → tax lines", accessory: {
            if page.categoryTypes.contains(where: { !$0.isStored && !TaxExpenseTypeMap.needsReview($0.category.name) }) {
                Button("Confirm suggestions") { viewModel.confirmSuggestedTypes() }
                    .buttonStyle(.borderless)
                    .help("Store the types suggested from the category names")
            }
        }) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(page.categoryTypes, id: \.category.id) { entry in
                    GridRow {
                        Text(entry.category.name).lineLimit(1)
                        Picker("Tax line for \(entry.category.name)", selection: Binding(
                            get: { entry.expenseType },
                            set: { viewModel.setCategoryType(categoryId: entry.category.id!, $0) })) {
                            ForEach(TaxExpenseType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text(entry.isStored ? "" : TaxExpenseTypeMap.needsReview(entry.category.name) ? "check: capital and interest" : "suggested")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ruleText(_ row: TaxOverview.RuleRow) -> String {
        if row.rule == .apportionByCover {
            return "\(row.rule.displayName) (\(row.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths) months if unknown)"
        }
        return row.rule.displayName
    }

    private func scopeText(_ scope: TaxOverview.RuleScope) -> String {
        switch scope {
        case .builtIn: return "default"
        case .allYears: return "every year"
        case .thisYear: return "this year only"
        }
    }
}

/// Enter the year's EUR rate as HMRC publishes it (euros per £1).
struct TaxRateSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let year: UKTaxYear
    let current: HMRCRate?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    private var value: Double? { Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        SheetScaffold(title: "HMRC average rate · \(year.label)", subtitle: "Euros per £1, as HMRC publishes it (e.g. 1.1880). It replaces a fetched or filed-return rate.",
                      error: error, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (value ?? 0) > 0) {
                          guard let value else { return }
                          error = viewModel.setRate(currencyCode: "EUR", unitsPerPound: value)
                          if error == nil { dismiss() }
                      }) {
            SheetForm {
                LabeledContent("EUR per £1") {
                    TextField("EUR per £1", text: $text).frame(width: 120)
                }
                if let value, value > 0 {
                    SheetFormNote(String(format: "£%.6f per euro", 1 / value))
                }
            }
        }
        .onAppear { if let current { text = String(format: "%.4f", current.unitsPerPound ?? 1 / current.gbpPerUnit) } }
    }
}

/// A split: the person's share of one type (or every type) for the year.
struct TaxSplitSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    let draft: TaxSettingsTab.SplitDraft
    @Environment(\.dismiss) private var dismiss
    @State private var expenseType: TaxExpenseType?
    @State private var percent = ""
    @State private var error: String?

    /// The split already stored for the chosen type, when adding (Save then replaces it).
    private var existing: TaxYearSplit? {
        guard draft.shareBasisPoints == nil else { return nil }
        return page.splits.first { $0.expenseType == expenseType }
    }

    private var basisPoints: Int? {
        guard let value = Double(percent.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
              (0...100).contains(value) else { return nil }
        return Int((value * 100).rounded())
    }

    var body: some View {
        SheetScaffold(title: "Split · \(page.row.year.label)", subtitle: page.row.person.name, error: error, onCancel: { dismiss() },
                      primary: SheetAction(existing == nil ? "Save" : "Replace", isEnabled: basisPoints != nil) {
                          error = viewModel.setSplit(expenseType: expenseType, shareBasisPoints: basisPoints)
                          if error == nil { dismiss() }
                      }) {
            SheetForm {
                LabeledContent("Applies to") {
                    Picker("Applies to", selection: $expenseType) {
                        Text("Every type").tag(TaxExpenseType?.none)
                        ForEach(TaxExpenseType.allCases, id: \.self) { Text($0.displayName).tag(TaxExpenseType?.some($0)) }
                    }
                    .fixedSize()
                    .disabled(draft.shareBasisPoints != nil)
                }
                LabeledContent("Share (%)") {
                    TextField("Share", text: $percent).frame(width: 80)
                }
                if let existing {
                    SheetFormNote("There's already a \(PropertyFormat.percent(existing.shareBasisPoints)) split for this: Replace changes it.", isError: true)
                }
                SheetFormNote("Ownership is \(PropertyFormat.percent(page.ownershipShareBasisPoints)) over the year.")
            }
        }
        .onAppear {
            expenseType = draft.expenseType
            percent = draft.shareBasisPoints.map { String(format: "%g", Double($0) / 100) } ?? ""
        }
    }
}

/// A type's rule, for every year or this year only.
struct TaxRuleSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let year: UKTaxYear
    let row: TaxOverview.RuleRow
    @Environment(\.dismiss) private var dismiss
    @State private var rule: TaxAttributionRuleKind = .byDate
    @State private var thisYearOnly = false
    @State private var coverMonths = 12
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: row.expenseType.displayName, subtitle: "How its payments are attributed to a tax year.", error: error,
                      onCancel: { dismiss() },
                      primary: SheetAction("Save") {
                          error = viewModel.setRule(row.expenseType, rule: rule, thisYearOnly: thisYearOnly,
                                                    coverMonths: rule == .apportionByCover ? coverMonths : nil)
                          if error == nil { dismiss() }
                      },
                      destructive: row.scope == .builtIn ? nil : SheetAction(row.scope == .thisYear ? "Remove override" : "Back to default") {
                          error = viewModel.setRule(row.expenseType, rule: nil, thisYearOnly: row.scope == .thisYear, coverMonths: nil)
                          if error == nil { dismiss() }
                      }) {
            SheetForm {
                LabeledContent("Rule") {
                    Picker("Rule", selection: $rule) {
                        ForEach(TaxAttributionRuleKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                }
                if rule == .apportionByCover {
                    LabeledContent("Cover if unknown") {
                        Stepper("\(coverMonths) months", value: $coverMonths, in: 1...36)
                    }
                }
                LabeledContent("Applies to") {
                    Picker("Applies to", selection: $thisYearOnly) {
                        Text("Every year").tag(false)
                        Text("\(year.label) only").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
        .onAppear {
            rule = row.rule
            thisYearOnly = row.scope == .thisYear
            coverMonths = row.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths
        }
    }
}
