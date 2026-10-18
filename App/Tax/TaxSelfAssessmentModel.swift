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

    // MARK: Form import

    /// A form read and waiting for the user to confirm it.
    struct FormImportDraft: Identifiable {
        let id = UUID()
        var documentId: Int64
        var fileName: String
        var extraction: PayrollFormExtraction
        /// Whether the file was new to the library (Cancel removes it again).
        var isNewDocument: Bool
        /// Warnings about whose form it is (another person's NI number, or not this person's).
        var personWarnings: [String]
    }

    /// Copies the file into the library and reads it (off the main thread).
    func readForm(_ url: URL, kind: PayrollFormKind?) async -> Result<FormImportDraft, Error> {
        let library = library
        let personId = selection?.personId
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(EvidenceLibrary.AddResult, PayrollFormExtraction), Error> in
            Result {
                try EvidenceFiles.withAccess(url) {
                    let added = try library.addAnalyzing(url)
                    return (added, PayrollFormReader.read(library.fileURL(for: added.document), kind: kind))
                }
            }
        }.value
        switch outcome {
        case let .failure(error):
            return .failure(error)
        case let .success((added, extraction)):
            guard let documentId = added.document.id else { return .failure(PersonalIncomeError.employmentNotFound) }
            let warnings = (try? await dbQueue.read { db -> [String] in
                guard let number = extraction.nationalInsuranceNumber else { return [] }
                if let suggested = try PayrollFormImport.suggestedPersonId(db: db, nationalInsuranceNumber: number), suggested != personId {
                    return ["The form's National Insurance number is \(try Person.fetchOne(db, key: suggested)?.name ?? "another person")'s, not this person's."]
                }
                if let personId, let person = try Person.fetchOne(db, key: personId), let stored = person.ukNino,
                   stored.uppercased().filter({ $0.isLetter || $0.isNumber }) != number {
                    return ["The form's National Insurance number isn't the one stored for \(person.name)."]
                }
                return []
            }) ?? []
            return .success(FormImportDraft(documentId: documentId, fileName: url.lastPathComponent, extraction: extraction,
                                            isNewDocument: added.isNew, personWarnings: warnings))
        }
    }

    /// Cancel of the confirm sheet: a file the import added to the library goes again while
    /// nothing links to it.
    func discardImport(_ draft: FormImportDraft) {
        guard draft.isNewDocument else { return }
        let library = library
        Task.detached(priority: .utility) { try? library.remove(draft.documentId) }
    }

    func applyForm(_ confirmed: PayrollFormImport.Confirmed, documentId: Int64) -> String? {
        do {
            let result = try dbQueue.write { db in try PayrollFormImport.apply(db: db, confirmed, documentId: documentId) }
            infoMessage = "\(confirmed.kind.displayName) saved for \(result.employment.employerName)"
                + (result.createdEmployment ? " (new employment)." : ".")
            return nil
        } catch let PayrollFormImport.ImportError.incomplete(problems) {
            return problems.map(TaxIncomeMessages.text).joined(separator: " ")
        } catch {
            return TaxMessages.text(for: error)
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

/// Readable text for the income tab's checks.
enum TaxIncomeMessages {
    static func text(_ problem: PayrollFormImport.Problem) -> String {
        switch problem {
        case .missingTaxYear: return "Choose the tax year."
        case .missingEmployer: return "Enter the employer's name."
        case .missingPayOrTax: return "Enter the pay and the tax taken off."
        case .missingLeavingDate: return "Enter the leaving date."
        case .leavingDateOutsideYear: return "The leaving date isn't in that tax year."
        case .invalidPAYEReference: return "A PAYE reference looks like 123/AB456."
        }
    }
}
