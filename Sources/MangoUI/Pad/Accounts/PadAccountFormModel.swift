import Foundation
import BudgetCore
import GRDB

/// The iPad's Add account and Edit details forms (step 11, Task 3): a draft over `PadAccountEdits`. Validation lives in
/// BudgetCore (`AccountDetails.errors`, `AccountEditing`'s name and credit rules, `AccountSharing.preview`); this keeps the
/// draft, says what is wrong before Save, and saves in one transaction on Save only: Cancel (or a dismiss) writes nothing.
/// A refusal is kept under `PadAccountFormModel.rowId` and the form stays. There is no delete or archive on the iPad.
@MainActor
public final class PadAccountFormModel: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case add
        case edit(Account)
    }

    /// What the form reads before it shows: who is writing, the other accounts' names, whether the account has a history,
    /// and (editing) its sharing.
    public struct Context: Equatable, Sendable {
        public var isAdmin = false
        /// The other accounts' names, folded for comparing.
        public var otherNames: Set<String> = []
        public var hasHistory = true
        public var sharing: AccountSharing.State?

        public init(isAdmin: Bool = false, otherNames: Set<String> = [], hasHistory: Bool = true, sharing: AccountSharing.State? = nil) {
            self.isAdmin = isAdmin
            self.otherNames = otherNames
            self.hasHistory = hasHistory
            self.sharing = sharing
        }
    }

    /// The row a refusal is kept under in `PadWriteModel`.
    public static let rowId = "account-form"

    public let mode: Mode
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    @Published public private(set) var context: Context

    // The draft.
    @Published public var name: String
    @Published public var kind: AccountKind
    @Published public var currency: Currency = .gbp
    /// Add: the balance is kept by hand ("Updated by hand"), else from statements.
    @Published public var updatedByHand = false
    @Published public var includeInNetWorth: Bool
    @Published public var balanceText = ""
    @Published public var asOf: Date
    @Published public var joint = false
    @Published public var details: AccountDetails
    /// Add: the region follows the currency until it is picked.
    @Published public private(set) var regionChosen: Bool
    /// Editing: the sharing draft (owner Joint, and the level).
    @Published public var sharingJoint = false
    @Published public var sharingLevel: SharingLevel = .everything
    @Published public private(set) var preview: AccountSharing.Preview?
    @Published public private(set) var isSaving = false
    /// Set once Save was pressed with something wrong: every error shows.
    @Published public private(set) var revealErrors = false
    /// The new account's id, after an Add.
    @Published public private(set) var addedId: Int64?

    public init(mode: Mode, write: PadWriteModel, dbQueue: any DatabaseReader, context: Context = Context(), today: Date = Date()) {
        self.mode = mode
        self.write = write
        self.dbQueue = dbQueue
        self.context = context
        asOf = today
        switch mode {
        case .add:
            name = ""
            kind = .cash
            includeInNetWorth = true
            details = AccountDetails(region: .forCurrency(.gbp))
            regionChosen = false
        case .edit(let account):
            name = account.name
            kind = account.kind
            includeInNetWorth = account.includeInNetWorth
            currency = account.currency
            details = AccountDetails(account)
            regionChosen = true
        }
        applySharing(context.sharing)
    }

    // MARK: Loading

    /// Reads the context as the device's user: her admin status, the other names, the history and the sharing.
    public func load() async {
        guard let writer = write.writer else { return }
        let actor = try? await writer.actor()
        let accountId = editedId
        let loaded = try? await dbQueue.read { db in try Self.readContext(db: db, actor: actor, accountId: accountId) }
        if let loaded { setContext(loaded) }
    }

    /// The context as `actor` sees it. Reads only (also the snapshot routes').
    public nonisolated static func readContext(db: Database, actor: AccessActor?, accountId: Int64?) throws -> Context {
        var context = Context(isAdmin: actor?.isAdmin ?? false)
        context.otherNames = Set(try Account.fetchAll(db).filter { $0.id != accountId }.map { folded($0.name) })
        if let accountId {
            context.hasHistory = try AccountEditing.hasHistory(db: db, accountId: accountId)
            if let actor { context.sharing = try AccountSharing.load(accountId: accountId, actor: actor, db: db) }
        } else {
            context.hasHistory = false
        }
        return context
    }

    /// Shows an already read context (the snapshot routes).
    public func preload(_ context: Context) {
        setContext(context)
    }

    private func setContext(_ new: Context) {
        let sharingChanged = new.sharing != context.sharing
        context = new
        if sharingChanged { applySharing(new.sharing) }
    }

    private func applySharing(_ state: AccountSharing.State?) {
        guard let state else { return }
        sharingJoint = state.owner == .joint
        sharingLevel = state.level
        preview = nil
    }

    /// The account being edited.
    public var editedId: Int64? {
        if case .edit(let account) = mode { return account.id }
        return nil
    }

    private var existing: Account? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    public var isAdding: Bool { existing == nil }

    // MARK: What the form shows

    /// The kinds the picker offers: with a history, no move to or from credit.
    public var kindChoices: [AccountKind] {
        let all: [AccountKind] = [.cash, .investment, .credit]
        guard let existing, context.hasHistory else { return all }
        return all.filter { ($0 == .credit) == (existing.kind == .credit) }
    }

    /// Add account's Joint toggle: only the household's admin adds a joint account.
    public var showsJointToggle: Bool { isAdding && context.isAdmin }

    /// The Sharing section: editing an account the signed-in person may set the owner or the level of.
    public var showsSharing: Bool {
        guard let state = context.sharing else { return false }
        return state.canChangeOwner || state.canChangeLevel
    }

    public var showsOwnerPicker: Bool { context.sharing?.canChangeOwner == true }

    public var showsLevelPicker: Bool {
        guard let state = context.sharing, !sharingJoint else { return false }
        return state.canChangeLevel || state.canChangeOwner
    }

    /// Moves the owner picker; the level follows (Joint is Everything, else the account's default).
    public func setSharingJoint(_ isJoint: Bool) {
        guard let state = context.sharing else { return }
        let choice = state.choosing(joint: isJoint)
        sharingJoint = isJoint
        sharingLevel = choice.level
    }

    /// The owner and level the draft would save; nil when sharing isn't shown or nothing changes.
    public var sharingChange: (owner: SharingSetup.Owner, level: SharingLevel)? {
        guard showsSharing, let state = context.sharing else { return nil }
        let owner: SharingSetup.Owner = sharingJoint ? .joint : .person(state.personId)
        let level = sharingJoint ? SharingLevel.everything : sharingLevel
        guard owner != state.owner || level != state.level else { return nil }
        return (owner, level)
    }

    /// The draft level is below the stored one: the warning shows before Save.
    public var isLowering: Bool {
        guard let state = context.sharing, let change = sharingChange else { return false }
        return change.level < state.level
    }

    /// Counts what the draft sharing would move (`AccountSharing.preview`); the form calls it as the draft changes.
    public func refreshPreview() async {
        guard let id = editedId, let change = sharingChange else { preview = nil; return }
        preview = try? await dbQueue.read { db in try AccountSharing.preview(accountId: id, owner: change.owner, level: change.level, db: db) }
    }

    /// The lowering warning and the count, once the preview is read.
    public func loweringWarning() -> String? {
        guard let state = context.sharing, preview?.isLowering == true else { return nil }
        return SharingCopy.lowerWarning(otherName: state.otherName)
    }

    public func blockerLines() -> [String] {
        (preview?.blockers ?? []).map(SharingCopy.blocker)
    }

    // MARK: Checks

    nonisolated static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBalance: String { balanceText.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var openingBalance: Int? { Money.parseMinorUnits(trimmedBalance) }
    public var balanceError: String? {
        isAdding && !trimmedBalance.isEmpty && openingBalance == nil ? "Enter an amount such as 1,250.00." : nil
    }

    public var nameError: String? {
        guard !trimmedName.isEmpty else { return nil }
        return context.otherNames.contains(Self.folded(name)) ? "An account with that name already exists." : nil
    }

    /// Each bank field's problem (a stored value that predates a rule passes until it is edited).
    public var detailErrors: [BankDetailField: AccountDetailsError] { details.errors(existing: existing) }

    public func detailError(_ field: BankDetailField) -> String? { detailErrors[field]?.errorDescription }

    public var errors: [String] {
        var lines: [String] = []
        if let nameError { lines.append(nameError) }
        if let balanceError { lines.append(balanceError) }
        lines += BankDetailField.allCases.compactMap { detailError($0) }
        lines += blockerLines()
        return lines
    }

    public var canSave: Bool {
        !trimmedName.isEmpty && nameError == nil && balanceError == nil && detailErrors.isEmpty && kindChoices.contains(kind)
            && preview?.isBlocked != true && !isSaving
    }

    /// Save stays pressable once there is a name, so pressing it can say what is wrong.
    public var canPressSave: Bool { !trimmedName.isEmpty && !isSaving }

    public func setRegion(_ region: BankRegion) {
        details.region = region
        regionChosen = true
    }

    public func setCurrency(_ new: Currency) {
        currency = new
        if !regionChosen { details.region = .forCurrency(new) }
    }

    // MARK: Save

    /// Saves in one transaction (the details and the sharing together): true when it saved. A refusal stays under `rowId`.
    @discardableResult
    public func save() async -> Bool {
        guard canSave, let writer = write.writer else {
            if !canSave { revealErrors = true }
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            switch mode {
            case .add:
                addedId = try await PadAccountEdits.add(
                    writer: writer, name: name, currency: currency, kind: kind, manual: updatedByHand,
                    openingBalanceEntered: trimmedBalance.isEmpty ? nil : openingBalance, asOf: QuickEditModel.snapshotDay(asOf),
                    details: details, includeInNetWorth: includeInNetWorth, joint: joint && context.isAdmin)
            case .edit(let account):
                try await PadAccountEdits.update(writer: writer, accountId: account.id ?? 0, name: name, kind: kind, details: details,
                                                 includeInNetWorth: includeInNetWorth, sharing: sharingChange)
            }
            write.clearRefusal(rowId: Self.rowId)
            await write.refresh()
            return true
        } catch {
            write.refuse(rowId: Self.rowId, message: Self.message(for: error))
            if error is AccessDenied { await write.refresh() }
            return false
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case let error as AccountDetailsError: return error.errorDescription ?? "Check the account details."
        case let error as SharingError: return SharingCopy.error(error)
        case let error as AccountEditError:
            switch error {
            case .emptyName: return "Enter a name."
            case .duplicateName: return "An account with that name already exists."
            case .creditKindChange: return "Can't change to or from credit once the account has balances or transactions."
            case .accountNotFound: return "That account no longer exists."
            }
        default: return PadWriteModel.text(for: error)
        }
    }
}
