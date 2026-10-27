import Foundation
import BudgetCore
import GRDB

/// Where an action on the This-month screen goes (step 10, Task 10): the built-in browser at a saved site, the Check and
/// link sheet for a downloaded file, or another screen of the iPad.
enum PadDestination: Equatable {
    /// The browser at the saved site of that kind; `name` (a provider's) picks among several.
    case site(SavedSiteKind, name: String?)
    case check(UUID)
    /// Bills & recharges: the bills grid.
    case billsAndRecharges
    /// Bills & recharges: the recharge statements (to email one, or link a payment by hand).
    case recharges
    case evidence
}

/// The iPad's This-month screen (step 10, Task 10): the selected tenancy's checklist as `ThisMonthChecklist` computes it
/// (nothing is stored or worked out here), with what each provider's bill is, and the charges so far. Reads only,
/// except "Confirm match", which links the tenant's transfer to last month's statement through the device writer.
@MainActor
public final class PadThisMonthModel: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var checklist: ThisMonthChecklist
        /// This month's bill per provider (`ProviderBill.id`), in `currency`.
        public var amounts: [String: Int]
        /// This month's statement total: what the checked bills put to recharge so far.
        public var rechargeSoFarMinorUnits: Int
        public var currency: Currency
    }

    @Published public private(set) var snapshot: Snapshot?
    public let property: PadPropertyModel
    public let write: PadWriteModel
    /// The downloads waiting (the browser's tray); empty where there is no browser.
    var trayItems: @MainActor () -> [TrayItem] = { [] }
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
    }

    public var checklist: ThisMonthChecklist? { snapshot?.checklist }
    public var tenancies: [Tenancy] { property.tenancies }
    public var selectedTenancyId: Int64? { property.selectedTenancyId }

    /// Shows an already read snapshot (the snapshot routes' first frame).
    /// Reading again then keeps it (`reload` does nothing).
    public func preload(_ snapshot: Snapshot?) {
        self.snapshot = snapshot
        isPreloaded = snapshot != nil
    }

    public func reload() async {
        guard !isPreloaded else { return }
        generation += 1
        let mine = generation
        guard let tenancyId = property.selectedTenancyId ?? property.tenancies.first?.id else {
            snapshot = nil
            return
        }
        let day = today()
        let tray = trayItems()
        let viewer = try? await write.writer?.actor()
        let reader = dbQueue
        guard let read = try? await reader.read({ db in
            try Self.read(db, tenancyId: tenancyId, today: day, tray: tray, viewer: viewer)
        }), mine == generation else { return }
        snapshot = read
    }

    /// The checklist of another tenancy.
    public func select(_ tenancyId: Int64) async {
        property.selectedTenancyId = tenancyId
        await reload()
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, tenancyId: Int64?, today: Date, tray: [TrayItem] = [],
                                           viewer: AccessActor? = nil) -> Snapshot? {
        guard let tenancyId else { return nil }
        return try? dbQueue.read { db in try read(db, tenancyId: tenancyId, today: today, tray: tray, viewer: viewer) }
    }

    nonisolated static func read(_ db: Database, tenancyId: Int64, today: Date, tray: [TrayItem], viewer: AccessActor?) throws -> Snapshot {
        let checklist = try ThisMonthChecklist.build(db: db, tenancyId: tenancyId, today: today, trayCount: tray.count, trayItems: tray, viewer: viewer)
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw RechargeError.tenancyNotFound }
        let currency = try Property.fetchOne(db, key: tenancy.propertyId)?.currency ?? .eur
        var amounts: [String: Int] = [:]
        if !checklist.isHidden {
            let grid = try UtilityBills.read(db: db, propertyId: tenancy.propertyId, tenancyId: tenancyId)
            for bill in grid.bills where bill.month == checklist.month {
                amounts[UtilityBills.key(bill.providerId), default: 0] += bill.amountMinorUnits
            }
        }
        let total = try checklist.statementId.flatMap { try RechargeStatement.fetchOne(db, key: $0) }?.totalMinorUnits ?? 0
        return Snapshot(checklist: checklist, amounts: amounts, rechargeSoFarMinorUnits: total, currency: currency)
    }

    // MARK: Actions

    /// Where `action` goes; nil for the one handled here (`confirmMatch`).
    func destination(for action: ThisMonthChecklist.ChecklistAction) -> PadDestination? {
        switch action {
        case .fetchStatement(let kind): return .site(kind, name: nil)
        case .openSite(let providerId): return .site(.utility, name: snapshot?.checklist.step(.billsIn)?.providers.first { $0.providerId == providerId }?.name)
        case .check(let id): return .check(id)
        case .prepareEmail, .markReceived: return .recharges
        case .confirmMatch: return nil
        }
    }

    /// Whether the screen offers `action`: browsing sites needs nothing; the rest change something and need Edit on
    /// Property (Check also needs Documents, `checkAllowed`).
    func offers(_ action: ThisMonthChecklist.ChecklistAction, checkAllowed: Bool = true) -> Bool {
        switch action {
        case .fetchStatement, .openSite: return true
        case .check: return write.canEdit && checkAllowed
        case .confirmMatch, .prepareEmail, .markReceived: return write.canEdit
        }
    }

    /// The saved site an "Open site" goes to: of `kind`, the one named like `name` (either contains the other, ignoring
    /// case and accents), else the first of that kind.
    static func site(in sites: [SavedSite], kind: SavedSiteKind, name: String?) -> SavedSite? {
        let ofKind = sites.filter { $0.kind == kind }
        func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        if let name = name.map(folded), !name.isEmpty,
           let named = ofKind.first(where: { let site = folded($0.name); return site.contains(name) || name.contains(site) }) {
            return named
        }
        return ofKind.first
    }

    /// Links the tenant's transfer to last month's statement (`Recharges.linkPayment`), as the Mac's matching does for an
    /// exact one. A refusal (a filed year, a credit with nothing left) shows under step 1.
    @discardableResult
    public func confirmMatch(transactionId: Int64) async -> Bool {
        guard let statementId = checklist?.lastStatementId else { return false }
        // What the statement's lines were paid with, and the credit: what the link can reach.
        let reader = dbQueue
        let paid = (try? await reader.read { db in
            try Recharges.lineDetails(db: db, statementId: statementId).flatMap { [$0.invoice?.transactionId, $0.line.transactionId] }.compactMap { $0 }
        }) ?? []
        let saved = await write.perform(rowId: Self.confirmRow, origin: .propertyMatching, edit: "Record payment",
                                        scope: FiledYearEditCheck.Scope(transactionIds: paid + [transactionId])) { db in
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: transactionId)
        }
        if saved { await reload() }
        return saved
    }

    static let confirmRow = "thisMonthStep1"
}
