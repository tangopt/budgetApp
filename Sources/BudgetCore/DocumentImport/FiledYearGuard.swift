import Foundation
import GRDB

/// Filed returns never change (spec 2026-10-20, "Calls made after the builder check" 2): an
/// item whose confirmation would move any figure on a filed or paid Self Assessment return of
/// the person who filed it is held in Needs you with the impact explained, and its only
/// resolution is to leave it out. Figures that are information only (not on the return) may
/// change; they are kept on the item for the preview.
///
/// Each item is checked by doing what confirming it does — a placeholder document from its
/// placement, `ImportEffects.applyRecords`, the follow-on matching — in a savepoint that is
/// rolled back, and comparing `TaxFigures` before and after. There is no date shortcut: the
/// rental accounts attribute payments to earlier years (previous calendar year, invoice date,
/// quota windows) and matching can recategorise older rows.
///
/// Taking the figures is the slow part, so with several items to check, what taking them read
/// is recorded statement by statement, year by year (`TaxFiguresReads`); after confirming an
/// item, the statements reading a table it wrote run again, and only the years one of whose
/// statements returns something else are worked out again (none: the item changes no figure).
/// Every read counts, so this is the same answer as taking every figure again.
///
/// The batch's follow-on matching is run once on its own first: whatever filed figure the
/// matching alone would move (stale matching) is reported on every item whose confirmation
/// reruns it ("Re-running matching on … would change this return"); each item's own impact is
/// measured against the figures after that matching.
///
/// Confirm-time backstop (the importer): take `TaxFigures.snapshot(db:)` before applying the
/// batch, apply every item and the follow-ons, then roll back when `filedChanges(db:from:)`
/// isn't empty.
public enum FiledYearGuard {
    /// Issue id of an item whose confirmation couldn't be simulated.
    static let checkFailedIssueId = "filed-check"
    static let checkFailedReason = "Couldn't check this against the filed returns: leave it out and report it"

    /// The UK tax years (start years) anyone has filed or paid.
    public static func filedYears(db: Database) throws -> Set<Int> {
        Set(try Int.fetchAll(db, sql: "SELECT DISTINCT startYear FROM taxYear WHERE status IN (?, ?)",
                             arguments: [TaxYearStatus.filed.rawValue, TaxYearStatus.paid.rawValue]))
    }

    /// The return changes, in years the person filed or paid, between `raw` (taken earlier in
    /// this transaction) and the figures now. The importer's confirm-time backstop: snapshot
    /// before applying the batch (`TaxFigures.snapshot(db:)`), apply it and its follow-on
    /// matching, then abort (roll back) when this isn't empty.
    public static func filedChanges(db: Database, from raw: TaxFigures.Snapshot) throws -> [FiledYearImpact] {
        let now = try TaxFigures.snapshot(db: db, years: Array(Set(raw.values.keys.map(\.startYear))))
        return FiledYearImpact.impacts(before: raw, after: now, causes: [])
    }

    /// Whether confirming the item can write more than the document itself: an effect, a link,
    /// or a document with a date or period (which the rental accounts may read).
    public static func needsCheck(_ item: ImportItem) -> Bool {
        if item.effect.mayChangeTaxFigures || !item.links.isEmpty { return true }
        guard let metadata = item.placement?.metadata else { return false }
        return metadata.docDate != nil || metadata.periodStart != nil || metadata.periodEnd != nil
    }

    /// What confirming the item would change in each (year, person) that person filed or paid:
    /// impacts with return changes, and impacts with only information changes. Empty when the
    /// item writes nothing that could (`needsCheck`) or no year is filed or paid.
    public static func impacts(db: Database, item: ImportItem, filedYears: Set<Int>) throws -> [FiledYearImpact] {
        try impacts(db: db, item: item, filedYears: filedYears, onSnapshot: {})
    }

    /// `impacts`, calling `onSnapshot` for each snapshot taken (tests count them).
    static func impacts(db: Database, item: ImportItem, filedYears: Set<Int>, onSnapshot: () -> Void) throws -> [FiledYearImpact] {
        guard !filedYears.isEmpty, needsCheck(item) else { return [] }
        let item = asConfirmed(item)
        var impacts: [FiledYearImpact] = []
        let cache = RentCreditEvidence.AdviceCache()
        try db.inSavepoint {
            let base = try baseline(db: db, cache: cache, onSnapshot: onSnapshot)
            impacts = try matchingImpacts(db: db, item: item, baseline: base)
                + Self.impacts(db: db, item: item, before: base.before, reads: base.reads, cache: cache, onSnapshot: onSnapshot)
            return .rollback
        }
        return impacts
    }

