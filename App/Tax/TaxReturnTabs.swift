// App/Tax/TaxReturnTabs.swift
import SwiftUI
import BudgetCore

/// The Return, Calculation and Filing tabs of a tax year (plan phase 4 Task 4), laid out from
/// `SelfAssessment.Result` and `SelfAssessmentFiling`.
struct TaxReturnTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage

    var body: some View {
        if let result = page.selfAssessment {
            VStack(alignment: .leading, spacing: 12) {
                TaxSelfAssessmentWarnings(result: result)
                ForEach(Array(result.boxGroups.enumerated()), id: \.offset) { _, group in
                    PropertySection("\(group.form.rawValue) · \(group.section)") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(Array(group.boxes.enumerated()), id: \.offset) { _, box in
                                GridRow {
                                    Text(box.number).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    Text(box.label).lineLimit(2)
                                    TaxBoxValueText(value: box.value).gridColumnAlignment(.trailing)
                                    HStack(spacing: 8) {
                                        Button("Copy") { viewModel.copy(box.copyText) }
                                            .accessibilityLabel("Copy box \(box.number), \(box.label)")
                                        if let step = box.step {
                                            Button("Why?") { viewModel.showStep(step) }
                                                .help("Show the calculation step behind this box")
                                                .accessibilityLabel("Show how box \(box.number) is worked out")
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                Text("Box values are whole pounds, as the return takes them: income rounded down; expenses, tax paid, finance costs and losses rounded up. SA110 keeps pence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            TaxSelfAssessmentUnavailable(page: page)
        }
    }
}

struct TaxBoxValueText: View {
    let value: SelfAssessment.BoxValue

    var body: some View {
        switch value {
        case let .amount(pence): PropertyMoney(minorUnits: pence, currency: .gbp, neutral: true)
        case let .text(text): Text(text).monospacedDigit().lineLimit(1)
        case .cross: Text("X").font(.body.weight(.semibold))
        }
    }
}

struct TaxSelfAssessmentWarnings: View {
    let result: SelfAssessment.Result

    var body: some View {
        if !result.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TaxSelfAssessmentUnavailable: View {
    let page: TaxOverview.YearPage

    var body: some View {
        Text(page.selfAssessmentError ?? "No return to show yet.").foregroundStyle(.secondary)
    }
}

/// The SA110 calculation, step by step; a Return box's "Why?" highlights its step.
struct TaxCalculationTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @Environment(\.theme) private var theme

    var body: some View {
        if let result = page.selfAssessment {
            let c = result.calculation
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    figure("Income Tax due", c.incomeTaxDue)
                    figure("Tax deducted", c.taxDeducted)
                    figure(c.balancingPayment >= 0 ? "Balancing payment" : "Repayment", abs(c.balancingPayment))
                    figure("Payments on account", c.nextPaymentOnAccount, detail: c.nextPaymentOnAccount > 0 ? "each, for \(UKTaxYear(startYear: result.taxYear.startYear + 1).label)" : nil)
                }
                TaxSelfAssessmentWarnings(result: result)
                PropertySection("How the tax is worked out") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                            let focused = viewModel.focusedStep?.title == step.title
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title).font(.body.weight(.semibold))
                                    Text(step.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if let amount = step.amount { PropertyMoney(minorUnits: amount, currency: .gbp, neutral: true) }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(focused ? theme.accent.opacity(0.15) : Color.clear))
                            .id(step.title)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        } else {
            TaxSelfAssessmentUnavailable(page: page)
        }
    }

    private func figure(_ title: String, _ pence: Int, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            PropertyMoney(minorUnits: pence, currency: .gbp, font: .title3.monospacedDigit().weight(.semibold), neutral: true)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// HMRC online, step by step, with the values to enter; deadlines; Filed and payments.
struct TaxFilingTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var recording: Identified<HMRCPayment>?
    @State private var editing: Identified<HMRCPayment>?
    @State private var deleting: HMRCPayment?

    var body: some View {
        if let result = page.selfAssessment {
            VStack(alignment: .leading, spacing: 12) {
                PropertySection("Status", accessory: {
                    HStack(spacing: 8) {
                        if page.row.status == .preparing || page.row.status == .ready {
                            Button("Mark as filed") { viewModel.setStatus(.filed) }
                        }
                        Button("Record payment…") {
                            let c = result.calculation
                            recording = Identified(HMRCPayment(personId: page.row.person.id ?? 0, startYear: result.taxYear.startYear,
                                                               date: PayCalendar.utcDay(sameDayAs: Date(), in: .current), amountMinorUnits: abs(c.balancingPayment),
                                                               kind: c.balancingPayment >= 0 ? .balancingPayment : .refund))
                        }
                    }
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(TaxFormat.status(page.row.status), systemImage: TaxFormat.statusImage(page.row.status))
                        Text("Return and payment by \(DocumentFormat.day(page.row.deadlines.onlineReturnAndBalancingPayment)) · 2nd payment on account by \(DocumentFormat.day(page.row.deadlines.secondPaymentOnAccount))")
                            .font(.callout).foregroundStyle(.secondary)
                        if !page.income.payments.isEmpty {
                            HMRCPaymentsGrid(payments: page.income.payments, counts: page.income.documentCounts,
                                             edit: { editing = Identified($0) }, delete: { deleting = $0 })
                                .padding(.top, 4)
                        }
                    }
                }
                ForEach(page.filing) { step in
                    PropertySection("\(step.id). \(step.title)", accessory: {
                        if let deadline = step.deadline { Text("by \(DocumentFormat.day(deadline))").font(.callout).foregroundStyle(.secondary) }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !step.values.isEmpty {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                    ForEach(Array(step.values.enumerated()), id: \.offset) { _, value in
                                        GridRow {
                                            Text(value.box ?? "").monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                            Text(value.label).lineLimit(2)
                                            TaxBoxValueText(value: value.value).gridColumnAlignment(.trailing)
                                            Button("Copy") { viewModel.copy(value.copyText) }
                                                .buttonStyle(.borderless)
                                                .accessibilityLabel("Copy \(value.label)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .sheet(item: $recording) { item in
                HMRCPaymentSheet(viewModel: viewModel, payment: item.value, yearStatus: page.row.status, markPaid: true)
            }
            .sheet(item: $editing) { item in
                HMRCPaymentSheet(viewModel: viewModel, payment: item.value, yearStatus: page.row.status)
            }
            .confirmationDialog("Delete this \(deleting?.kind.displayName.lowercased() ?? "payment")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    if let id = deleting?.id { viewModel.deletePayment(id) }
                    deleting = nil
                }
            } message: {
                Text("Its document links go too; the documents stay in the library.")
            }
        } else {
            TaxSelfAssessmentUnavailable(page: page)
        }
    }
}
