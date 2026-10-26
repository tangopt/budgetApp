import Foundation
import GRDB

/// One person per Mac user (sync spec §3.1, step 6 review I1): a database that holds another person's private
/// records (their accounts below Everything, as the owner's own devices keep them) is that person's, so nobody else
/// signs in to it. Fails closed: the screens never have to hide someone else's ledger from the person signed in.
/// A database holding only what the household shares (stubs and summaries of the other person's private accounts,
/// §10 property money) lets anyone in the household sign in.
public enum SharingSignIn {
    /// Why `personId` can't sign in to this database, or nil when they can.
    public static func refusal(personId: Int64, db: Database) throws -> String? {
        try holdsOthersPrivateRecords(personId: personId, db: db) ? SharingCopy.otherPersonsMacUser : nil
    }

    /// Whether the database holds a record the zone router places in another person's private zone: a row of one of
    /// their accounts below Everything (its transactions, statements, balances, plan entries) that the household
    /// doesn't get.
    public static func holdsOthersPrivateRecords(personId: Int64, db: Database) throws -> Bool {
        try !othersPrivateRecords(personId: personId, db: db, first: true).isEmpty
    }

    /// Every such record, by table (account records only), in table and id order: what this database holds that the
    /// other person's device for `personId` would never get.
    public static func othersPrivateRecords(personId: Int64, db: Database) throws -> [(table: String, id: Int64)] {
        try othersPrivateRecords(personId: personId, db: db, first: false)
    }

    private static func othersPrivateRecords(personId: Int64, db: Database, first: Bool) throws -> [(table: String, id: Int64)] {
        let accounts = try Int64.fetchAll(db, sql: """
            SELECT id FROM account WHERE ownerPersonId IS NOT NULL AND ownerPersonId != ? AND sharingLevel != ?
            """, arguments: [personId, SharingLevel.everything.rawValue])
        guard !accounts.isEmpty else { return [] }
        let router = try SyncZoneRouter(db: db)
        let list = accounts.map(String.init).joined(separator: ",")
        var found: [(table: String, id: Int64)] = []
        for table in SyncZoneRouter.accountRecordTables.sorted() where try db.tableExists(table) {
            guard try db.columns(in: table).contains(where: { $0.name == "accountId" }) else { continue }
            // Rows this device made for itself and never sends (the placeholder batch shared transactions of a private
            // batch are filed under) aren't the other person's records.
            for id in try Int64.fetchAll(db, sql: """
                SELECT id FROM \(table) WHERE accountId IN (\(list))
                  AND id NOT IN (SELECT localId FROM syncRecord WHERE tableName = ? AND zone = ?)
                ORDER BY id
                """, arguments: [table, SyncZoneSet.deviceOnlyZone]) where try router.assignment(table: table, localId: id).isPrivate {
                found.append((table, id))
                if first { return found }
            }
        }
        return found
    }
}
