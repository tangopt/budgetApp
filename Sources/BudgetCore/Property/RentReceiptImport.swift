import GRDB
import Foundation

/// Imports the portal's rent-receipts export into a property (spec 2026-10-16 §2, §6.1):
/// tenancies are created or merged by contract number, receipts upserted by (tenancy,
/// receipt number). Re-importing a newer export updates statuses and never duplicates.
public enum RentReceiptImport {
    public struct Report: Equatable, Sendable {
        /// Contract numbers of tenancies created.
        public var createdTenancies: [String] = []
        /// Contract numbers of existing tenancies whose details changed (start, end, tenant).
        public var updatedTenancies: [String] = []
        public var createdReceipts = 0
        public var updatedReceipts = 0
        public var unchangedReceipts = 0
        /// Receipts that became cancelled with this import (new cancelled ones included).
        public var cancelledReceipts = 0
        /// Payment links dropped: every active one of a receipt now cancelled, the auto ones of
        /// a receipt whose amount received changed.
        public var removedPaymentLinks = 0
        /// Auto links made again (by `RentReceiptMatching.match`) after amounts changed.
        public var rematchedPaymentLinks = 0
        /// Manual links whose rent was cut because the receipt's amount received went down
        /// below what they covered (the cut part moves to their `otherMinorUnits`).
        public var clampedManualLinks = 0
        /// Receipts of the imported contracts that the export no longer lists (kept).
        public var missingFromExport: [RentReceipt] = []
        /// The distinct "Imóvel" descriptions seen (one expected).
        public var propertyDescriptions: [String] = []

        public init() {}
    }

