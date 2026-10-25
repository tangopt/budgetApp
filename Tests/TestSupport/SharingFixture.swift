import Foundation
import GRDB
import BudgetCore

/// A small household for zone routing (step 6): admin A and member B; accounts *Shared* (A, Everything),
/// *Joint* (no owner), *Private* (A, Balance only), *Totals* (A, Category totals) and *Lisbon* (A, Everything,
/// linked to the property). Ownership is confirmed through `SharingSetup.save`. Synthetic names only.
///
/// Rows: one import run holding Private's batch, another holding every other account's batch; a transaction
/// in each account; on Private a plain one, a property-category one paid by a rent receipt, and a plain one
/// pinned by a tax owner; a transfer from Shared to Private; one document linked to Private's plain
/// transaction only, another linked to it and to Shared's.
public struct SharingFixture {
    public var personA: Int64
    public var personB: Int64
    public var personAUuid: String
    public var admin: AccessActor

    public var shared: Int64
    public var joint: Int64
    public var privateAccount: Int64
    public var totals: Int64
    public var lisbon: Int64
    public var propertyId: Int64

    public var propertyCategory: Int64
    public var plainCategory: Int64
    public var privateRun: Int64
    public var sharedRun: Int64
    public var privateBatch: Int64

    /// Transactions.
    public var sharedTransaction: Int64
    public var jointTransaction: Int64
    public var totalsTransaction: Int64
    public var lisbonTransaction: Int64
    public var privateTransaction: Int64
    public var privatePropertyTransaction: Int64
    public var privatePinnedTransaction: Int64
    public var transferOut: Int64
    public var transferIn: Int64
    public var transferLink: Int64

