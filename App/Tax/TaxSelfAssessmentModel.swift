// App/Tax/TaxSelfAssessmentModel.swift
import Foundation
import AppKit
import BudgetCore
import GRDB

/// The Self Assessment tabs' actions (plan phase 4 Task 4): the person's income records and
/// HMRC payments (saved with their staged documents), P60 / P45 / P11D import, the evidence
/// rules, and the Return tab' copy and drill-down.
extension TaxYearsViewModel {
    // MARK: Records (through the filed-year check, plan Task 14: they feed the year's SA boxes)

    /// A record of the year on show saved or deleted through the filed-year check (`gate`: a
    /// sheet's; nil: the screen's), reaching that year (or `year`, when earlier) and later ones.
    private func record(_ edit: String, year: Int? = nil, gate: FiledYearGate? = nil, _ body: @escaping (Database) throws -> Void,
                        done: ((String?) -> Void)? = nil) {
        let years = [selection?.startYear, year].compactMap { $0 }
        let scope = years.min().map(FiledYearEditCheck.Scope.from(year:)) ?? .everyYear
        checked(edit: edit, scope: scope, gate: gate, body, done: done)
    }

    func saveEmployment(_ employment: Employment, documents: EvidenceLinkChanges, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        record("Employment \(employment.employerName) \(employment.id == nil ? "added" : "edited")", year: employment.startYear, gate: gate, { db in
            var employment = employment
            try Employments.save(db: db, &employment, documents: documents)
        }, done: done)
    }

    func deleteEmployment(_ id: Int64) {
        record("Employment deleted") { db in _ = try Employments.delete(db: db, id: id) }
    }

    func saveIncome(_ income: EmploymentIncome, documents: EvidenceLinkChanges, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        record("Pay and tax \(income.id == nil ? "added" : "edited")", gate: gate, { db in
            var income = income
            try Employments.save(db: db, &income, documents: documents)
        }, done: done)
    }

    func deleteIncome(_ id: Int64) {
        record("Pay and tax deleted") { db in _ = try Employments.deleteIncome(db: db, id: id) }
    }

    func saveBenefit(_ benefit: BenefitInKind, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        record("Benefit \(benefit.id == nil ? "added" : "edited")", gate: gate, { db in
            var benefit = benefit
            try Employments.save(db: db, &benefit)
        }, done: done)
    }

    func deleteBenefit(_ id: Int64) {
        record("Benefit deleted") { db in _ = try Employments.deleteBenefit(db: db, id: id) }
    }

    func saveOtherIncome(_ income: OtherIncome, documents: EvidenceLinkChanges, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        record("\(income.kind.displayName) \(income.id == nil ? "added" : "edited")", year: income.startYear, gate: gate, { db in
            var income = income
            try OtherIncomes.save(db: db, &income, documents: documents)
        }, done: done)
    }

    func deleteOtherIncome(_ id: Int64) {
        record("Other income deleted") { db in _ = try OtherIncomes.delete(db: db, id: id) }
    }

    func savePension(_ contribution: PensionContribution, documents: EvidenceLinkChanges, gate: FiledYearGate,
                     done: @escaping (String?) -> Void) {
        record("Pension contribution \(contribution.id == nil ? "added" : "edited")", gate: gate, { db in
            var contribution = contribution
            try PensionContributions.save(db: db, &contribution, documents: documents)
        }, done: done)
    }

    func deletePension(_ id: Int64) {
        record("Pension contribution deleted") { db in _ = try PensionContributions.delete(db: db, id: id) }
    }

    func savePayment(_ payment: HMRCPayment, documents: EvidenceLinkChanges, markYear status: TaxYearStatus?, gate: FiledYearGate,
                     done: @escaping (String?) -> Void) {
        record("HMRC payment \(payment.id == nil ? "recorded" : "edited")", year: payment.startYear, gate: gate, { db in
            var payment = payment
            try HMRCPayments.save(db: db, &payment, documents: documents, markYear: status)
        }, done: done)
    }

    func deletePayment(_ id: Int64) {
        record("HMRC payment deleted") { db in _ = try HMRCPayments.delete(db: db, id: id) }
    }


    func seedIncomeEvidenceRules() {
        do {
            let added = try dbQueue.write(.property) { db in try PersonalIncomeEvidence.seedRules(db: db) }
            infoMessage = added.isEmpty ? "The personal income evidence rules are already there."
                : "Added \(added.count) evidence rule\(added.count == 1 ? "" : "s"): P60, P45 and P11D per employment, a proof per HMRC payment."
        } catch {
            errorMessage = TaxMessages.text(for: error)
        }
    }

    // MARK: Return and filing

    /// Puts a box's value on the clipboard as HMRC online takes it (`copyText`); the row's copy
    /// icon confirms it in place (`CopyValueButton`), so no banner moves the page.
    func copy(_ text: String) {
        CopyValueButton.toPasteboard(text)
    }

    /// Shows the calculation step behind a box.
    func showStep(_ title: String) {
        tab = .calculation
        focusedStep = StepRequest(title: title)
    }
}
