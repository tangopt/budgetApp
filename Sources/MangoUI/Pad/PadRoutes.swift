import SwiftUI
import BudgetCore

/// The iPad's snapshot routes (step 8, Task 6): rendered by `--device ipad` at the iPad window sizes.
public enum PadRoutes {
    /// The iPad window sizes the harness renders: portrait and landscape on the 11-inch and 13-inch iPads.
    public static let windowSizes: [CGSize] = [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                                               CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)]

    static let all: [DemoRoute] = [
        // The sidebar over Home: Home's 14 figures (the sidebar adds none).
        DemoRoute(name: "pad-root", sizes: DemoRoute.padSizes, minimumFigures: 14, pad: true) { context in
            let today = context.today
            let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin,
                                      home: HomeViewModel(dbQueue: context.dbQueue, today: { today }, viewer: .demoAdmin,
                                                          preloaded: HomeViewModel.readNow(context.dbQueue, today: today)))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-property-overview", sizes: DemoRoute.padSizes, minimumFigures: 15, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .propertyOverview,
                                columns: .doubleColumn))
        },
        DemoRoute(name: "pad-tenancies", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .tenancies,
                                columns: .doubleColumn))
        },
        DemoRoute(name: "pad-bills", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .bills,
                                columns: .doubleColumn))
        },
        DemoRoute(name: "pad-documents", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            let tabs = tabs(context)
            let model = tabs.padDocuments
            model.preload(PadDocumentsModel.readNow(context.dbQueue))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .documents, columns: .doubleColumn))
        },
        // Task 8: the Property screens with their actions (the demo's admin edits).
        DemoRoute(name: "pad-recharges", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { context in
            let tabs = editingTabs(context)
            tabs.padRecharges.preload(PadRechargesModel.readNow(context.dbQueue, propertyId: tabs.padProperty.property?.id,
                                                                tenancyId: tabs.padProperty.selectedTenancyId))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .recharges, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-rent-receipts", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { context in
            let tabs = editingTabs(context)
            tabs.padRentReceipts.preload(PadRentReceiptsModel.readNow(context.dbQueue, tenancyId: tabs.padProperty.selectedTenancyId))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .rentReceipts, columns: .doubleColumn))
        },
        // A filed-year refusal under the latest draft's bill, its cell selected.
        DemoRoute(name: "pad-bills-refusal", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { context in
            let tabs = editingTabs(context)
            if let grid = tabs.padProperty.bills, let bill = grid.bills.last(where: { $0.stage == .inRecharge }) ?? grid.bills.last {
                tabs.padProperty.selectedCellId = grid.rows.compactMap { grid.cell(row: $0, month: bill.month) }
                    .first { cell in cell.bills.contains { $0.id == bill.id } }?.id
                tabs.padWrite.preload(canEdit: true, refusal: PadWriteModel.Refusal(
                    rowId: bill.id, message: DeviceWriteCopy.filedYear(years: ["2024/25"])))
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .bills, columns: .doubleColumn))
        },
    ]

    /// `tabs`, writing as the demo's admin (nothing is written by a render).
    @MainActor
    static func editingTabs(_ context: PhoneDemoContext) -> PhoneTabsModel {
        let tabs = tabs(context, writer: DeviceWriter(db: context.dbQueue, viewer: { .demoAdmin }, afterWrite: {}))
        tabs.padWrite.preload(canEdit: true)
        return tabs
    }

    /// Tabs over the demo with Property's models already read, so the first frame has its data.
    @MainActor
    static func tabs(_ context: PhoneDemoContext, writer: DeviceWriter? = nil) -> PhoneTabsModel {
        let today = context.today
        let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        tabs.padProperty.preload(PadPropertyModel.readNow(context.dbQueue, today: today))
        tabs.property.preload(PropertyViewModel.readNow(context.dbQueue, today: today))
        return tabs
    }
}