    public var rentReceiptPayment: Int64
    public var taxTransactionOwner: Int64
    public var privateOnlyDocument: Int64
    public var sharedDocument: Int64

    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    public static func build(_ db: Database) throws -> SharingFixture {
        try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
        let personA = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person B')")
        let personB = db.lastInsertedRowID
        var adminUser = AppUser(personId: personA, displayName: "A", isAdmin: true, createdAt: day)
        try adminUser.insert(db)
        var memberUser = AppUser(personId: personB, displayName: "B", isAdmin: false, createdAt: day)
        try memberUser.insert(db)
        let admin = try AccessActor.load(appUserId: adminUser.id!, db: db)

        func account(_ name: String) throws -> Int64 {
            try AccountEditing.add(db: db, name: name, currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: day).id!
        }
        let shared = try account("Synthetic shared")
        let joint = try account("Synthetic joint")
        let privateAccount = try account("Synthetic private")
        let totals = try account("Synthetic totals")
        let lisbon = try account("Synthetic flat account")
        try db.execute(sql: "UPDATE account SET sortCode = '000000', accountNumber = '00000000' WHERE id = ?", arguments: [privateAccount])

        try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
        let propertyId = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO propertyAccount(propertyId, accountId, role) VALUES (?, ?, 'current')", arguments: [propertyId, lisbon])
        try db.execute(sql: "INSERT INTO categoryGroup(name, type) VALUES ('Synthetic flat costs', 'expense')")
        let propertyGroup = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO propertyCategoryGroup(propertyId, categoryGroupId) VALUES (?, ?)", arguments: [propertyId, propertyGroup])
        try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Synthetic flat rent', 'income', ?)", arguments: [propertyGroup])
        let propertyCategory = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO categoryGroup(name, type) VALUES ('Synthetic everyday', 'expense')")
        let plainGroup = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Synthetic groceries', 'expense', ?)", arguments: [plainGroup])
        let plainCategory = db.lastInsertedRowID

        let rows = try SharingSetup.proposal(admin: admin, db: db).map { row -> SharingSetup.Row in
            var row = row
            switch row.id {
            case shared: row.level = .everything
            case joint: row.owner = .joint; row.level = .everything
            case privateAccount: row.level = .balanceOnly
            case totals: row.level = .categoryTotals
            default: break  // Lisbon: property-linked, Everything by default
            }
            return row
        }
        try SharingSetup.save(rows, admin: admin, db: db, now: day)

        func run() throws -> Int64 {
            try db.execute(sql: "INSERT INTO importRun(confirmedAt, entryPoint, summary) VALUES (?, 'documents', 'Synthetic run')", arguments: [day])
            return db.lastInsertedRowID
        }
        let privateRun = try run()
        let sharedRun = try run()
        func batch(_ account: Int64, _ run: Int64) throws -> Int64 {
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt, importRunId) VALUES (?, 'synthetic.csv', ?, ?)",
                           arguments: [account, day, run])
            return db.lastInsertedRowID
        }
        let privateBatch = try batch(privateAccount, privateRun)
        var batches = [privateAccount: privateBatch]
        for account in [shared, joint, totals, lisbon] { batches[account] = try batch(account, sharedRun) }
        var fingerprint = 0
        func transaction(_ account: Int64, _ amount: Int, category: Int64?) throws -> Int64 {
            fingerprint += 1
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic', ?, ?, 'confirmed', 'rule', ?)
                """, arguments: [batches[account], account, day, amount, category, "fp-\(fingerprint)"])
            return db.lastInsertedRowID
        }
        let sharedTransaction = try transaction(shared, -1_000, category: plainCategory)
        let jointTransaction = try transaction(joint, -2_000, category: plainCategory)
        let totalsTransaction = try transaction(totals, -3_000, category: plainCategory)
        let lisbonTransaction = try transaction(lisbon, 50_000, category: propertyCategory)
        let privateTransaction = try transaction(privateAccount, -4_000, category: plainCategory)
        let privatePropertyTransaction = try transaction(privateAccount, 60_000, category: propertyCategory)
        let privatePinnedTransaction = try transaction(privateAccount, -5_000, category: plainCategory)
        let transferOut = try transaction(shared, -10_000, category: nil)
        let transferIn = try transaction(privateAccount, 10_000, category: nil)
        try db.execute(sql: "INSERT INTO transferLink(outTransactionId, inTransactionId, origin) VALUES (?, ?, 'auto')",
                       arguments: [transferOut, transferIn])
        let transferLink = db.lastInsertedRowID

        try db.execute(sql: "INSERT INTO tenancy(propertyId, referenceLabel, startDate) VALUES (?, 'Synthetic tenancy', ?)", arguments: [propertyId, day])
        let tenancy = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO rentReceipt(tenancyId, receiptNumber, periodStart, periodEnd, amountMinorUnits, amountReceivedMinorUnits)
            VALUES (?, 'R-1', ?, ?, 60000, 60000)
            """, arguments: [tenancy, day, day])
        let receipt = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO rentReceiptPayment(rentReceiptId, transactionId, rentMinorUnits, origin) VALUES (?, ?, 60000, 'auto')",
                       arguments: [receipt, privatePropertyTransaction])
        let rentReceiptPayment = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO taxTransactionOwner(transactionId, personId) VALUES (?, ?)", arguments: [privatePinnedTransaction, personA])
        let taxTransactionOwner = db.lastInsertedRowID

        func document(_ hash: String) throws -> Int64 {
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'synthetic.pdf', 1, ?)
                """, arguments: [hash, "aa/\(hash).pdf", day])
            return db.lastInsertedRowID
        }
        func link(_ document: Int64, _ transaction: Int64) throws {
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [document, transaction, day])
        }
        let privateOnlyDocument = try document(String(repeating: "1", count: 64))
        try link(privateOnlyDocument, privateTransaction)
        let sharedDocument = try document(String(repeating: "2", count: 64))
        try link(sharedDocument, privateTransaction)
        try link(sharedDocument, sharedTransaction)

        let personAUuid = try SyncRecordStore.uuid(for: "person", localId: personA, db: db)
        return SharingFixture(personA: personA, personB: personB, personAUuid: personAUuid, admin: admin,
                              shared: shared, joint: joint, privateAccount: privateAccount, totals: totals, lisbon: lisbon,
                              propertyId: propertyId, propertyCategory: propertyCategory, plainCategory: plainCategory,
                              privateRun: privateRun, sharedRun: sharedRun, privateBatch: privateBatch,
                              sharedTransaction: sharedTransaction, jointTransaction: jointTransaction, totalsTransaction: totalsTransaction,
                              lisbonTransaction: lisbonTransaction, privateTransaction: privateTransaction,
                              privatePropertyTransaction: privatePropertyTransaction, privatePinnedTransaction: privatePinnedTransaction,
                              transferOut: transferOut, transferIn: transferIn, transferLink: transferLink,
                              rentReceiptPayment: rentReceiptPayment, taxTransactionOwner: taxTransactionOwner,
                              privateOnlyDocument: privateOnlyDocument, sharedDocument: sharedDocument)
    }

    /// Person A's private zone.
    public var privateZone: String { SyncZones.privateZone(personUuid: personAUuid) }
}
