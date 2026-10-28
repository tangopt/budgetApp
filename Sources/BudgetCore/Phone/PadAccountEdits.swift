import Foundation
import GRDB

/// An account write the iPad doesn't make.
public enum PadAccountError: Error, Equatable, LocalizedError {
    /// A joint account added by someone other than the household's admin.
    case jointNeedsAdmin

    public var errorDescription: String? {
        switch self {
        case .jointNeedsAdmin: return "Only the household's admin adds a joint account."
        }
    }
}

/// The iPad's account writes (step 11): add an account, edit its details, and set its sharing, each in one transaction
/// through `DeviceWriter.writeWithActor` in Budget & accounts. Outside the actor's Edit areas it throws `AccessDenied`,
/// on a filed return `DeviceWriteRefusal.filedYear`, and a sharing change the owner rule refuses its `SharingError`;
/// each writes nothing. There is no delete or archive here: deleting accounts stays on the Mac.
public enum PadAccountEdits {
    // MARK: Add

    /// Add account's Save (`AccountEditing.add`), as the actor: hers at her default level once ownership is confirmed,
    /// or joint (Everything) when `joint`, which only the household's admin may add (`PadAccountError.jointNeedsAdmin`
    /// otherwise). `manual` keeps its balance by hand (`.manual`), else from statements. The opening balance, when
    /// given, is its first snapshot dated `asOf`. Returns the new account's id.
    @discardableResult
    public static func add(writer: DeviceWriter, name: String, currency: Currency, kind: AccountKind, manual: Bool,
                           openingBalanceEntered: Int?, asOf: Date, details: AccountDetails, includeInNetWorth: Bool,
                           joint: Bool) async throws -> Int64 {
        let scope = openingBalanceEntered == nil ? FiledYearEditCheck.Scope() : FiledYearEditCheck.Scope(dates: [asOf])
        return try await writer.writeWithActor(.budgetAndAccounts, edit: "Add account", scope: scope) { db, actor in
            if joint, !actor.isAdmin { throw PadAccountError.jointNeedsAdmin }
            let account = try AccountEditing.add(db: db, name: name, currency: currency, kind: kind,
                                                 trackingMode: manual ? .manual : .imported,
                                                 openingBalanceEntered: openingBalanceEntered, asOf: asOf, details: details,
                                                 includeInNetWorth: includeInNetWorth, owner: actor, joint: joint)
            return account.id!
        }
    }

    // MARK: Edit

    /// Edit account's Save: the details (`AccountEditing.update`) and, when `sharing` is given, the owner or level
    /// (`AccountSharing.apply`: only the owner sets a level, only the admin moves it between theirs and Joint), in one
    /// transaction: both or neither. A kind or Count toward net worth change on a property-linked account is checked
    /// against every filed year.
    public static func update(writer: DeviceWriter, accountId: Int64, name: String, kind: AccountKind, details: AccountDetails,
                              includeInNetWorth: Bool, sharing: (owner: SharingSetup.Owner, level: SharingLevel)?) async throws {
        let viewer = writer.viewerNow()
        let scope = try await writer.reader.read { db in
            try updateScope(accountId: accountId, kind: kind, includeInNetWorth: includeInNetWorth, db: db)
        }
        try await writer.writeWithActor(.budgetAndAccounts, edit: "Edit account", scope: scope) { db, actor in
            // The other person's account seen below Everything: not hers to edit. Checked in the write's own transaction,
            // so a level synced in since the screen read can't slip past.
            if let account = try Account.fetchOne(db, key: accountId), try !viewer.resolve(db: db).seesInFull(account) {
                throw AccessDenied(area: .budgetAndAccounts)
            }
            try AccountEditing.update(db: db, accountId: accountId, name: name, kind: kind, details: details,
                                      includeInNetWorth: includeInNetWorth)
            if let sharing {
                try AccountSharing.apply(owner: sharing.owner, level: sharing.level, accountId: accountId, actor: actor, db: db,
                                         now: Date())
            }
        }
    }

    /// What an edit of the account reaches: every filed year when it changes a property-linked account's kind or
    /// Count toward net worth, else nothing. Reads only.
    static func updateScope(accountId: Int64, kind: AccountKind, includeInNetWorth: Bool, db: Database) throws -> FiledYearEditCheck.Scope {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw AccountEditError.accountNotFound }
        guard account.kind != kind || account.includeInNetWorth != includeInNetWorth,
              try SharingDefaults.isPropertyLinked(accountId: accountId, db: db) else { return FiledYearEditCheck.Scope() }
        return .everyYear
    }

    // MARK: Sharing

    /// The account's sharing as the device's user sees it (`AccountSharing.load`); nil with no actor.
    public static func sharingState(writer: DeviceWriter, dbReader: any DatabaseReader, accountId: Int64) async throws -> AccountSharing.State? {
        guard let actor = try await writer.actor() else { return nil }
        return try await dbReader.read { db in try AccountSharing.load(accountId: accountId, actor: actor, db: db) }
    }

    /// Whether the account's sharing controls show: it is the device's user's own (`State.canChangeLevel`) and she has
    /// Edit on Budget & accounts (false with no actor).
    public static func canSetSharing(accountId: Int64, writer: DeviceWriter, dbReader: any DatabaseReader) async throws -> Bool {
        guard let state = try await sharingState(writer: writer, dbReader: dbReader, accountId: accountId), state.canChangeLevel else { return false }
        return await writer.canEdit(.budgetAndAccounts)
    }
}
