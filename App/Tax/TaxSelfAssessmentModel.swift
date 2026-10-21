// App/Tax/TaxSelfAssessmentModel.swift
import Foundation
import AppKit
import BudgetCore
import GRDB

/// The Self Assessment tabs' actions (plan phase 4 Task 4): the person's income records and
/// HMRC payments (saved with their staged documents), P60 / P45 / P11D import, the evidence
/// rules, and the Return and Filing tabs' copy and drill-down.
extension TaxYearsViewModel {
    // MARK: Records

    func saveEmployment(_ employment: Employment, documents: EvidenceLinkChanges) -> String? {
        write { db in var employment = employment; try Employments.save(db: db, &employment, documents: documents) }
    }

    func deleteEmployment(_ id: Int64) {
        errorMessage = write { db in _ = try Employments.delete(db: db, id: id) }
    }

    func saveIncome(_ income: EmploymentIncome, documents: EvidenceLinkChanges) -> String? {
        write { db in var income = income; try Employments.save(db: db, &income, documents: documents) }
    }

    func deleteIncome(_ id: Int64) {
        errorMessage = write { db in _ = try Employments.deleteIncome(db: db, id: id) }
    }

    func saveBenefit(_ benefit: BenefitInKind) -> String? {
        write { db in var benefit = benefit; try Employments.save(db: db, &benefit) }
    }

    func deleteBenefit(_ id: Int64) {
        errorMessage = write { db in _ = try Employments.deleteBenefit(db: db, id: id) }
    }

    func saveOtherIncome(_ income: OtherIncome, documents: EvidenceLinkChanges) -> String? {
        write { db in var income = income; try OtherIncomes.save(db: db, &income, documents: documents) }
    }

    func deleteOtherIncome(_ id: Int64) {
        errorMessage = write { db in _ = try OtherIncomes.delete(db: db, id: id) }
    }

    func savePension(_ contribution: PensionContribution, documents: EvidenceLinkChanges) -> String? {
        write { db in var contribution = contribution; try PensionContributions.save(db: db, &contribution, documents: documents) }
    }

    func deletePension(_ id: Int64) {
        errorMessage = write { db in _ = try PensionContributions.delete(db: db, id: id) }
    }

    func savePayment(_ payment: HMRCPayment, documents: EvidenceLinkChanges, markYear status: TaxYearStatus?) -> String? {
        write { db in var payment = payment; try HMRCPayments.save(db: db, &payment, documents: documents, markYear: status) }
    }

    func deletePayment(_ id: Int64) {
        errorMessage = write { db in _ = try HMRCPayments.delete(db: db, id: id) }
    }

    func seedIncomeEvidenceRules() {
        do {
            let added = try dbQueue.write { db in try PersonalIncomeEvidence.seedRules(db: db) }
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
