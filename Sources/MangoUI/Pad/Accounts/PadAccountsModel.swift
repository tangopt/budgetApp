import Foundation
import BudgetCore
import GRDB

/// What the iPad's Accounts screen can offer on an account (step 11).
public enum PadAccountAction: Hashable, Sendable {
    case addAccount, editDetails, setSharing, updateBalance, fetchStatement
}

/// The iPad's Accounts screen (step 11, Task 2): the selected account beside the list, and which actions each account
/// offers. The figures are `AccountsViewModel`'s (the iPhone's); every control is offered only with Edit on Budget &
/// accounts, and never on an account the viewer doesn't see in full (the other person's, below Everything): the writer
/// refuses those too (`AccessDenied`), this keeps them from showing. With no writer (demo data) nothing is offered.
@MainActor
public final class PadAccountsModel: ObservableObject {
    public let accounts: AccountsViewModel
    public let write: PadWriteModel
    @Published public var selectedId: Int64?
    /// The built-in browser exists (not on demo data): "Fetch statement" needs it. Set by the screen.
    public var offersBrowser = true
    /// The transaction open in its sheet, with the first document linked to it.
    @Published public private(set) var openTransaction: OpenTransaction?
    private let dbQueue: any DatabaseReader
    /// The form open in its sheet (Add account or Edit): nothing is written until its Save.
    @Published public var form: OpenForm?

    public struct OpenForm: Identifiable {
        public let id = UUID()
        public let model: PadAccountFormModel
    }

    public struct OpenTransaction: Identifiable, Equatable, Sendable {
        public var row: TransactionSearch.Row
        public var documentId: Int64?
        /// Every document linked to the transaction (the panel lists them, the first previewed).
        public var documents: [TransactionDocument] = []
        public var id: Int64 { row.id }
    }

    public init(accounts: AccountsViewModel, write: PadWriteModel, dbQueue: any DatabaseReader) {
        self.accounts = accounts
        self.write = write
        self.dbQueue = dbQueue
    }

    /// The actions the account offers the device's user: none without Edit, or when it isn't hers to change.
    public func actions(for accountId: Int64) async -> Set<PadAccountAction> {
        guard let writer = write.writer, await writer.canEdit(.budgetAndAccounts), await seesInFull(accountId) else { return [] }
        var actions: Set<PadAccountAction> = [.addAccount, .editDetails]
        if offersBrowser { actions.insert(.fetchStatement) }
        if await PhoneQuickEdits.canUpdateBalance(accountId: accountId, writer: writer, dbReader: dbQueue) { actions.insert(.updateBalance) }
        if (try? await PadAccountEdits.canSetSharing(accountId: accountId, writer: writer, dbReader: dbQueue)) == true { actions.insert(.setSharing) }
        return actions
    }

    /// Opens Add account.
    public func openAddForm() {
        write.clearRefusal(rowId: PadAccountFormModel.rowId)
        form = OpenForm(model: PadAccountFormModel(mode: .add, write: write, dbQueue: dbQueue))
    }

    /// Opens Edit details for the account, from its stored details (nothing when it is gone).
    public func openEditForm(accountId: Int64) async {
        guard let account = try? await dbQueue.read({ db in try Account.fetchOne(db, key: accountId) }) else { return }
        write.clearRefusal(rowId: PadAccountFormModel.rowId)
        form = OpenForm(model: PadAccountFormModel(mode: .edit(account), write: write, dbQueue: dbQueue))
    }

    /// A form saved: the list and the account's detail read again; a new account is the selected one.
    public func formSaved(_ saved: PadAccountFormModel) async {
        await accounts.load()
        if let added = saved.addedId { selectedId = added }
        if let id = saved.addedId ?? saved.editedId {
            await accounts.detailModel(for: AccountDestination(accountId: id)).load()
        }
    }

    /// "Add account" shows above the list: Edit on Budget & accounts.
    public func canAdd() async -> Bool {
        guard let writer = write.writer else { return false }
        return await writer.canEdit(.budgetAndAccounts)
    }

    /// The viewer sees the account in full (its owner's choice is Everything, or it is hers).
    private func seesInFull(_ accountId: Int64) async -> Bool {
        let viewer = accounts.viewer
        return (try? await dbQueue.read { db in
            guard let account = try Account.fetchOne(db, key: accountId) else { return false }
            return try viewer.resolve(db: db).seesInFull(account)
        }) ?? false
    }

