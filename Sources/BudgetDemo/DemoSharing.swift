import Foundation
import GRDB
import BudgetCore

/// The demo's sharing set-up (step 6), so its screens show owners, levels and summaries: Person A is the admin
/// (an app user named "A" with no password is made when the demo has none) and owns every account, saved
/// through the ownership sheet's own rules (`SharingSetup.save`): "Rainy Day Saver" joint, "Travel Card" at
/// Category totals, "Everyday Current" at Balance only, the rest at their defaults (property accounts at
/// Everything, the other personal ones at Balance only). The summaries are then rebuilt, as the Mac does
/// before a push. Person A owns or shares every account, so the demo's figures for A are the local ledger's.
public enum DemoSharing {
    public static let adminDisplayName = "A"
    public static let jointAccount = "Rainy Day Saver"
    public static let categoryTotalsAccount = "Travel Card"
    public static let balanceOnlyAccount = "Everyday Current"

    public static func apply(db: Database, now: Date) throws {
        guard let personA = try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personA]) else { return }
        if try AppUser.filter(Column("isAdmin") == true).fetchCount(db) == 0 {
            var admin = AppUser(personId: personA, displayName: adminDisplayName, isAdmin: true, createdAt: now)
            try admin.insert(db)
        }
        let admin = try AccessActor.admin(db: db)
        guard try !SharingSetup.isConfirmed(db: db) else { return }
        let names = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { account in account.id.map { ($0, account.name) } })
        let rows = try SharingSetup.proposal(admin: admin, db: db).map { row -> SharingSetup.Row in
            var row = row
            switch names[row.id] {
            case jointAccount?:
                row.owner = .joint
                row.level = .everything
            case categoryTotalsAccount?:
                row.level = .categoryTotals
            case balanceOnlyAccount?:
                row.level = .balanceOnly
            default:
                break
            }
            return row
        }
        try SharingSetup.save(rows, admin: admin, db: db, now: now)
        try AccountSummaryBuilder.rebuild(ownerPersonId: admin.personId, db: db, today: now)
    }
}
