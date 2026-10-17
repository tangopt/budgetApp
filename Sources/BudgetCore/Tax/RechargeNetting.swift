import GRDB
import Foundation

/// How utilities meet the recharges received for them (plan phase 5 Task 1).
///
/// The utility categories of a property are those whose tax type is Utilities, plus the
/// utility-named ones (electricity, gas, water…) left "not deductible" by the phase 3
/// suggestion (recharged to the tenant). A year's mode:
/// - `netOfRecharges`: every utility cost goes on the Utilities line, less the recharges
///   received in the year (the statement-linked parts of tenant credits), floored at zero;
///   recharges beyond the utilities paid are rental income ("Recharges above utilities paid").
/// - `notDeductible`: every utility cost goes on the not-deductible line.
/// - none stored (automatic): when the person's tax year is filed or paid, or the year has no
///   recharges received, each category stays on its own line exactly as before phase 5 (filed
///   figures don't move silently; an open year with utilities left not deductible warns);
///   else `netOfRecharges`.
///
/// Netting needs a common basis per year: utilities count by their rule (by date: the invoice
/// or debit date), recharges by the date their credit arrived. A recharge received early in a
/// year can pay invoices of the year before ("window drift"); the year's totals still balance
/// over time, and a year's recharges above its utilities paid are rental income.
/// When rent comes from credits (rent rule other than by rent period), a credit's
/// statement-linked part is taken out of the rent whenever a mode applies.
public enum RechargeNetting {
    /// The year's mode: its own, else the one for every year, else `nil` (automatic).
    public static func mode(db: Database, startYear: Int) throws -> RechargeNettingMode? {
        if let rule = try request(startYear: startYear).fetchOne(db) { return rule.mode }
        return try request(startYear: nil).fetchOne(db)?.mode
    }

    /// Sets the mode for every year (`startYear` nil) or one year; `nil` removes it.
    public static func set(db: Database, startYear: Int?, mode: RechargeNettingMode?, notes: String? = nil) throws {
        let existing = try request(startYear: startYear).fetchOne(db)
        guard let mode else {
            if let existing { try existing.delete(db) }
            return
        }
        var rule = existing ?? RechargeNettingRule(startYear: startYear, mode: mode)
        rule.mode = mode
        rule.notes = Transaction.normalizedNote(notes)
        try rule.save(db)
    }

    /// Whether a category name is a utility's, by whole words: utilities, electricity, water,
    /// electric, gas, água, luz, eletricidade (the evidence and tax rules only look at the
    /// property's own categories).
    public static func isUtilityName(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !words.isDisjoint(with: ["utilities", "utility", "electricity", "electric", "eletricidade", "electricidade", "water", "gas", "agua", "luz"])
    }

    /// The property's utility expense categories: tax type Utilities, or not deductible with a
    /// utility name.
    public static func utilityCategoryIds(db: Database, propertyId: Int64) throws -> Set<Int64> {
        Set(try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId).filter { entry in
            entry.category.type == .expense
                && (entry.expenseType == .utilities || (entry.expenseType == .notDeductible && isUtilityName(entry.category.name)))
        }.compactMap(\.category.id))
    }

    private static func request(startYear: Int?) -> QueryInterfaceRequest<RechargeNettingRule> {
        startYear.map { RechargeNettingRule.filter(Column("startYear") == $0) } ?? RechargeNettingRule.filter(Column("startYear") == nil)
    }
}
