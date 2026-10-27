import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// Property ▸ Rent receipts on the iPad (step 8, Task 8): the selected tenancy's issued receipts, latest first, with
/// the rent their linked credits cover. One not fully covered offers "Link payment…": a rent credit of the property
/// (`RentReceiptMatching.candidateCredits`) with something left, closest to the receipt's date first, linked through
/// `RentReceiptMatching.link`.
@MainActor
public final class PadRentReceiptsModel: ObservableObject {
    public struct Receipt: Equatable, Identifiable, Sendable {
        public var receipt: RentReceipt
        /// The rent the receipt's active links cover.
        public var coveredMinorUnits: Int
        public var id: Int64 { receipt.id ?? 0 }
        public var isCovered: Bool { coveredMinorUnits >= receipt.amountReceivedMinorUnits }
        var rowId: String { "receipt\(id)" }
    }

    @Published public private(set) var receipts: [Receipt] = []
    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private var generation = 0

    /// How many credits "Link payment…" offers.
    static let choiceLimit = 5

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
    }

    public func preload(_ receipts: [Receipt]) {
        self.receipts = receipts
    }

    public func reload() async {
        generation += 1
        let mine = generation
        guard let tenancyId = property.selectedTenancyId else {
            receipts = []
            return
        }
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, tenancyId: tenancyId) }), mine == generation else { return }
        receipts = read
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, tenancyId: Int64?) -> [Receipt] {
        guard let tenancyId else { return [] }
        return (try? dbQueue.read { db in try read(db, tenancyId: tenancyId) }) ?? []
    }

    nonisolated static func read(_ db: Database, tenancyId: Int64) throws -> [Receipt] {
        try RentReceipts.receipts(db: db, tenancyId: tenancyId).reversed().map { receipt in
            let covered = try RentReceiptMatching.payments(db: db, receiptId: receipt.id!).reduce(0) { $0 + $1.rentMinorUnits }
            return Receipt(receipt: receipt, coveredMinorUnits: covered)
        }
    }

    /// Whether "Link payment…" is offered on `receipt`.
    public func canLink(_ receipt: Receipt) -> Bool { write.canEdit && !receipt.isCovered }

    /// The property's rent credits with something left after their rent and recharge links, closest to the
    /// receipt's date (else its rent period's start) first.
    public func candidates(for receipt: Receipt) async -> [Transaction] {
        guard let propertyId = property.property?.id else { return [] }
        let expected = receipt.receipt.receiptDate ?? receipt.receipt.periodStart
        let limit = Self.choiceLimit
        return (try? await dbQueue.read { db in
            let credits = try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId)
                .filter { try Recharges.creditRemainder(db: db, transactionId: $0.id!) > 0 }
            return Array(credits.sorted { abs($0.date.timeIntervalSince(expected)) < abs($1.date.timeIntervalSince(expected)) }.prefix(limit))
        }) ?? []
    }

    /// Links credit `transactionId` to `receipt` (the rent it still needs, as far as the credit goes).
    @discardableResult
    public func link(_ receipt: Receipt, transactionId: Int64) async -> Bool {
        let receiptId = receipt.id
        let saved = await write.perform(rowId: receipt.rowId, origin: .propertyMatching, edit: "Link payment",
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try RentReceiptMatching.link(db: db, receiptId: receiptId, transactionId: transactionId)
        }
        if saved { await reload() }
        return saved
    }
}

struct PadRentReceiptsView: View {
    @ObservedObject var model: PadRentReceiptsModel
    @ObservedObject var property: PadPropertyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @State private var request: PadChoiceRequest?
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PadWriteNotices(write: write)
                    if model.receipts.isEmpty {
                        EmptyState(symbol: "receipt", title: "No rent receipts",
                                   message: "Rent receipts appear here once the Mac has shared a tenancy.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(model.receipts) { receipt in card(receipt) }
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("Rent receipts")
        }
        .task(id: ReloadKey(trigger: SyncReloadTrigger(syncStatus), tenancy: property.selectedTenancyId)) {
            await write.refresh()
            await model.reload()
        }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
    }

    private struct ReloadKey: Equatable {
        var trigger: SyncReloadTrigger
        var tenancy: Int64?
    }

    private var currency: Currency { property.property?.currency ?? .gbp }

    private func card(_ receipt: PadRentReceiptsModel.Receipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Receipt \(receipt.receipt.receiptNumber)".figuresUnbroken).font(.headline)
                    Spacer(minLength: 8)
                    MoneyText(minorUnits: receipt.receipt.amountReceivedMinorUnits, currency: currency, role: .neutral, font: .headline)
                }
                HStack(spacing: 4) {
                    DateText(receipt.receipt.periodStart, font: .subheadline)
                    Text("to").font(.subheadline).foregroundStyle(.secondary)
                    DateText(receipt.receipt.periodEnd, font: .subheadline)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(receipt.isCovered ? "Paid" : "Paid so far").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    MoneyText(minorUnits: receipt.coveredMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                }
                if model.canLink(receipt) {
                    Button("Link payment…") { Task { await choose(receipt) } }
                        .buttonStyle(.bordered)
                }
                PadRefusalBanner(message: write.message(for: receipt.rowId))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choose(_ receipt: PadRentReceiptsModel.Receipt) async {
        let credits = await model.candidates(for: receipt)
        request = PadChoiceRequest(title: "Link payment", button: "Link", empty: "No rent credit is left to link.",
                                   currency: currency, choices: credits.map(PadChoice.transaction),
                                   choose: { id in await model.link(receipt, transactionId: id) })
    }
}
