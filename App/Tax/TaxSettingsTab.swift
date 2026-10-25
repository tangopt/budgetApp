// App/Tax/TaxSettingsTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The year's settings (UI polish §4.2): the HMRC average rate (with where it came from as a
/// pill; fetch, or enter by hand) beside the person's share and splits; the attribution rules
/// and the category → tax line map as tables, an edit icon or a picker per row.
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
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if page.property != nil {
                // Side by side while the rate's two buttons fit beside its title.
                SplitRow(ratio: 0.5, stackBelow: 900) {
                    ratePanel
                    splitsPanel
                }
            } else {
                ratePanel
            }
            rulesPanel
            if page.property != nil {
                typesPanel
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

    // MARK: Rate

    private var ratePanel: some View {
        Panel("HMRC average rate", subtitle: "For the year to 31 March \(String(page.row.year.startYear + 1))", fillsHeight: true) {
            HStack(spacing: 6) {
                if viewModel.isFetchingRate { ProgressView().controlSize(.small) }
                Button("Fetch from HMRC") { viewModel.fetchRate(replace: false) }
                    .disabled(viewModel.selectedYearIsFiled)
                    .help(viewModel.selectedYearIsFiled
                          ? "\(page.row.year.label) is filed: HMRC's rate isn't fetched for it, so its figures stay as filed"
                          : "HMRC's average for the year to 31 March; keeps a rate entered by hand or from a filed return")
                Button("Enter by hand…") { editingRate = true }
            }
            .controlSize(.small)
        } content: {
            if page.rates.isEmpty {
                Text(viewModel.selectedYearIsFiled
                     ? "No rate for \(page.row.year.label): it's filed, so HMRC's average isn't fetched for it. Enter the rate the return used by hand."
                     : "No rate for \(page.row.year.label) yet: fetch HMRC's average, or enter it by hand.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(page.rates.enumerated()), id: \.element.currencyCode) { index, rate in
                        if index > 0 { Divider() }
                        rateFacts(rate)
                    }
                }
            }
        }
    }

    private func rateFacts(_ rate: HMRCRate) -> some View {
        let pill = TaxFormat.sourcePill(rate)
        return PropertyFacts {
            PropertyFact(page.rates.count > 1 ? "Rate (\(rate.currencyCode))" : "Rate") {
                HStack(spacing: 8) {
                    Text(TaxFormat.unitsPerPound(rate)).monospacedDigit().fontWeight(.semibold).figureText()
                    Spacer(minLength: 8)
                    // The same remove icon as the splits beside it.
                    Button(role: .destructive) { viewModel.removeRate(currencyCode: rate.currencyCode) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the \(rate.currencyCode) rate")
                    .accessibilityLabel("Remove the \(rate.currencyCode) rate")
                }
            }
            PropertyFact("In pounds") {
                Text(TaxFormat.poundsPerUnit(rate)).monospacedDigit().foregroundStyle(.secondary).figureText()
            }
            PropertyFact("Source") {
                HStack(spacing: 6) {
                    StatusPill(pill.title, tone: pill.tone, systemImage: pill.systemImage, help: rate.notes)
                    if let fetched = rate.fetchedAt {
                        Text("on \(DocumentFormat.day(fetched))").font(.caption).foregroundStyle(.secondary).figureText()
                    }
                }
            }
        }
    }

    // MARK: Share and splits

    private var splitsPanel: some View {
        Panel("\(page.row.person.name)'s share", subtitle: "A split overrides the ownership share for this year", fillsHeight: true) {
            Button("Add split…") { editingSplit = SplitDraft(expenseType: nil, shareBasisPoints: nil) }
                .controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                PropertyFacts {
                    PropertyFact("Ownership") {
                        HStack(spacing: 6) {
                            Text(PropertyFormat.percent(page.ownershipShareBasisPoints)).monospacedDigit().fontWeight(.semibold).figureText()
                            Text("over the year, weighted by days owned").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if page.splits.isEmpty {
                    Text("No splits: every line takes the ownership share.").font(.callout).foregroundStyle(.secondary)
                } else {
                    DataTable(columns: [
                        .text("Applies to", { $0.expenseType?.displayName ?? "Every type" }),
                        DataTableColumn("Share", alignment: .trailing, width: .min(56),
                                        accessibilityValue: { PropertyFormat.percent($0.shareBasisPoints) }) { split, _ in
                            Text(PropertyFormat.percent(split.shareBasisPoints)).monospacedDigit().figureText()
                        },
                        .actions { split in
                            let name = split.expenseType?.displayName ?? "every type"
                            return [
                                DataTableAction("Edit the split for \(name)", systemImage: "pencil", inline: true) {
                                    editingSplit = SplitDraft(expenseType: split.expenseType, shareBasisPoints: split.shareBasisPoints)
                                },
                                DataTableAction("Remove the split for \(name)", systemImage: "xmark.circle", inline: true) {
                                    viewModel.setSplit(expenseType: split.expenseType, shareBasisPoints: nil)
                                }
                            ]
                        }
                    ], rows: page.splits.map(SplitEntry.init), zebra: false)
                }
            }
        }
    }

    /// A split as a table row.
    private struct SplitEntry: Identifiable {
        let id: String
        let expenseType: TaxExpenseType?
        let shareBasisPoints: Int

        init(_ split: TaxYearSplit) {
            id = split.expenseType?.rawValue ?? "all"
            expenseType = split.expenseType
            shareBasisPoints = split.shareBasisPoints
        }
    }

    // MARK: Rules

    private var rulesPanel: some View {
        Panel("Attribution rules", subtitle: "How each tax line's payments are attributed to a tax year") {
            DataTable(columns: [
                .text("Tax line", width: .fit, { $0.expenseType.displayName }),
                DataTableColumn("Rule", width: .fill(min: 200), accessibilityValue: { ruleText($0) }) { row, _ in
                    HStack(spacing: 4) {
                        Text(row.rule.displayName).lineLimit(1)
                        if row.rule == .apportionByCover {
                            // The rule's name truncates first; the months stay whole.
                            Text("· \(row.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths) months if the cover is unknown")
                                .foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                        }
                        if row.windowShiftMonths != 0 {
                            Text("· \(windowText(row))").foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                        }
                    }
                },
                // The exception (this year only) as a pill; the usual scopes as plain words.
                DataTableColumn("Applies", accessibilityValue: { scopeText($0.scope) }) { row, _ in
                    if row.scope == .thisYear {
                        StatusPill(scopeText(row.scope), tone: .accent, help: "Changed for this year only: other years keep their rule")
                    } else {
                        Text(scopeText(row.scope)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .help(row.scope == .builtIn ? "The built-in rule" : "Changed for every year")
                    }
                },
                .actions { row in
                    [DataTableAction("Change the rule for \(row.expenseType.displayName)", systemImage: "pencil", inline: true) { editingRule = row }]
                }
            ], rows: page.rules)
        }
    }

    // MARK: Categories → tax lines

    private var typesPanel: some View {
        Panel("Categories → tax lines", subtitle: "The tax line each of the property's categories feeds") {
            if page.categoryTypes.contains(where: { !$0.isStored && !TaxExpenseTypeMap.needsReview($0.category.name) }) {
                Button("Confirm suggestions") { viewModel.confirmSuggestedTypes() }
                    .controlSize(.small)
                    .help("Store the types suggested from the category names")
            }
        } content: {
            if page.categoryTypes.isEmpty {
                Text("No categories yet: link the property's category groups in Property › Profile.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: [
                    .text("Category", width: .min(170), { $0.category.name }),
                    // No accessibility value: the picker stays its own element, so VoiceOver reaches it.
                    DataTableColumn("Tax line", width: .fill(min: 240)) { entry, _ in
                        Picker("Tax line for \(entry.category.name)", selection: Binding(
                            get: { entry.expenseType },
                            set: { viewModel.setCategoryType(categoryId: entry.category.id!, $0) })) {
                            ForEach(TaxExpenseType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    },
                    .status("") { entry -> StatusPill? in
                        if entry.isStored { return nil }
                        if TaxExpenseTypeMap.needsReview(entry.category.name) {
                            return StatusPill("Check: capital and interest", tone: .warning,
                                              help: "A loan instalment mixes capital and interest: only the interest is a finance cost")
                        }
                        return StatusPill("Suggested", help: "Suggested from the category's name; Confirm suggestions stores it")
                    }
                ], rows: page.categoryTypes.map(TypeRow.init))
            }
        }
    }

    /// A category's entry as a table row.
    private struct TypeRow: Identifiable {
        let entry: TaxExpenseTypeMap.Entry
        var id: Int64 { entry.category.id ?? 0 }
        var category: Category { entry.category }
        var expenseType: TaxExpenseType { entry.expenseType }
        var isStored: Bool { entry.isStored }

        init(_ entry: TaxExpenseTypeMap.Entry) { self.entry = entry }
    }

    private func scopeText(_ scope: TaxOverview.RuleScope) -> String {
        switch scope {
        case .builtIn: return "Default"
        case .allYears: return "Every year"
        case .thisYear: return "\(page.row.year.label) only"
        }
    }

    private func ruleText(_ row: TaxOverview.RuleRow) -> String {
        var text = row.rule.displayName
        if row.rule == .apportionByCover {
            text += " (\(row.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths) months if unknown)"
        }
        if row.windowShiftMonths != 0 { text += ", \(windowText(row))" }
        return text
    }

    /// "window Oct 2022 – Sep 2023, as filed": the year's moved window.
    private func windowText(_ row: TaxOverview.RuleRow) -> String {
        "window \(RentalAccounts.windowLabel(page.row.year, shift: row.windowShiftMonths)), as filed"
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
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()

    private var value: Double? { Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        SheetScaffold(title: "HMRC average rate · \(year.label)", subtitle: "Euros per £1, as HMRC publishes it. It replaces the rate fetched or taken from a filed return.",
                      error: error, width: SheetMetrics.compactWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: (value ?? 0) > 0) {
                          guard let value else { return }
                          viewModel.setRate(currencyCode: "EUR", unitsPerPound: value, gate: gate) { message in
                              error = message
                              if message == nil { dismiss() }
                          }
                      }) {
            SheetForm {
                LabeledContent("EUR per £1") {
                    TextField("EUR per £1", text: $text, prompt: Text("1.1880"))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 120)
                }
                if let value, value > 0 {
                    SheetFormNote(String(format: "£%.6f per euro", 1 / value))
                }
            }
        }
        .onAppear { if let current { text = String(format: "%.4f", current.unitsPerPound ?? 1 / current.gbpPerUnit) } }
        .filedYearGate(gate)
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
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()

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
        SheetScaffold(title: "Split · \(page.row.year.label)", subtitle: page.row.person.name, error: error, width: SheetMetrics.compactWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction(existing == nil ? "Save" : "Replace", isEnabled: basisPoints != nil) {
                          viewModel.setSplit(expenseType: expenseType, shareBasisPoints: basisPoints, gate: gate) { message in
                              error = message
                              if message == nil { dismiss() }
                          }
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
                LabeledContent("Share") {
                    HStack(spacing: 4) {
                        TextField("Share", text: $percent, prompt: Text("50"))
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                            .accessibilityLabel("Share percent")
                        Text("%").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .sheetFieldNote("Ownership is \(PropertyFormat.percent(page.ownershipShareBasisPoints)) over the year.")
                }
            }
            if let existing {
                InlineBanner(.warning, "There's already a \(PropertyFormat.percent(existing.shareBasisPoints)) split for this: Replace changes it.")
            }
        }
        .onAppear {
            expenseType = draft.expenseType
            percent = draft.shareBasisPoints.map { String(format: "%g", Double($0) / 100) } ?? ""
        }
        .filedYearGate(gate)
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
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()

    var body: some View {
        SheetScaffold(title: row.expenseType.displayName, subtitle: "Its attribution rule: how its payments count towards a tax year.",
                      error: error, width: SheetMetrics.compactWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save") {
                          viewModel.setRule(row.expenseType, rule: rule, thisYearOnly: thisYearOnly,
                                            coverMonths: rule == .apportionByCover ? coverMonths : nil, gate: gate) { message in
                              error = message
                              if message == nil { dismiss() }
                          }
                      },
                      destructive: row.scope == .builtIn ? nil : SheetAction(row.scope == .thisYear ? "Remove override" : "Back to default") {
                          viewModel.setRule(row.expenseType, rule: nil, thisYearOnly: row.scope == .thisYear, coverMonths: nil,
                                            gate: gate) { message in
                              error = message
                              if message == nil { dismiss() }
                          }
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
                        ValueStepper("Cover if unknown", value: $coverMonths, in: 1...36, text: ValueStepper.months)
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
        .filedYearGate(gate)
    }
}