    /// Each item checked against the filed and paid years: one `.filedYear` issue per (year,
    /// person) whose return would change (id `"filed-<year>-<person>"`, resolution: leave out),
    /// the information-only impacts in `informationChanges`. Earlier guard annotations are
    /// replaced; left-out and duplicate items aren't applied, so aren't checked. An item whose
    /// confirmation can't be simulated is held too (it can't be shown to leave filed returns alone).
    /// Each item is checked on its own against the same "before". With several items to check,
    /// what taking "before" read is recorded (`TaxFiguresReads`), and an item after which it all
    /// reads the same isn't worked out again (nor the years whose reads didn't change).
    public static func annotate(_ items: [ImportItem], db: Database) throws -> [ImportItem] {
        try annotate(items, db: db, onSnapshot: {})
    }

    /// `annotate`, calling `onSnapshot` for each snapshot taken (tests count them).
    /// `progress`: (items checked, items to check), with (0, 0) before the baseline is taken.
    /// `checkCancellation`: called before the baseline and each item; what it throws stops the pass.
    /// `shortcut`: false — every item's figures are taken again in full (tests compare).
    static func annotate(_ items: [ImportItem], db: Database, timings: ImportPlanTimings? = nil,
                         progress: (_ checked: Int, _ total: Int) -> Void = { _, _ in },
                         checkCancellation: () throws -> Void = {}, shortcut: Bool = true,
                         onSnapshot: () -> Void) throws -> [ImportItem] {
        let filed = try filedYears(db: db)
        var result = items.map { original -> ImportItem in
            var item = original
            item.issues.removeAll(where: isGuardIssue)
            item.informationChanges = []
            return item
        }
        let checked = result.indices.filter { !result[$0].isLeftOut && result[$0].duplicate == nil && needsCheck(result[$0]) }
        guard !filed.isEmpty, !checked.isEmpty else { return result }
        // The library's advices are read once for the pass (each item's placeholder is new).
        let cache = RentCreditEvidence.AdviceCache()
        try db.inSavepoint {
            progress(0, 0)
            try checkCancellation()
            let base = try timings.measure(.guardBaseline) {
                // Recording pays off from the second item on.
                try baseline(db: db, cache: cache, recordReads: shortcut && checked.count > 1, onSnapshot: onSnapshot)
            }
            for (done, index) in checked.enumerated() {
                progress(done, checked.count)
                try checkCancellation()
                let start = Date()
                defer { timings?.addCheck(effectName(result[index].effect), Date().timeIntervalSince(start)) }
                var item = result[index]
                let confirmed = asConfirmed(item)
                for impact in try matchingImpacts(db: db, item: confirmed, baseline: base) {
                    item.issues.append(ImportIssue(id: "filed-\(impact.startYear)-\(impact.person)-matching", kind: .filedYear(impact),
                                                   reason: impact.headline, offers: [.leaveOut]))
                }
                let impacts: [FiledYearImpact]
                do {
                    impacts = try Self.impacts(db: db, item: confirmed, before: base.before, reads: base.reads, cache: cache,
                                               timings: timings, onSnapshot: onSnapshot)
                } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                    throw error
                } catch {
                    item.issues.append(holdIssue(for: error))
                    result[index] = item
                    continue
                }
                for impact in impacts {
                    if impact.returnChanges.isEmpty {
                        item.informationChanges.append(impact)
                    } else {
                        item.issues.append(ImportIssue(id: "filed-\(impact.startYear)-\(impact.person)", kind: .filedYear(impact),
                                                       reason: impact.headline, offers: [.leaveOut]))
                    }
                }
                result[index] = item
            }
            progress(checked.count, checked.count)
            return .rollback
        }
        return result
    }

    /// The effect's case name (`"file"`, `"ukStatement"`…), for the dry run's slowest checks.
    private static func effectName(_ effect: ImportEffect) -> String {
        String(String(describing: effect).prefix { $0 != "(" })
    }

    /// The item as confirming it would apply it: a possibly corrected version of a recorded
    /// invoice or receipt still to answer is checked as its default answer, "File the document
    /// only" (it is never recorded a second time, which its own effect would be refused).
    static func asConfirmed(_ item: ImportItem) -> ImportItem {
        guard let issue = item.issues.first(where: { ImportDuplicates.isCorrectedVersion($0.id) }),
              issue.offers.contains(.fileWithoutLink),
              let answered = try? ImportResolutions.apply(.fileWithoutLink, to: item, issueId: issue.id) else { return item }
        return answered
    }

    /// The hold of an item whose confirmation couldn't be simulated (`impacts` threw `error`):
    /// what confirming it would refuse (`ImportApplyError.planOutdated`, e.g. a mortgage balance
    /// the statement contradicts) said as is, anything else "Couldn't check…". Leave out only.
    public static func holdIssue(for error: Error) -> ImportIssue {
        if case ImportApplyError.planOutdated(let why) = error {
            let reason = "\(why): leave it out of this import"
            return ImportIssue(id: checkFailedIssueId, kind: .readerProblem(reason), reason: reason, offers: [.leaveOut])
        }
        return ImportIssue(id: checkFailedIssueId, kind: .readerProblem(checkFailedReason), reason: checkFailedReason,
                           offers: [.leaveOut], detail: String(describing: error))
    }

    private static func isGuardIssue(_ issue: ImportIssue) -> Bool {
        if case .filedYear = issue.kind { return true }
        return issue.id == checkFailedIssueId
    }

    /// What the follow-on matching alone would change on filed or paid returns (the baseline
    /// against the figures as stored: stale matching), in a savepoint that is rolled back.
    /// Needs a write transaction.
    public static func matchingDrift(db: Database) throws -> [FiledYearImpact] {
        var drift: [FiledYearImpact] = []
        try db.inSavepoint {
            drift = try baseline(db: db, cache: RentCreditEvidence.AdviceCache(), onSnapshot: {}).drift
            return .rollback
        }
        return drift
    }

    // MARK: Simulation

    /// The figures as stored (`raw`) and after the follow-on matching has run on its own
    /// (`before`, inside the caller's savepoint), so an item's own impact is only what the item
    /// adds; `drift` is what the matching alone would change on filed returns, and `drifting`
    /// the properties whose figures it moves (nil: can't tell, all of them).
    private struct Baseline {
        var before: TaxFigures.Snapshot
        var drift: [FiledYearImpact]
        var drifting: Set<Int64>?
        var driftingNames: [String]?
        /// What taking `before` read, year by year (nil: not recorded, or not replayable).
        var reads: YearReads?
    }

    /// The years a snapshot works out (`TaxFigures.years`), what working them out read, and
    /// which of those reads each year's figures came from.
    struct YearReads {
        var years: [Int]
        var reads: TaxFiguresReads
        /// Each year's reads, with those of the earlier years whose returns and accounts it reused.
        var yearReads: [Int: Set<Int>]
        /// The returns and accounts worked out, each tagged with the year it was worked out for.
        var memo: TaxComputationMemo
        /// The schema they were read with (GRDB reads a table's columns once: a later year's reads don't show it).
        var schemaVersion: Int32

        /// The years one of whose reads gives something else now (nil when the years themselves
        /// or the schema changed: take the whole snapshot again). `written`: the only tables
        /// written since (`TaxFiguresReads.writtenTables`; nil: can't tell).
        func changedYears(db: Database, written: Set<String>?) throws -> [Int]? {
            guard try db.schemaVersion() == schemaVersion, try TaxFigures.years(db: db, extra: years) == years else { return nil }
            let changed = reads.changed(written: written)
            return years.filter { year in yearReads[year].map { !$0.isDisjoint(with: changed) } ?? true }
        }
    }

    /// `recordReads`: record what taking `before` reads (`TaxFiguresReads`), for the items' checks.
    private static func baseline(db: Database, cache: RentCreditEvidence.AdviceCache, recordReads: Bool = false,
                                 onSnapshot: () -> Void) throws -> Baseline {
        onSnapshot()
        let raw = try TaxFigures.snapshot(db: db)
        try ImportEffects.followOns(db: db, propertyIds: nil, adviceCache: cache)
        onSnapshot()
        let years = try TaxFigures.years(db: db, extra: Array(Set(raw.values.keys.map(\.startYear))))
        var before: TaxFigures.Snapshot
        var reads: YearReads?
        if recordReads {
            // Year by year, each year's reads recorded on their own (the same figures as one snapshot).
            // Earlier years first, so a year's return reuses the earlier ones (their reads count as its own).
            before = try TaxFigures.snapshot(db: db, only: [])
            let memo = TaxComputationMemo()
            var recorded = YearReads(years: years, reads: TaxFiguresReads(), yearReads: [:], memo: memo, schemaVersion: try db.schemaVersion())
            var replayable = true
            for year in years {
                memo.tag = year
                memo.usedTags = []
                let (part, read) = try recorded.reads.record(db: db) { try TaxFigures.snapshot(db: db, only: [year], memo: memo) }
                before.values.merge(part.values) { _, new in new }
                guard var read else {
                    replayable = false
                    continue
                }
                for used in memo.usedTags { read.formUnion(recorded.yearReads[used] ?? []) }
                recorded.yearReads[year] = read
            }
            reads = replayable ? recorded : nil
        } else {
            before = try TaxFigures.snapshot(db: db, only: years)
        }
        let drift = FiledYearImpact.impacts(before: raw, after: before, causes: [])
        guard !drift.isEmpty else { return Baseline(before: before, drift: [], drifting: [], driftingNames: [], reads: reads) }
        // The properties named by the fields that moved ("<property> · …").
        let moved = TaxFigures.changes(from: raw, to: before).map(\.key.field)
        let properties = try Property.fetchAll(db).filter { property in moved.contains { $0.hasPrefix("\(property.name) · ") } }
        guard !properties.isEmpty else { return Baseline(before: before, drift: drift, drifting: nil, driftingNames: nil, reads: reads) }
        return Baseline(before: before, drift: drift, drifting: Set(properties.compactMap(\.id)), driftingNames: properties.map(\.name),
                        reads: reads)
    }

    /// The filed-return changes the matching alone would make, for an item whose confirmation
    /// reruns that matching (it really does at apply): `"Re-running matching on <properties>
    /// would change this return"`, before = as stored, after = after the matching.
    private static func matchingImpacts(db: Database, item: ImportItem, baseline: Baseline) throws -> [FiledYearImpact] {
        guard !baseline.drift.isEmpty else { return [] }
        let touched = try ImportEffects.touchedPropertyIds(db: db, item: item)
        let triggers: Bool
        if let touched {
            triggers = !touched.isEmpty && (baseline.drifting.map { !$0.isDisjoint(with: touched) } ?? true)
        } else {
            triggers = true
        }
        guard triggers else { return [] }
        let names = baseline.driftingNames.map { $0.joined(separator: ", ") } ?? "every account"
        return baseline.drift.map { impact in
            var impact = impact
            impact.causes = ["Re-running matching on \(names) would change this return"]
            return impact
        }
    }

    /// Confirms the item in a savepoint (placeholder document, records, follow-ons), takes the
    /// figures and rolls back. A year whose reads in taking `before` (`reads`) all read the same
    /// after confirming it has `before`'s figures, and isn't worked out again: only the other
    /// years are (none: nothing changes).
    private static func impacts(db: Database, item: ImportItem, before: TaxFigures.Snapshot, reads: YearReads?,
                                cache: RentCreditEvidence.AdviceCache, timings: ImportPlanTimings? = nil,
                                onSnapshot: () -> Void) throws -> [FiledYearImpact] {
        var after = TaxFigures.Snapshot()
        var unchanged = false
        try db.inSavepoint {
            let written = try TaxFiguresReads.writtenTables(db: db) {
                try timings.measure(.guardApply) {
                    let documentId = try placeholderDocument(db: db, item: item)
                    try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: nil)
                }
                try timings.measure(.guardFollowOns) {
                    try ImportEffects.followOns(db: db, propertyIds: ImportEffects.touchedPropertyIds(db: db, item: item), adviceCache: cache)
                }
            }
            if let reads, let changed = try timings.measure(.guardReplay, { try reads.changedYears(db: db, written: written) }) {
                guard !changed.isEmpty else {
                    unchanged = true
                    return .rollback
                }
                onSnapshot()
                // The returns and accounts of the years whose reads didn't change are reused.
                let memo = reads.memo.keeping(excluding: Set(changed))
                let part = try timings.measure(.guardSnapshot) { try TaxFigures.snapshot(db: db, only: changed, memo: memo) }
                let retaken = Set(changed)
                after = before
                after.values = after.values.filter { !retaken.contains($0.key.startYear) }.merging(part.values) { _, new in new }
                after.statuses = part.statuses
                return .rollback
            }
            onSnapshot()
            after = try timings.measure(.guardSnapshot) {
                try TaxFigures.snapshot(db: db, years: Array(Set(before.values.keys.map(\.startYear))))
            }
            return .rollback
        }
        if unchanged { return [] }
        let found = FiledYearImpact.impacts(before: before, after: after, causes: [], includeInformationOnly: true)
        return try found.map { impact in
            var impact = impact
            impact.causes = try causes(db: db, item: item)
            return impact
        }
    }

    /// A document row as filing the item would add it (its placement's kind, dates, amount,
    /// persons and text — so the follow-on advice matching reads it as it will the real one),
    /// without copying any file.
    static func placeholderDocument(db: Database, item: ImportItem) throws -> Int64 {
        // The metadata the importer files the item with (`ImportApplier.metadata`).
        let metadata = ImportApplier.metadata(for: item, folders: [])
        var document = EvidenceDocument(sha256: "filed-year-check:\(item.id.uuidString)", storedRelativePath: "",
                                        originalFileName: item.file.fileName, byteCount: item.file.byteCount,
                                        canonicalName: metadata.canonicalName, kind: metadata.kind, docDate: metadata.docDate,
                                        periodStart: metadata.periodStart, periodEnd: metadata.periodEnd,
                                        amountMinorUnits: metadata.amountMinorUnits, currency: metadata.currency, persons: metadata.persons,
                                        textStatus: metadata.textStatus, extractedText: metadata.extractedText, addedAt: Date())
        try document.insert(db)
        return document.id!
    }

    // MARK: Causes

    /// The item (`"<title>: <money and date facts>"`) and, for a statement, each row put in a
    /// property's category (the rows the rental accounts read): `"<date> <description> <amount>"`;
    /// for a BBVA statement also each interest row it writes on the mortgage (an instalment's,
    /// or an estimate's replacement): `"<date> Mortgage interest (instalment N) <amount>"`.
    static func causes(db: Database, item: ImportItem) throws -> [String] {
        let facts = item.facts.compactMap { fact -> String? in
            let name = fact.field.displayName.lowercased()
            switch fact.value {
            case .money(let amount, let currency): return "\(name) \(Money.format(amount, currency: currency))"
            case .date(let date): return "\(name) \(EvidenceInitialImport.day(date))"
            case .text, .year: return nil
            }
        }
        var causes = [facts.isEmpty ? item.title : "\(item.title): \(facts.joined(separator: ", "))"]
        var statementRows: (accountId: Int64, rows: [StagedTransaction])?
        switch item.effect {
        case .ukStatement(let statement): statementRows = (statement.accountId, statement.staged)
        case .bbvaStatement(let statement): statementRows = (statement.currentAccountId, statement.staged)
        default: break
        }
        if let statement = statementRows {
            let currency = try Account.fetchOne(db, key: statement.accountId)?.currency ?? .gbp
            var propertyCategories = Set<Int64>()
            for property in try Property.fetchAll(db) {
                guard let propertyId = property.id else { continue }
                propertyCategories.formUnion(try TaxExpenseTypeMap.propertyCategories(db: db, propertyId: propertyId).compactMap(\.id))
            }
            for row in statement.rows where row.suggestedCategoryId.map(propertyCategories.contains) == true {
                causes.append("\(EvidenceInitialImport.day(row.parsed.date)) \(row.parsed.rawDescription) "
                              + Money.format(row.parsed.amountMinorUnits, currency: currency))
            }
        }
        if case .bbvaStatement(let statement) = item.effect, let loanId = statement.loanAccountId {
            let currency = try Account.fetchOne(db, key: loanId)?.currency ?? .eur
            for receipt in statement.instalments.map(\.receipt) + statement.estimates.map(\.receipt) {
                let charges = BBVAStatementLegs.charges(receipt)
                guard charges != 0 else { continue }
                causes.append("\(EvidenceInitialImport.day(receipt.operationDate)) \(BBVAFundMortgageImport.interestCategoryName) "
                              + "(instalment \(receipt.number)) \(Money.format(-charges, currency: currency))")
            }
        }
        return causes
    }
}