    /// The Details card (bank, number, kind, how the balance is kept, sharing) shows: the viewer sees the account in full
    /// and is a known person (demo data's admin, tests' everyone). The other person's account below Everything, or any
    /// account while this device's user isn't named yet, shows no details, as on the iPhone.
    public func showsDetails(for accountId: Int64) async -> Bool {
        let viewer = accounts.viewer
        return (try? await dbQueue.read { db in
            guard let account = try Account.fetchOne(db, key: accountId) else { return false }
            return Self.showsDetails(account, seer: try viewer.resolve(db: db))
        }) ?? false
    }

    nonisolated static func showsDetails(_ account: Account, seer: SharingViewer) -> Bool {
        if seer.personId == nil, seer.strict { return false }
        return seer.seesInFull(account)
    }

    /// The account's sharing as the device's user sees it; nil with no writer or actor.
    public func sharing(for accountId: Int64) async -> AccountSharing.State? {
        guard let writer = write.writer else { return nil }
        return try? await PadAccountEdits.sharingState(writer: writer, dbReader: dbQueue, accountId: accountId)
    }

    /// Opens `row` in its sheet, with its first linked document in the document panel.
    public func open(_ row: TransactionSearch.Row) async {
        let id = row.id
        let reader = dbQueue
        let documents = (try? await reader.read { db in
            try TransactionDocuments.documents(db: db, transactionId: id, catalog: try DocumentKindCatalog.load(db: db))
        }) ?? []
        openTransaction = OpenTransaction(row: row, documentId: documents.first?.id, documents: documents)
    }

    /// `row` opened as the sheet shows it, read now (the snapshot routes).
    public nonisolated static func openNow(_ dbQueue: any DatabaseReader, row: TransactionSearch.Row) -> OpenTransaction {
        let id = row.id
        let documents = (try? dbQueue.read { db in
            try TransactionDocuments.documents(db: db, transactionId: id, catalog: try DocumentKindCatalog.load(db: db))
        }) ?? []
        return OpenTransaction(row: row, documentId: documents.first?.id, documents: documents)
    }

    public func closeTransaction() {
        openTransaction = nil
    }

    /// The Sharing line: the level and the owner ("Everything · Synthetic Person A", "Everything · Joint"); nil unless
    /// the viewer sees the account in full.
    public func sharingLine(for accountId: Int64) async -> String? {
        let viewer = accounts.viewer
        return try? await dbQueue.read { db -> String? in
            guard let account = try Account.fetchOne(db, key: accountId), try viewer.resolve(db: db).seesInFull(account) else { return nil }
            let owner = try account.ownerPersonId.flatMap { try Person.fetchOne(db, key: $0)?.name }
            return Self.sharingLine(level: account.sharingLevel, ownerName: account.ownerPersonId == nil ? "Joint" : owner)
        }
    }

    nonisolated static func sharingLine(level: SharingLevel, ownerName: String?) -> String {
        [level.title, ownerName].compactMap { $0 }.joined(separator: " · ")
    }

    /// An account number as the detail shows it: the last four characters after bullets ("•••• 4567"); short ones whole.
    nonisolated static func masked(_ number: String) -> String {
        let trimmed = number.filter { !$0.isWhitespace && $0 != "-" }
        return trimmed.count > 4 ? "•••• " + trimmed.suffix(4) : trimmed
    }

    public func detailModel(for accountId: Int64) -> AccountDetailModel {
        accounts.detailModel(for: AccountDestination(accountId: accountId))
    }

    /// The saved site "Fetch statement" opens: a bank site whose name or host matches the account's bank name, else nil
    /// (the sites strip opens).
    nonisolated static func bankSite(in sites: [SavedSite], bankName: String?) -> SavedSite? {
        guard let bank = bankName.map(Self.folded), !bank.isEmpty else { return nil }
        return sites.first { site in
            let host = Self.folded(site.url.host ?? "")
            return host.contains(bank.replacingOccurrences(of: " ", with: "")) || Self.folded(site.name).contains(bank) || bank.contains(Self.folded(site.name))
        }
    }

    private nonisolated static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}