    /// Imports `rows` into the property.
    ///
    /// A new tenancy takes the export's reference as its label, the tenant, and starts on its
    /// first issued period. An existing one keeps its label, gains a blank tenant, and starts
    /// earlier when receipts do. A tenancy with no end gets one — its last issued period's end —
    /// once another tenancy of the property has receipts starting after it; the latest
    /// tenancy stays open. An end that issued receipts run past is moved to their last day.
    /// A receipt whose amount received changed loses its auto payment links, and matching
    /// runs again for the property.
    @discardableResult
    public static func run(db: Database, propertyId: Int64, rows: [RentReceiptsExport.Row],
                           matchOptions: RentReceiptMatching.Options = .init()) throws -> Report {
        guard try Property.exists(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        var report = Report()
        var needsRematch = false
        report.propertyDescriptions = Array(Set(rows.compactMap(\.property))).sorted()
        let byContract = Dictionary(grouping: rows, by: \.contractNumber)

        for contract in byContract.keys.sorted() {
            let group = byContract[contract]!.sorted { ($0.periodStart, $0.rowNumber) < ($1.periodStart, $1.rowNumber) }
            let issued = group.filter { $0.status == .issued }
            let firstStart = (issued.isEmpty ? group : issued).map(\.periodStart).min()!
            let first = group[0]
            var tenancy: Tenancy
            if let existing = try Tenancies.tenancy(db: db, propertyId: propertyId, contractNumber: contract) {
                tenancy = existing
                let before = tenancy
                if tenancy.tenantName == nil { tenancy.tenantName = group.compactMap(\.tenant).first }
                tenancy.startDate = min(tenancy.startDate, PropertyDates.day(firstStart))
                if tenancy != before {
                    try Tenancies.save(db: db, &tenancy)
                    report.updatedTenancies.append(contract)
                }
            } else {
                tenancy = Tenancy(propertyId: propertyId, referenceLabel: first.reference ?? "Contract \(contract)", contractNumber: contract,
                                  tenantName: group.compactMap(\.tenant).first, startDate: firstStart)
                try Tenancies.save(db: db, &tenancy)
                report.createdTenancies.append(contract)
            }

            var listed: Set<String> = []
            for row in group {
                listed.insert(row.receiptNumber)
                var receipt = try RentReceipts.receipt(db: db, tenancyId: tenancy.id!, receiptNumber: row.receiptNumber)
                    ?? RentReceipt(tenancyId: tenancy.id!, receiptNumber: row.receiptNumber, periodStart: row.periodStart,
                                   periodEnd: row.periodEnd, receiptDate: row.receiptDate, amountMinorUnits: row.amountMinorUnits,
                                   status: row.status)
                let isNew = receipt.id == nil
                let before = receipt
                receipt.periodStart = PropertyDates.day(row.periodStart)
                receipt.periodEnd = PropertyDates.day(row.periodEnd)
                receipt.receiptDate = row.receiptDate.map(PropertyDates.day)
                receipt.amountMinorUnits = row.amountMinorUnits
                receipt.withholdingMinorUnits = row.withholdingMinorUnits
                receipt.amountReceivedMinorUnits = row.amountReceivedMinorUnits
                receipt.status = row.status
                if isNew {
                    try RentReceipts.save(db: db, &receipt)
                    report.createdReceipts += 1
                    if receipt.status == .cancelled { report.cancelledReceipts += 1 }
                } else if receipt != before {
                    try RentReceipts.save(db: db, &receipt)
                    report.updatedReceipts += 1
                    if receipt.status == .cancelled && before.status != .cancelled {
                        report.cancelledReceipts += 1
                        // A cancelled receipt takes no payments: its auto and manual links go
                        // (dismissed ones stay, so matching never remakes them).
                        report.removedPaymentLinks += try RentReceiptPayment.active.filter(Column("rentReceiptId") == receipt.id!).deleteAll(db)
                    } else if receipt.amountReceivedMinorUnits != before.amountReceivedMinorUnits {
                        let removed = try RentReceiptMatching.removeAutoLinks(db: db, receiptId: receipt.id!)
                        report.removedPaymentLinks += removed
                        report.clampedManualLinks += try clampManualLinks(db: db, receipt: receipt)
                        needsRematch = needsRematch || removed > 0
                    }
                } else {
                    report.unchangedReceipts += 1
                }
            }
            report.missingFromExport += try RentReceipts.receipts(db: db, tenancyId: tenancy.id!, includeCancelled: true)
                .filter { !listed.contains($0.receiptNumber) }
        }

        try closeEndedTenancies(db: db, propertyId: propertyId, contracts: Set(byContract.keys), report: &report)
        if needsRematch {
            report.rematchedPaymentLinks = try RentReceiptMatching.match(db: db, propertyId: propertyId, options: matchOptions).created.count
        }
        return report
    }

    /// Cuts the rent of the receipt's manual links (latest first) to its amount received; the
    /// cut part becomes other, so each credit stays fully allocated. Returns how many changed.
    private static func clampManualLinks(db: Database, receipt: RentReceipt) throws -> Int {
        var links = try RentReceiptPayment.active
            .filter(Column("rentReceiptId") == receipt.id! && Column("origin") == RentPaymentOrigin.manual.rawValue)
            .order(Column("id").desc).fetchAll(db)
        var excess = links.reduce(0) { $0 + $1.rentMinorUnits } - receipt.amountReceivedMinorUnits
        var changed = 0
        for index in links.indices where excess > 0 {
            let cut = min(excess, links[index].rentMinorUnits)
            links[index].rentMinorUnits -= cut
            links[index].otherMinorUnits += cut
            try links[index].update(db)
            excess -= cut
            changed += 1
        }
        return changed
    }

    /// The same import, rolled back: what `run` would report, writing nothing.
    public static func preview(db: Database, propertyId: Int64, rows: [RentReceiptsExport.Row],
                               matchOptions: RentReceiptMatching.Options = .init()) throws -> Report {
        var report = Report()
        try db.inSavepoint {
            report = try run(db: db, propertyId: propertyId, rows: rows, matchOptions: matchOptions)
            return .rollback
        }
        return report
    }

    private static func closeEndedTenancies(db: Database, propertyId: Int64, contracts: Set<String>, report: inout Report) throws {
        let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
        var lastEnd: [Int64: Date] = [:]
        var firstStart: [Int64: Date] = [:]
        for tenancy in tenancies {
            let issued = try RentReceipts.receipts(db: db, tenancyId: tenancy.id!)
            lastEnd[tenancy.id!] = issued.map(\.periodEnd).max()
            firstStart[tenancy.id!] = issued.map(\.periodStart).min()
        }
        for var tenancy in tenancies {
            guard let number = tenancy.contractNumber, contracts.contains(number), let end = lastEnd[tenancy.id!] else { continue }
            if let current = tenancy.endDate {
                // Receipts past the end (a later export extends it): the tenancy ran longer.
                guard end > current else { continue }
            } else {
                let followed = tenancies.contains { other in
                    other.id != tenancy.id && (firstStart[other.id!].map { $0 > end } ?? false)
                }
                guard followed else { continue }
            }
            tenancy.endDate = end
            try Tenancies.save(db: db, &tenancy)
            if !report.createdTenancies.contains(number) && !report.updatedTenancies.contains(number) {
                report.updatedTenancies.append(number)
            }
        }
    }
}
