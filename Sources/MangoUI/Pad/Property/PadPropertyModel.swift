import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Property

/// What the iPad's Property screens read (step 8, Task 7): the property's tenancies (the current one first), which
/// one is selected, and that tenancy's utility bills grid, as the Mac's `UtilityBills.read` has it. Nothing here
/// computes a figure.
@MainActor
public final class PadPropertyModel: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var property: Property?
        public var tenancies: [Tenancy]
        public var bills: UtilityBillsGrid?
    }

    @Published public private(set) var property: Property?
    @Published public private(set) var tenancies: [Tenancy] = []
    @Published public var selectedTenancyId: Int64? {
        didSet { if oldValue != selectedTenancyId, loaded { Task { await reload() } } }
    }
    @Published public private(set) var bills: UtilityBillsGrid?
    /// A cell chosen in the bills grid, for the actions of Task 8.
    @Published public var selectedCellId: String?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var loaded = false
    private var generation = 0

    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.dbQueue = dbQueue
        self.today = today
    }

    /// Already loaded (the snapshot routes).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, preloaded snapshot: Snapshot, selected: Int64?) {
        self.dbQueue = dbQueue
        self.today = today
        property = snapshot.property
        tenancies = snapshot.tenancies
        bills = snapshot.bills
        selectedTenancyId = selected ?? snapshot.tenancies.first?.id
        loaded = true
    }

    /// Shows an already read snapshot (the snapshot routes' first frame).
    public func preload(_ snapshot: Snapshot) {
        property = snapshot.property
        tenancies = snapshot.tenancies
        bills = snapshot.bills
        loaded = false
        selectedTenancyId = snapshot.tenancies.first?.id
        loaded = true
    }

    public var selectedTenancy: Tenancy? { tenancies.first { $0.id == selectedTenancyId } }

    /// The newest read under way. A read overtaken by a newer one (`selectedTenancyId` starts its own, unawaited, when it
    /// changes) waits for that one instead of returning with nothing applied, so `await reload()` always comes back with
    /// the latest data in place (a save that selects the tenancy it created reads it back right after).
    private var latest: Task<Void, Never>?

    public func reload() async {
        generation += 1
        let mine = generation
        let task = Task { await self.read(generation: mine) }
        latest = task
        await task.value
    }

    private func read(generation mine: Int) async {
        let day = today()
        let selected = selectedTenancyId
        let reader = dbQueue
        guard let snapshot = try? await reader.read({ db in try Self.read(db, today: day, selected: selected) }) else { return }
        guard mine == generation else {
            await latest?.value
            return
        }
        property = snapshot.property
        tenancies = snapshot.tenancies
        bills = snapshot.bills
        loaded = true
        let ids = snapshot.tenancies.compactMap(\.id)
        let wanted = selected.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        if wanted != selectedTenancyId {
            loaded = false
            selectedTenancyId = wanted
            loaded = true
            if wanted != selected { await reload() }
        }
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date, selected: Int64? = nil) -> Snapshot {
        (try? dbQueue.read { db in try read(db, today: today, selected: selected) })
            ?? Snapshot(property: nil, tenancies: [], bills: nil)
    }

    /// The first property's tenancies, the current one first (then latest start first), and the bills grid of the
    /// selected one (the first when none or gone).
    nonisolated static func read(_ db: Database, today: Date, selected: Int64?) throws -> Snapshot {
        guard let property = try Property.order(Column("name")).fetchOne(db), let propertyId = property.id else {
            return Snapshot(property: nil, tenancies: [], bills: nil)
        }
        let tenancies = try ordered(Tenancy.filter(Column("propertyId") == propertyId).fetchAll(db), today: today)
        let chosen = tenancies.first { $0.id == selected } ?? tenancies.first
        let grid = try chosen?.id.map { try UtilityBills.read(db: db, propertyId: propertyId, tenancyId: $0) }
        return Snapshot(property: property, tenancies: tenancies, bills: grid)
    }

    /// The tenancy running on `today` first, then the rest by start date, latest first.
    nonisolated static func ordered(_ tenancies: [Tenancy], today: Date) -> [Tenancy] {
        func isCurrent(_ t: Tenancy) -> Bool { t.startDate <= today && (t.endDate.map { $0 >= today } ?? true) }
        return tenancies.sorted { a, b in
            if isCurrent(a) != isCurrent(b) { return isCurrent(a) }
            return a.startDate > b.startDate
        }
    }
}
