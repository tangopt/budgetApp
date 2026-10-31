import SwiftUI
import BudgetCore
import GRDB

/// The iPad's snapshot routes (step 8, Task 6): rendered by `--device ipad` at the iPad window sizes.
public enum PadRoutes {
    /// The iPad window sizes the harness renders: portrait and landscape on the 11-inch and 13-inch iPads.
    public static let windowSizes: [CGSize] = [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                                               CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)]

    static let all: [DemoRoute] = [
        // Step 8: Settings as the iPad shows it, a form sheet about 600 pt wide over the dimmed root: Appearance and the
        // eight theme cards, 4 x 2.
        DemoRoute(name: "pad-settings", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            let today = context.today
            return AnyView(ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                SettingsSheet(appearance: .constant(.system), themeSetId: .constant(ThemeSet.defaultID), iCloud: .available,
                              keyHeld: true, status: .idle(lastSync: today.addingTimeInterval(-300)),
                              version: SettingsCopy.version(marketing: "0.2.0", build: "1"), now: { today },
                              onLockNow: {}, onSyncNow: {})
                    .environment(\.horizontalSizeClass, .regular)
                    .frame(maxWidth: 600, maxHeight: 900)
                    .clipShape(RoundedRectangle(cornerRadius: MangoRadius.sheet, style: .continuous))
            })
        },
        // The sidebar over Home: Home's 14 figures (the sidebar adds none).
        DemoRoute(name: "pad-root", sizes: DemoRoute.padSizes, minimumFigures: 14, pad: true) { context in
            let today = context.today
            let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin,
                                      home: HomeViewModel(dbQueue: context.dbQueue, today: { today }, viewer: .demoAdmin,
                                                          preloaded: HomeViewModel.readNow(context.dbQueue, today: today)))
            // Home's recharges chart reads the bills of the selected tenancy.
            tabs.padProperty.preload(PadPropertyModel.readNow(context.dbQueue, today: today))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, columns: .doubleColumn))
        },
        // Step 10, Task 3: the sidebar over This month (its progress and counts are the figures), expanded (pad-root shows it over Home) and collapsed to the icon rail.
        DemoRoute(name: "pad-sidebar-expanded", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .thisMonth,
                                waitingChanges: 2, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-sidebar-collapsed", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .thisMonth,
                                sidebarCollapsed: true, columns: .doubleColumn))
        },
        // Step 10, Task 10: This month for the demo's tenancy (two downloads waiting), with nothing to show yet, and with every step done.
        DemoRoute(name: "pad-this-month", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            let browser = sampleBrowser("pad-this-month", items: 2)
            let tabs = editingTabs(context)
            tabs.padThisMonth.trayItems = { browser.tray.items() }
            tabs.padThisMonth.preload(PadThisMonthModel.readNow(context.dbQueue, tenancyId: tabs.padProperty.selectedTenancyId,
                                                                 today: context.today, tray: browser.tray.items()))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .thisMonth, browser: browser,
                                       columns: .doubleColumn))
        },
        DemoRoute(name: "pad-this-month-empty", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            // A household with no tenancy: nothing to read.
            let tabs = PhoneTabsModel(dbQueue: (try? DatabaseQueue()) ?? context.dbQueue, today: { context.today }, hasProperty: true, viewer: .demoAdmin)
            tabs.padProperty.preload(PadPropertyModel.Snapshot(property: nil, tenancies: [], bills: nil))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .thisMonth, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-this-month-allDone", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            let tabs = editingTabs(context)
            if var snapshot = PadThisMonthModel.readNow(context.dbQueue, tenancyId: tabs.padProperty.selectedTenancyId, today: context.today) {
                snapshot.checklist.steps = snapshot.checklist.steps.map { step in
                    var step = step
                    step.state = .done
                    step.actions = []
                    step.isWaitingForMac = false
                    step.providers = step.providers.map { var p = $0; p.state = .checked; p.trayItemIds = []; return p }
                    switch step.id {
                    case .lastRechargePaid: step.detail = ThisMonthCopy.paid
                    case .billsIn: step.detail = ThisMonthCopy.billsChecked(step.providers.count, of: step.providers.count)
                    case .chargesInGrid: step.detail = ThisMonthCopy.chargesIn(step.providers.count)
                    case .emailTenant: step.detail = ThisMonthCopy.sentOn(context.today)
                    }
                    return step
                }
                tabs.padThisMonth.preload(snapshot)
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .thisMonth, columns: .doubleColumn))
        },
        // Step 10, Task 13: Tenancies (the current tenancy's details and its receipts by month), then with a receipt's document
        // panel open (the rent paid line under its details), and with a filed-year refusal under a receipt.
        DemoRoute(name: "pad-tenancies", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            let tabs = tenanciesTabs(context)
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .tenancies, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-tenancies-panel", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            let tabs = tenanciesTabs(context, selecting: { $0.row.documentCount > 0 && !$0.row.payments.isEmpty })
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .tenancies, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-tenancies-refusal", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            let tabs = tenanciesTabs(context, selecting: { $0.row.documentCount > 0 && !$0.row.payments.isEmpty })
            if let receipt = tabs.padTenancies.selectedReceipt {
                tabs.padWrite.preload(canEdit: true, refusal: PadWriteModel.Refusal(rowId: receipt.rowId, message: DeviceWriteCopy.filedYear(years: ["2024/25"])))
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .tenancies, columns: .doubleColumn))
        },
        // Step 10, Task 15: Money (the year's tiles, cost categories as chips, the months newest first, one expanded to its
        // transactions), then with a transaction's document open in the panel, and Calendar (the agenda, then the month grid).
        DemoRoute(name: "pad-money", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            AnyView(PadRootView(tabs: moneyTabs(context, selecting: false), syncStatus: context.syncStatus, initialSelection: .propertyDetails, flatSegment: .money, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-money-panel", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            AnyView(PadRootView(tabs: moneyTabs(context, selecting: true), syncStatus: context.syncStatus, initialSelection: .propertyDetails, flatSegment: .money, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-calendar", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            AnyView(PadRootView(tabs: calendarTabs(context, layout: .agenda), syncStatus: context.syncStatus, initialSelection: .calendar, columns: .doubleColumn))
        },
        // Redesign step 4: the Calendar's filter, the flat's items only and the personal planned bills only.
        DemoRoute(name: "pad-calendar-flat", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            AnyView(PadRootView(tabs: calendarTabs(context, layout: .agenda, scope: .property), syncStatus: context.syncStatus, initialSelection: .calendar, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-calendar-personal", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            AnyView(PadRootView(tabs: calendarTabs(context, layout: .agenda, scope: .personal), syncStatus: context.syncStatus, initialSelection: .calendar, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-calendar-month", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            AnyView(PadRootView(tabs: calendarTabs(context, layout: .month), syncStatus: context.syncStatus, initialSelection: .calendar, columns: .doubleColumn))
        },
        // Step 10, Task 16: Checks (the check lines, the deposit's card beside them, the recurring costs by provider, the Undo
        // toast after "Not expected any more"), Profile (details, address and map, owners, mortgage, accounts, groups,
        // documents) and its mortgage terms form.
        DemoRoute(name: "pad-checks", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            AnyView(PadRootView(tabs: checksTabs(context), syncStatus: context.syncStatus, initialSelection: .propertyDetails, flatSegment: .costs, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-profile", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            AnyView(PadRootView(tabs: profileTabs(context), syncStatus: context.syncStatus, initialSelection: .propertyDetails, flatSegment: .profile, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-mortgage-terms", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            let tabs = profileTabs(context)
            let form = tabs.padProfile.mortgageForm() ?? MortgageTermsEditing.Form(terms: PropertyMortgageTerms(propertyId: 0), overrides: [])
            return AnyView(PadMortgageTermsSheet(model: tabs.padProfile, write: tabs.padWrite, form: form))
        },
        // Step 11, Task 2: Accounts (net worth and the grouped cards, the first account's detail beside them or pushed), the
        // detail itself, and a transaction's sheet with its document in the panel.
        DemoRoute(name: "pad-accounts", sizes: DemoRoute.padSizes, minimumFigures: 17, pad: true) { context in
            let tabs = accountsTabs(context, pushed: false)
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .accounts,
                                       browser: sampleBrowser("pad-accounts", items: 0), columns: .doubleColumn))
        },
        DemoRoute(name: "pad-account-detail", sizes: DemoRoute.padSizes, minimumFigures: 21, pad: true) { context in
            let tabs = accountsTabs(context, pushed: true)
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .accounts,
                                       browser: sampleBrowser("pad-account-detail", items: 0), columns: .doubleColumn))
        },
        DemoRoute(name: "pad-account-transaction", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            let tabs = editingTabs(context)
            let rows = AccountsViewModel.readNow(context.dbQueue, today: context.today).page?.sections.flatMap(\.rows) ?? []
            let opened = rows.compactMap { row -> PadAccountsModel.OpenTransaction? in
                guard case .loaded(let detail) = AccountDetailModel.readNow(context.dbQueue, accountId: row.id, today: context.today),
                      let first = detail.recent.first else { return nil }
                return PadAccountsModel.openNow(context.dbQueue, row: first)
            }
            guard let open = opened.first(where: { $0.documentId != nil }) ?? opened.first else { return AnyView(Text("The demo has no transaction")) }
            return AnyView(PadAccountTransactionPanel(open: open, onClose: {}).frame(width: 440)
                .environment(\.quickEdit, tabs.quickEdit)
                .environment(\.documentPanelSource, tabs.padDocuments.panelSource))
        },
        // Step 11, Task 3: Add account, and Edit details with its Sharing section (the demo's first account, its owner's view).
        DemoRoute(name: "pad-account-add", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            let tabs = editingTabs(context)
            let model = PadAccountFormModel(mode: .add, write: tabs.padAccountWrite, dbQueue: context.dbQueue, today: context.today)
            model.preload(PadAccountFormModel.Context(isAdmin: true))
            model.name = "Synthetic savings"
            return AnyView(PadAddAccountSheet(model: model))
        },
        DemoRoute(name: "pad-account-edit", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            let tabs = editingTabs(context)
            let rows = AccountsViewModel.readNow(context.dbQueue, today: context.today).page?.sections.flatMap(\.rows) ?? []
            let account = rows.first.flatMap { row in try? context.dbQueue.read { db in try Account.fetchOne(db, key: row.id) } }
            guard let account, let id = account.id else { return AnyView(Text("The demo has no account")) }
            let loaded = try? context.dbQueue.read { db in
                try PadAccountFormModel.readContext(db: db, actor: try AccessActor.admin(db: db), accountId: id)
            }
            let model = PadAccountFormModel(mode: .edit(account), write: tabs.padAccountWrite, dbQueue: context.dbQueue, today: context.today)
            model.preload(loaded ?? PadAccountFormModel.Context(isAdmin: true))
            return AnyView(PadEditAccountSheet(model: model))
        },
        DemoRoute(name: "pad-documents", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            let tabs = tabs(context)
            let model = tabs.padDocuments
            model.preload(PadDocumentsModel.readNow(context.dbQueue))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .documents, columns: .doubleColumn))
        },
        // Step 5: Month in two columns (summary, categories), then with a category's transactions in the side panel.
        DemoRoute(name: "pad-month", sizes: DemoRoute.padSizes, minimumFigures: 20, pad: true) { context in
            AnyView(PadRootView(tabs: monthTabs(context, selecting: false), syncStatus: context.syncStatus, initialSelection: .month, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-month-panel", sizes: DemoRoute.padSizes, minimumFigures: 20, pad: true) { context in
            AnyView(PadRootView(tabs: monthTabs(context, selecting: true), syncStatus: context.syncStatus, initialSelection: .month, columns: .doubleColumn))
        },
        // Search under the iPad sidebar: the flat field under the title with its suggested chips, with the newest transactions
        // (minimumFigures: day totals and amounts), and with a query and a token applied.
        DemoRoute(name: "pad-search", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            AnyView(PadRootView(tabs: searchTabs(context, query: "", tokens: []), syncStatus: context.syncStatus,
                                initialSelection: .search, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-search-query", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            AnyView(PadRootView(tabs: searchTabs(context, query: ">100", tokens: [.period(.thisMonth)]), syncStatus: context.syncStatus,
                                initialSelection: .search, columns: .doubleColumn))
        },
        // Step 10, Task 11: Bills & recharges as one screen (summary, the year's grid by stage, statements), then with a bill's
        // document panel open, and with a filed-year refusal under a bill.
        DemoRoute(name: "pad-bills-recharges", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            let tabs = billsTabs(context)
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .billsAndRecharges, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-bills-panel", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            let tabs = billsTabs(context, selecting: { $0.invoice?.documentId != nil && $0.stage >= .inRecharge && $0.stage < .paidByTenant })
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .billsAndRecharges, columns: .doubleColumn))
        },
        DemoRoute(name: "pad-bills-refusal", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
            let tabs = billsTabs(context, selecting: { $0.stage == .inRecharge })
            if let id = tabs.padBills.selectedBillId {
                tabs.padWrite.preload(canEdit: true, refusal: PadWriteModel.Refusal(rowId: id, message: DeviceWriteCopy.filedYear(years: ["2024/25"])))
            }
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .billsAndRecharges, columns: .doubleColumn))
        },
        // Task 12: Prepare email on the draft statement: the text, the statement PDF, what's missing (the demo's draft bill
        // has no PDF yet), Open in Mail / Share instead / Mark as sent….
        DemoRoute(name: "pad-prepare-email", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            let tabs = billsTabs(context)
            let draft = tabs.padBills.statements.first { $0.statement.status == .draft }
            let model = tabs.padBills.prepareEmailModel(statementId: draft?.id ?? 0, open: nil)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-prepare-email", isDirectory: true)
            let library = RechargeEmailPackage.Library(folder: folder) { _ in nil }
            if let id = draft?.id, let package = try? context.dbQueue.read({ db in
                try RechargeEmailPackage.build(db: db, statementId: id, language: .portuguese, library: library)
            }) {
                model.preload(package)
            }
            return AnyView(PrepareEmailSheet(model: model, write: tabs.padWrite))
        },
        // Step 10, Task 14: Evidence for the tax year by area (Open site and Link existing document on each item; utility
        // bills pointed to Bills & recharges), then a missing item with a suggested document open in the panel.
        DemoRoute(name: "pad-evidence", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            AnyView(PadRootView(tabs: evidenceTabs(context, selecting: false), syncStatus: context.syncStatus, initialSelection: .documents, documentsSegment: .missing,
                                browser: sampleBrowser("pad-evidence", items: 0), columns: .doubleColumn))
        },
        DemoRoute(name: "pad-evidence-panel", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            AnyView(PadRootView(tabs: evidenceTabs(context, selecting: true), syncStatus: context.syncStatus, initialSelection: .documents, documentsSegment: .missing,
                                browser: sampleBrowser("pad-evidence-panel", items: 0), columns: .doubleColumn))
        },
        // Redesign step 4 (D4): Documents ▸ Downloads, the saved sites and the downloads waiting (three synthetic PDFs, one
        // with a long name, one shared to Mango), and with nothing waiting.
        DemoRoute(name: "pad-documents-downloads", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .documents, documentsSegment: .downloads,
                                browser: sampleBrowser("pad-documents-downloads", items: 3), columns: .doubleColumn))
        },
        DemoRoute(name: "pad-documents-downloads-empty", sizes: DemoRoute.padSizes, minimumFigures: 0, pad: true) { context in
            AnyView(PadRootView(tabs: tabs(context), syncStatus: context.syncStatus, initialSelection: .documents, documentsSegment: .downloads,
                                browser: sampleBrowser("pad-documents-downloads-empty", items: 0), columns: .doubleColumn))
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
        // Step 9, Task 4: a document waiting for its payment selected, the Waiting filter on, the panel's quiet line, the edits offered.
        DemoRoute(name: "pad-document-waiting", sizes: DemoRoute.padSizes, minimumFigures: 1, pad: true) { context in
            let tabs = editingTabs(context)
            let snapshot = PadDocumentsModel.readNow(context.dbQueue)
            tabs.padDocuments.preload(snapshot)
            tabs.padDocuments.filter = .waiting
            if let id = tabs.padDocuments.groups.first?.documents.first?.id {
                tabs.padDocuments.selectedId = id
                tabs.padDocuments.preload(links: PadDocumentsModel.linksNow(context.dbQueue, documentId: id))
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
        // Step 10, Task 5: the built-in browser (a site open, its page a still placeholder) with the Downloads tray beside
        // it, and the tray with no site open (a long name, a shared file). Synthetic sites and PDFs.
        DemoRoute(name: "pad-browser", sizes: DemoRoute.padSizes, minimumFigures: 3, pad: true) { _ in
            let browser = sampleBrowser("pad-browser", items: 2)
            browser.load(sampleSites[0])
            return AnyView(BrowserView(model: browser, showsWebView: false, onDone: {}))
        },
        DemoRoute(name: "pad-tray", sizes: DemoRoute.padSizes, minimumFigures: 4, pad: true) { _ in
            AnyView(BrowserView(model: sampleBrowser("pad-tray", items: 3), showsWebView: false, onDone: {}))
        },
        // Step 10, Task 8: the Check and link sheet for a utility bill (a figure to check, the suggested payment, the tenant's
        // share), a bank statement (sent to the Mac), and a bill that Save was refused (a filed year), the file still in the tray.
        DemoRoute(name: "pad-check-utility", sizes: DemoRoute.padSizes, minimumFigures: 6, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.utility(refusal: nil), showsLivePreview: false, onClose: {}))
        },
        DemoRoute(name: "pad-check-statement", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(), showsLivePreview: false, onClose: {}))
        },
        // Step 19: a statement imported here (Import, Finish on the Mac), waiting while the Mac imports, offline, the
        // owner's account in a zone this iPad doesn't write (Send to the Mac), and a member's iPad (a note, no button).
        DemoRoute(name: "pad-import-statement", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(route: .importHere, canFinishOnMac: true), showsLivePreview: false,
                                      onClose: {}))
        },
        DemoRoute(name: "pad-import-held", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(route: .heldBy(deviceName: "Mac", since: CheckSamples.importStarted),
                                                                    canFinishOnMac: true),
                                      showsLivePreview: false, onClose: {}))
        },
        DemoRoute(name: "pad-import-offline", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(route: .offline, canFinishOnMac: true), showsLivePreview: false,
                                      onClose: {}))
        },
        DemoRoute(name: "pad-import-send", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(route: .sendToMac), showsLivePreview: false, onClose: {}))
        },
        DemoRoute(name: "pad-import-member", sizes: DemoRoute.padSizes, minimumFigures: 5, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.statement(route: .ownerImports), showsLivePreview: false, onClose: {}))
        },
        DemoRoute(name: "pad-check-refusal", sizes: DemoRoute.padSizes, minimumFigures: 6, pad: true) { _ in
            AnyView(CheckAndLinkSheet(model: CheckSamples.utility(refusal: DeviceWriteCopy.filedYear(years: ["2024/25"])),
                                      showsLivePreview: false, onClose: {}))
        },
    ]

    /// The browser routes' saved sites: synthetic names on `example.test` hosts.
    static let sampleSites: [SavedSite] = [
        ("Example Water", "water.example.test", SavedSiteKind.utility), ("Example Energy", "energy.example.test", .utility),
        ("Example Bank", "bank.example.test", .bank), ("Tax portal", "tax.example.test", .tax),
        ("Building management", "condo.example.test", .condominium),
    ].enumerated().map { index, site in
        SavedSite(name: site.0, url: URL(string: "https://\(site.1)")!, kind: site.2, sortOrder: index)
    }

    /// A browser over `sampleSites` and a tray (in the temporary folder, emptied first) holding the first `items` of three
    /// synthetic PDFs.
    @MainActor
    static func sampleBrowser(_ name: String, items: Int) -> BrowserModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-\(name)-tray", isDirectory: true)
        let files: [(String, String?, Int)] = [
            ("Water bill October 2026.pdf", "water.example.test", 95),
            ("statement-2026-10-current-account-ending-0000-with-a-very-long-name-from-the-bank.pdf", "bank.example.test", 41),
            ("Electricity invoice.pdf", nil, 12),
        ]
        DownloadsTray(directory: folder).purgeAll()
        for (index, file) in files.prefix(items).enumerated() {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-\(UUID().uuidString).pdf")
            let body = "%PDF-1.4\n% \(file.0)\n" + String(repeating: "0", count: 1024 * (index + 1) * 40) + "\n%%EOF\n"
            try? Data(body.utf8).write(to: source)
            let received = Date().addingTimeInterval(-Double(file.2) * 60)
            _ = try? DownloadsTray(directory: folder, now: { received }).ingest(fileAt: source, suggestedName: file.0, sourceHost: file.1)
        }
        let tray = DownloadsTray(directory: folder)
        let browser = BrowserModel(tray: tray, store: FixedSavedSites(sites: sampleSites), websiteData: NoWebsiteData())
        browser.preload(sites: sampleSites, current: nil, items: tray.items())
        return browser
    }

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
        tabs.padAccountWrite.preload(canEdit: true)
        return tabs
    }

    /// Editing tabs with Accounts read; the first cash account selected, and with `pushed` its detail on the navigation
    /// stack (portrait; side by side the panel shows it).
    @MainActor
    static func accountsTabs(_ context: PhoneDemoContext, pushed: Bool) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        let state = AccountsViewModel.readNow(context.dbQueue, today: context.today)
        tabs.accounts.preload(state)
        if let row = state.page?.sections.first?.rows.first {
            let destination = AccountDestination(accountId: row.id)
            tabs.padAccounts.selectedId = row.id
            tabs.accounts.detailModel(for: destination).preload(AccountDetailModel.readNow(context.dbQueue, accountId: row.id, today: context.today))
            if pushed { tabs.accounts.path = [destination] }
        }
        return tabs
    }

    /// Editing tabs with Evidence read for the current tax year; `selecting`: its first missing item with a suggested
    /// document, open in the panel.
    @MainActor
    static func evidenceTabs(_ context: PhoneDemoContext, selecting: Bool) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        let model = tabs.padEvidence
        guard let snapshot = PadEvidenceModel.readNow(context.dbQueue, year: model.year) else { return tabs }
        guard selecting else {
            model.preload(snapshot)
            return tabs
        }
        let catalog = snapshot.catalog
        let panel = (try? context.dbQueue.read { db in
            try snapshot.areas.flatMap(\.items).filter { $0.state == .missing }.lazy
                .map { try PadEvidenceModel.panel(db, item: $0.item, catalog: catalog) }
                .first { !$0.suggestions.isEmpty }
        }) ?? nil
        model.preload(snapshot, selecting: panel?.itemId ?? snapshot.areas.flatMap(\.items).first?.id, panel: panel)
        return tabs
    }

    /// Editing tabs with Bills & recharges read, the first bill `selecting` accepts (latest first) open in the panel.
    @MainActor
    static func searchTabs(_ context: PhoneDemoContext, query: String, tokens: [SearchToken]) -> PhoneTabsModel {
        let today = context.today
        let search = SearchViewModel(dbQueue: context.dbQueue, today: { today }, query: query, tokens: tokens,
                                     preloaded: SearchViewModel.readNow(context.dbQueue))
        return PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin, search: search)
    }

    /// Tabs with the demo's current pay month read; with `selecting`, its busiest spending row open in the side panel.
    @MainActor
    static func monthTabs(_ context: PhoneDemoContext, selecting: Bool) -> PhoneTabsModel {
        let today = context.today
        let month = MonthViewModel(dbQueue: context.dbQueue, today: { today }, viewer: .demoAdmin,
                                   preloaded: MonthViewModel.readNow(context.dbQueue, today: today))
        let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin, month: month)
        if selecting, case let .loaded(page) = month.state {
            let lists = page.rows(.spending).map { row in
                (row: row, state: MonthTransactionsModel.readNow(context.dbQueue, row: row, range: page.review.range, today: today))
            }
            func count(_ state: MonthTransactionsModel.State) -> Int {
                if case let .loaded(days) = state { days.reduce(0) { $0 + $1.rows.count } } else { 0 }
            }
            if let busiest = lists.max(by: { count($0.state) < count($1.state) }) {
                let destination = MonthRowDestination(row: busiest.row, range: page.review.range)
                // The panel's list is read before the first frame, as the iPhone's `month-transactions` route's is.
                _ = month.transactionsModel(for: destination)
                month.panelDestination = destination
            }
        }
        return tabs
    }

    @MainActor
    static func billsTabs(_ context: PhoneDemoContext, selecting: ((UtilityBill) -> Bool)? = nil) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        tabs.padBills.preload(PadBillsAndRechargesModel.readNow(context.dbQueue, propertyId: tabs.padProperty.property?.id,
                                                                tenancyId: tabs.padProperty.selectedTenancyId, today: context.today))
        if let selecting, let bill = tabs.padProperty.bills?.bills.sorted(by: { $0.month > $1.month }).first(where: selecting) {
            tabs.padBills.selectedBillId = bill.id
        }
        return tabs
    }

    /// Editing tabs with Tenancies read, the latest receipt `selecting` accepts open in the panel.
    @MainActor
    static func tenanciesTabs(_ context: PhoneDemoContext, selecting: ((PadTenanciesModel.Receipt) -> Bool)? = nil) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        tabs.padTenancies.preload(PadTenanciesModel.readNow(context.dbQueue, tenancyId: tabs.padProperty.selectedTenancyId))
        if let selecting, let receipt = tabs.padTenancies.detail.receipts.first(where: selecting) {
            tabs.padTenancies.selectedReceiptId = receipt.id
        }
        return tabs
    }

    /// Editing tabs with Money read for the demo's year; the newest month with transactions expanded, and with `selecting` the
    /// first transaction with a document open in the panel.
    @MainActor
    static func moneyTabs(_ context: PhoneDemoContext, selecting: Bool) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        let model = tabs.padMoney
        let propertyId = tabs.padProperty.property?.id
        let snapshot = PadMoneyModel.readNow(context.dbQueue, propertyId: propertyId, period: model.period, today: context.today)
        guard let propertyId, let summary = snapshot.summary else {
            model.preload(snapshot)
            return tabs
        }
        let months = summary.months.reversed()
        let candidates = months.compactMap { month in
            PadMoneyModel.breakdownNow(context.dbQueue, propertyId: propertyId, month: month).map { (month, $0) }
        }
        let chosen = candidates.first { pair in
            selecting && pair.1.groups.flatMap(\.lines).contains { (snapshot.documentCounts[$0.transaction.id ?? 0] ?? 0) > 0 }
        } ?? candidates.first { !$0.1.groups.isEmpty }
        var panel: PadMoneyModel.Panel?
        if selecting, let (month, breakdown) = chosen {
            model.preload(snapshot, expanded: month.start, breakdown: breakdown)
            let lines = breakdown.groups.flatMap { model.lines($0) }
            if let line = lines.first(where: { $0.documentCount > 0 }) {
                panel = PadMoneyModel.panelNow(context.dbQueue, line: line, month: month.start)
            }
        }
        model.preload(snapshot, expanded: chosen?.0.start, breakdown: chosen?.1, panel: panel)
        return tabs
    }

    /// Editing tabs with Checks read for the demo's year, the deposit's card open and the toast after "Not expected any more".
    @MainActor
    static func checksTabs(_ context: PhoneDemoContext) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        let model = tabs.padChecks
        let snapshot = PadChecksModel.readNow(context.dbQueue, propertyId: tabs.padProperty.property?.id, period: model.period, today: context.today)
        model.preload(snapshot)
        let cost = model.recurringCosts.first
        model.preload(snapshot, selected: .deposit,
                      toast: cost.map { PadChecksModel.Toast(message: "\($0.pattern.title) is no longer expected.", undo: $0) })
        return tabs
    }

    /// Editing tabs with Profile read.
    @MainActor
    static func profileTabs(_ context: PhoneDemoContext) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        tabs.padProfile.preload(PadProfileModel.readNow(context.dbQueue, propertyId: tabs.padProperty.property?.id, today: context.today))
        return tabs
    }

    /// Editing tabs with Calendar read; `layout` Month shows the grid for the demo's month.
    @MainActor
    static func calendarTabs(_ context: PhoneDemoContext, layout: PadCalendarModel.Layout,
                             scope: PadCalendarModel.Scope = .all) -> PhoneTabsModel {
        let tabs = editingTabs(context)
        let model = tabs.padCalendar
        model.preload(PadCalendarModel.readNow(context.dbQueue, propertyId: tabs.padProperty.property?.id, today: context.today))
        model.layout = layout
        model.scope = scope
        if layout == .month, let first = model.snapshot.upcoming.first { model.selectedId = first.id }
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
        tabs.padThisMonth.preload(PadThisMonthModel.readNow(context.dbQueue, tenancyId: tabs.padProperty.selectedTenancyId, today: today))
        return tabs
    }
}

/// The snapshot routes' saved sites: fixed, nothing saved.
struct FixedSavedSites: SavedSiteStore {
    let sites: [SavedSite]
    func all() async throws -> [SavedSite] { sites }
    func save(_ site: SavedSite) async throws {}
    func remove(id: UUID) async throws {}
}

/// The snapshot routes' website data: nothing to clear.
struct NoWebsiteData: WebsiteDataClearing {
    @MainActor func clearAll() async {}
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
