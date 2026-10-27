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
        // Task 10: Missing evidence for 2025/26, its first missing item with suggestions in the side panel (Link offered).
        DemoRoute(name: "pad-missing-evidence", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { context in
            let tabs = editingTabs(context)
            let model = tabs.padMissingEvidence
            let year = UKTaxYear(startYear: 2025)
            if let snapshot = PadMissingEvidenceModel.readNow(context.dbQueue, year: year, today: context.today) {
                let catalog = snapshot.catalog
                let panels = (try? context.dbQueue.read { db in
                    try snapshot.items.filter { $0.status == .missing }.lazy
                        .map { try PadMissingEvidenceModel.panel(db, item: $0, catalog: catalog) }
                        .first { !$0.suggestions.isEmpty }
                }) ?? nil
                model.year = year
                model.preload(snapshot, selecting: panels?.itemId ?? snapshot.items.first?.id, panel: panels)
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .missingEvidence, columns: .doubleColumn))
        },
        // Step 10, Task 2: the shared document panel (thumbnail, buttons, details, Documents' edits) over the library, a
        // linked document selected, and the full-view modal with its details open.
        DemoRoute(name: "pad-document-panel", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            let tabs = editingTabs(context)
            let snapshot = PadDocumentsModel.readNow(context.dbQueue)
            tabs.padDocuments.preload(snapshot)
            if let document = linkedDocument(snapshot, context) {
                tabs.padDocuments.selectedId = document.id
                tabs.padDocuments.preload(links: PadDocumentsModel.linksNow(context.dbQueue, documentId: document.id))
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .documents, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-document-fullview", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            let tabs = editingTabs(context)
            let snapshot = PadDocumentsModel.readNow(context.dbQueue)
            let id = linkedDocument(snapshot, context)?.id ?? snapshot.all.first?.id ?? 0
            return AnyView(DocumentFullView(documentId: id, showsDetails: true)
                .environment(\.documentPanelSource, tabs.padDocuments.panelSource))
        },
        // A filed-year refusal under a document's transaction link (Unlink refused), the edits offered.
        DemoRoute(name: "pad-document-refusal", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            let tabs = editingTabs(context)
            let documents = tabs.padDocuments
            let snapshot = PadDocumentsModel.readNow(context.dbQueue)
            documents.preload(snapshot)
            if let document = snapshot.all.first(where: { document in
                PadDocumentsModel.linksNow(context.dbQueue, documentId: document.id).contains { $0.entity.type == .transaction }
            }) {
                documents.selectedId = document.id
                let links = PadDocumentsModel.linksNow(context.dbQueue, documentId: document.id)
                documents.preload(links: links)
                if let line = links.first(where: { $0.entity.type == .transaction }) {
                    tabs.padDocumentWrite.preload(canEdit: true, refusal: PadWriteModel.Refusal(
                        rowId: PadDocumentActions.linkRow(line.id), message: EvidenceLinkGuard.Failure.changesFiledYear(years: ["2024/25"]).errorDescription!))
                }
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .documents, columns: .doubleColumn))
        },
    ]

    /// The newest document with a link and a date, an amount or a period to show.
    @MainActor
    static func linkedDocument(_ snapshot: PadDocumentsModel.Snapshot, _ context: PhoneDemoContext) -> EvidenceDocumentSummary? {
        snapshot.all.first { document in
            document.amountMinorUnits != nil && !PadDocumentsModel.linksNow(context.dbQueue, documentId: document.id).isEmpty
        } ?? snapshot.all.first { !PadDocumentsModel.linksNow(context.dbQueue, documentId: $0.id).isEmpty }
    }

    /// `tabs`, writing as the demo's admin (nothing is written by a render).
    @MainActor
    static func editingTabs(_ context: PhoneDemoContext) -> PhoneTabsModel {
        let tabs = tabs(context, writer: DeviceWriter(db: context.dbQueue, viewer: { .demoAdmin }, afterWrite: {}))
        tabs.padWrite.preload(canEdit: true)
        tabs.padDocumentWrite.preload(canEdit: true)
        return tabs
    }

    /// Tabs over the demo with Property's models already read, so the first frame has its data.
    @MainActor
    static func tabs(_ context: PhoneDemoContext, writer: DeviceWriter? = nil) -> PhoneTabsModel {
        let today = context.today
        let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        tabs.padProperty.preload(PadPropertyModel.readNow(context.dbQueue, today: today))
        #if canImport(UIKit)
        // The demo's documents have no files: every one opens the same synthetic three-page PDF.
        tabs.padDocuments.open = { _ in try SampleDocumentFile.url() }
        tabs.padDocuments.panelLocalFile = { _ in try? SampleDocumentFile.url() }
        #endif
        tabs.property.preload(PropertyViewModel.readNow(context.dbQueue, today: today))
        return tabs
    }
}

#if canImport(UIKit)
/// A synthetic three-page PDF in the temporary folder, for the snapshot routes' document panel and full view.
enum SampleDocumentFile {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mango-sample-document.pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 28)]
                "Sample document".draw(at: CGPoint(x: 48, y: 64), withAttributes: title)
                "Page \(page) of 3".draw(at: CGPoint(x: 48, y: 110), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                UIColor.systemGray5.setFill()
                for line in 0..<14 { UIBezierPath(rect: CGRect(x: 48, y: 170 + line * 40, width: line % 3 == 2 ? 300 : 499, height: 12)).fill() }
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
