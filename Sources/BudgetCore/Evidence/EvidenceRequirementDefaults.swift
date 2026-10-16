import GRDB
import Foundation

/// The phase-1 default rules (plan Task 5, spec §7): every expense transaction in a property's
/// category group needs a document of the kind its category implies, and every instalment
/// transferred to the mortgage account needs the bank's notice. Never run automatically:
/// a tool or the app calls `seedPropertyRules` with the user's go.
public enum EvidenceRequirementDefaults {
    public struct CategoryRule: Equatable, Sendable {
        public var kinds: [DocumentKind]
        public var usualSource: String?
    }

    /// The kinds and usual source a category's transactions need, from its name (case and
    /// accent-insensitive), first match wins: insurance (incl. "Mortgage insurance") → receipt
    /// or policy, Mortgage interest → mortgage notice or interest statement, IMI → notice or
    /// payment, Condomínio → receipt, PT tax → IRS liquidação or payment, PT accountant →
    /// accountant invoice, Legal fees → legal invoice or court fee, Repairs → any document
    /// (invoices classify as `other`), Utilities → utility invoice, bank fees → bank
    /// statement; any other name → any document, no usual source.
    public static func rule(forCategoryName name: String) -> CategoryRule {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if folded.contains("insurance") || folded.contains("seguro") { return CategoryRule(kinds: [.insuranceReceipt, .insurancePolicy], usualSource: "Insurer") }
        if folded.contains("mortgage") { return CategoryRule(kinds: [.mortgageNotice, .mortgageInterestStatement], usualSource: "BBVA app") }
        if words.contains("imi") { return CategoryRule(kinds: [.imiNotice, .imiPayment], usualSource: "Portal das Finanças") }
        if folded.contains("condominio") { return CategoryRule(kinds: [.condominioReceipt], usualSource: "Condomínio administrator") }
        if folded.contains("pt tax") || words.contains("irs") {
            return CategoryRule(kinds: [.ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof], usualSource: "Portal das Finanças")
        }
        if folded.contains("accountant") { return CategoryRule(kinds: [.accountantInvoice], usualSource: "Accountant") }
        if folded.contains("legal") { return CategoryRule(kinds: [.legalInvoice, .courtFee], usualSource: "Lawyer / court") }
        if folded.contains("repair") { return CategoryRule(kinds: [], usualSource: "Supplier") }
        if folded.contains("utilit") { return CategoryRule(kinds: [.utilityInvoice], usualSource: "Utility provider") }
        if words.contains("fees") || words.contains("fee") { return CategoryRule(kinds: [.bankStatement], usualSource: "BBVA app") }
        return CategoryRule(kinds: [], usualSource: nil)
    }

    /// The notes stamped on seeded rules.
    public static let seededNote = "Default rule (phase 1)"

    /// The rules `seedPropertyRules` would add, unsaved (the app previews them first): for
    /// the category group `groupId`, one `transactionsInCategory` rule (debits) per expense
    /// category in it, and one `transactionsMatching` rule (debits) for the transfer
    /// categories of `mortgageAccountIds` (the instalments paid into the loan) expecting a
    /// mortgage notice. With mortgage accounts, the mortgage categories' rules leave out
    /// transactions on those accounts (the interest rows on the loan), so each instalment
    /// is asked for once, by the instalment rule. A rule whose scope already exists is left out.
    public static func propertyRules(db: Database, categoryGroupId groupId: Int64, mortgageAccountIds: [Int64] = []) throws -> [EvidenceRequirement] {
        let existingScopes = Set(try EvidenceRequirement.fetchAll(db).map(\.scope))
        let groupName = try CategoryGroup.fetchOne(db, key: groupId)?.name
        var rules: [EvidenceRequirement] = []

        let categories = try Category
            .filter(Column("groupId") == groupId && Column("type") == CategoryType.expense.rawValue && Column("isReserved") == false)
            .order(Column("name"))
            .fetchAll(db)
        for category in categories {
            guard let categoryId = category.id else { continue }
            let scope = EvidenceRequirementScope.transactionsInCategory(categoryId: categoryId)
            guard !existingScopes.contains(scope) else { continue }
            let rule = rule(forCategoryName: category.name)
            let name = [groupName, category.name].compactMap { $0 }.joined(separator: ": ")
            let isMortgageCategory = rule.kinds.contains(.mortgageNotice)
            rules.append(EvidenceRequirement(name: name, scope: scope, kinds: rule.kinds, direction: .outflows,
                                             excludedAccountIds: isMortgageCategory ? mortgageAccountIds : [],
                                             usualSource: rule.usualSource, notes: seededNote))
        }

        if !mortgageAccountIds.isEmpty {
            let transferCategories = try Category
                .filter(Column("type") == CategoryType.transfer.rawValue && mortgageAccountIds.contains(Column("transferAccountId")))
                .order(Column("name"))
                .fetchAll(db)
                .compactMap(\.id)
            if !transferCategories.isEmpty {
                let scope = EvidenceRequirementScope.transactionsMatching(categoryIds: transferCategories, accountIds: [], descriptionContains: nil)
                if !existingScopes.contains(scope) {
                    let name = [groupName, "Mortgage instalments"].compactMap { $0 }.joined(separator: ": ")
                    rules.append(EvidenceRequirement(name: name, scope: scope, kinds: [.mortgageNotice], direction: .outflows,
                                                     usualSource: "BBVA app", notes: seededNote))
                }
            }
        }
        return rules
    }

    /// Saves `propertyRules` (see there). Idempotent: a rule whose scope already exists is
    /// skipped. Returns the rules added.
    @discardableResult
    public static func seedPropertyRules(db: Database, categoryGroupId groupId: Int64, mortgageAccountIds: [Int64] = []) throws -> [EvidenceRequirement] {
        var added: [EvidenceRequirement] = []
        for var requirement in try propertyRules(db: db, categoryGroupId: groupId, mortgageAccountIds: mortgageAccountIds) {
            try EvidenceRequirements.save(db: db, &requirement)
            added.append(requirement)
        }
        return added
    }
}
