// App/Snapshots/SnapshotCatalog.swift
#if SNAPSHOTS
import SwiftUI
import CoreText
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// One capture target: a screen and tab in the main window, or a sheet over it.
struct SnapshotRoute {
    /// `<screen>-<tab>`, the PNGs' prefix (words joined by underscores).
    let name: String
    let title: String
    /// Multiplies the load time before the first capture.
    var settleFactor: Double = 1
    let makeView: @MainActor (SnapshotContext) async throws -> AnyView
}

struct SnapshotMissing: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what) not in the database" }
}

/// Every route the harness renders: each sidebar screen, each tab of Forecast, Property and
/// Tax years, the main sheets of the new screens, a few polished sheets to compare with, and
/// the shared components' gallery (`ComponentGallery`, `gallery-*`).
/// Records are found by the demo database's names ("Person A", "Tenancy 2") — the app doesn't
/// link the demo builder (`BudgetDemo`).
@MainActor
enum SnapshotCatalog {
    /// `importRoutes` last: `imports-history` writes to the demo copy; the attribution check after them
    /// (it imports too). `settings-sign-in` and the check add synthetic app users to the demo copy.
    static var routes: [SnapshotRoute] {
        screens + propertyTabs + taxTabs + sheets + ComponentGallery.routes + AuthSnapshots.routes + [AuthSnapshots.lockedContentRoute] + AuthSnapshots.lockedToolbarRoutes + importRoutes
            + [AuthSnapshots.attributionRoute, AuthSnapshots.launchLoadsOnceRoute]
    }

    // MARK: Imports, from the demo's samples

    /// Two invented letters of one insurer (written beside the demo copy), the first's kind and
    /// issuer's name corrected: the plan, that letter and the other documents its rules fit.
    @MainActor
    static func correctedInsurerLetter(_ context: SnapshotContext) async throws -> (ImportPlan, UUID, [ImportRuleFit]) {
        guard let path = context.environment.databasePath else { throw SnapshotMissing("The demo copy") }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("RuleFitLetters", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try ["2025-06", "2025-09"].map { month -> URL in
            let url = folder.appendingPathComponent("Example Seguros letter \(month).pdf")
            try textPDF(["Example Seguros, S.A. NIF 503504564", "Rua Exemplo 1, Lisboa", "Apolice 0001 - aviso \(month)",
                         "Synthetic demo document - not a real record."], to: url)
            return url
        }
        let center = context.environment.importCenter
        var plan = try await center.snapshotPlan(urls)
        guard let source = plan.items.first(where: { $0.file.fileName == urls[0].lastPathComponent }) else { throw SnapshotMissing("The first letter") }
        plan = try await center.snapshotResolve(plan, itemId: source.id, .chooseKind(.insurancePolicy))
        plan = try await center.snapshotResolve(plan, itemId: source.id, .setIssuer("Example Seguros"))
        guard let fits = try await center.snapshotRuleFits(plan)[source.id], !fits.isEmpty else { throw SnapshotMissing("A document the rules fit") }
        return (plan, source.id, fits)
    }

    /// A one-page PDF of plain text lines (A4).
    static func textPDF(_ lines: [String], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw SnapshotMissing("A PDF context") }
        pdf.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            pdf.textPosition = CGPoint(x: 50, y: 790 - CGFloat(index) * 16)
            CTLineDraw(CTLineCreateWithAttributedString(text), pdf)
        }
        pdf.endPDFPage()
        pdf.closePDF()
    }

    /// The demo's import samples (`DemoImportSamples`, written to `ImportSamples` beside the
    /// demo database) read by the real pipeline: the review with the first Needs-you item, the
    /// P60 a filed return holds, the receipt in its Ready group — then (last: it writes to the
    /// demo copy) the samples imported with Needs you left out, the history with that run, and
    /// its undo refused after a document it filed was changed.
    static var importRoutes: [SnapshotRoute] {
        [
            samplesReview("review", "Imports: the demo samples in review") { $0.items(in: .needsYou).first?.id },
            samplesReview("review_filed", "Imports: the samples, a P60 held by a filed return") { plan in
                plan.items(in: .needsYou).first { $0.issues.contains(where: ImportResolutions.isFiledYearHold) }?.id
            },
            samplesReview("review_ready", "Imports: the samples, a rent receipt ready") { plan in
                plan.items(in: .ready).first { $0.recognition.kind == .evidence(.rentReceipt) }?.id
            },
            // The BBVA statement of Euro Current: its period, balances, rows and instalment leg.
            samplesReview("review_statement", "Imports: the samples, a BBVA statement ready") { plan in
                plan.items.first { $0.recognition.kind == .bbvaStatement && $0.parentId == nil }?.id
            },
            // The UK CSV no profile reads, its account chosen (Everyday Current): its columns to map.
            SnapshotRoute(name: "imports-review_mapping", title: "Imports: the samples, a CSV's columns to map", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                var plan = try await center.snapshotPlan(try importSamples(context))
                guard let csv = plan.items.first(where: { $0.recognition.kind == .bankStatementCSV }),
                      let accountId = context.accountId("Everyday Current") else { throw SnapshotMissing("The sample CSV") }
                plan = try await center.snapshotResolve(plan, itemId: csv.id, .chooseAccount(.current, accountId))
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: csv.id)
                })))
            },
            // The letter nothing recognises, read by the on-device model's stand-in: its kind and
            // figures to check ("Use these", or each corrected).
            samplesReview("review_model", "Imports: the samples, a letter read by the on-device model",
                         modelReader: SnapshotModelReader()) { plan in
                plan.items.first { $0.file.fileName == "Letter.pdf" }?.id
            },
            // The letter's kind and issuer ticked off in place ("Checked", Undo), its date still to check.
            SnapshotRoute(name: "imports-review_model_checked", title: "Imports: the samples, the model's kind and issuer checked", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                var plan = try await center.snapshotPlan(try importSamples(context), modelReader: SnapshotModelReader())
                guard let letter = plan.items.first(where: { $0.file.fileName == "Letter.pdf" }) else { throw SnapshotMissing("The sample letter") }
                plan = try await center.snapshotResolve(plan, itemId: letter.id, .markChecked(.recognition))
                plan = try await center.snapshotResolve(plan, itemId: letter.id, .markChecked(.figure(.issuer)))
                let checked = plan
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(checked, selecting: letter.id)
                })))
            },
            // The letter's checks all ticked at once ("All checks marked", one undo for them all).
            SnapshotRoute(name: "imports-review_model_all_checked", title: "Imports: the samples, every check of the letter marked at once", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                var plan = try await center.snapshotPlan(try importSamples(context), modelReader: SnapshotModelReader())
                guard let letter = plan.items.first(where: { $0.file.fileName == "Letter.pdf" }) else { throw SnapshotMissing("The sample letter") }
                plan = try await center.snapshotResolve(plan, itemId: letter.id, .markAllChecked)
                let checked = plan
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(checked, selecting: letter.id)
                })))
            },
            // The same letter with the model unavailable: why, and the kind to choose.
            samplesReview("review_model_off", "Imports: the samples, the on-device model unavailable",
                         modelReader: SnapshotModelReader(isAvailable: false)) { plan in
                plan.items.first { $0.file.fileName == "Letter.pdf" }?.id
            },
            // Dashboard ▸ Import CSV… with Everyday Current picked, given the sample CSV: the
            // account pre-set (no account to choose), its columns to map.
            SnapshotRoute(name: "imports-review_dashboard_csv", title: "Imports: Dashboard ▸ Import CSV…, the sample CSV", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                guard let csv = try importSamples(context).first(where: { $0.pathExtension.lowercased() == "csv" }),
                      let accountId = context.accountId("Everyday Current") else { throw SnapshotMissing("The sample CSV") }
                let shortcut = ImportShortcut.statement(accountId: accountId, format: .csv, from: .dashboard)
                let plan = try await center.snapshotPlan([csv], intent: shortcut.intent)
                guard let item = plan.items.first(where: { $0.recognition.kind == .bankStatementCSV }) else { throw SnapshotMissing("The sample CSV's item") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // Tax year ▸ Income ▸ Import P60, P45 or P11D… (Person A, 2024/25) given the sample P60:
            // the filed year's hold stays, whatever year the shortcut pre-set.
            SnapshotRoute(name: "imports-review_p60", title: "Imports: Income ▸ Import P60, P45 or P11D…, the sample P60", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                guard let pdf = try importSamples(context).first(where: { $0.lastPathComponent.hasPrefix("P60") }),
                      let selection = context.taxYear("Person A", 2024) else { throw SnapshotMissing("The sample P60") }
                let shortcut = ImportShortcut.payrollForms(personId: selection.personId, taxYear: selection.startYear)
                let plan = try await center.snapshotPlan([pdf], intent: shortcut.intent)
                guard let item = plan.items.first(where: { $0.issues.contains(where: ImportResolutions.isFiledYearHold) }) ?? plan.items.first
                else { throw SnapshotMissing("The sample P60's item") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // Income ▸ Import P60, P45 or P11D… (Person A, 2026/27: no P11D yet) given the demo's P11D (read by OCR in the
            // real thing): its benefit rows to check and correct in the Benefits table.
            SnapshotRoute(name: "imports-review_p11d", title: "Imports: Income ▸ Import P60, P45 or P11D…, a P11D's benefits", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                guard let selection = context.taxYear("Person A", 2026),
                      let document = try await context.dbQueue.read({ db in
                          try EvidenceDocument.filter(Column("originalFileName") == "P11D 2025-26 Acme Widgets Ltd.pdf").fetchOne(db)
                      }) else { throw SnapshotMissing("The demo P11D") }
                let shortcut = ImportShortcut.payrollForms(personId: selection.personId, taxYear: selection.startYear)
                // A copy with a stray byte, so it isn't "already in the library".
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p11d-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent("P11D 2025-26 Acme Widgets Ltd.pdf")
                try (try Data(contentsOf: context.library.fileURL(for: document)) + Data("\n%".utf8)).write(to: copy)
                var plan = try await center.snapshotPlan([copy], intent: shortcut.intent)
                guard var item = plan.items.first else { throw SnapshotMissing("The demo P11D's item") }
                // The demo PDF's layout isn't the reader's: filed as a P11D, read again with the person pre-set, and its
                // benefits as the reader gives them for a form read by OCR.
                plan = try await center.snapshotResolve(plan, itemId: item.id, .chooseKind(.p11d))
                item = plan.items.first(where: { $0.id == item.id }) ?? item
                plan = try await center.snapshotResolve(plan, itemId: item.id, .confirmFigure(.taxYear, .year(2026)))
                item = plan.items.first(where: { $0.id == item.id }) ?? item
                plan = try await center.snapshotResolve(plan, itemId: item.id, .setBenefits([.init(kind: .medical, cashEquivalentMinorUnits: 121_000),
                                                                                              .init(kind: .carFuel, cashEquivalentMinorUnits: 0)]))
                item = plan.items.first(where: { $0.id == item.id }) ?? item
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // Tenancies ▸ a receipt's Add the receipt PDF… given the sample receipt PDF (Tenancy 2's
            // latest receipt): its link to that receipt pre-set ("You added it from Receipt ▸ Add PDF…").
            SnapshotRoute(name: "imports-review_receipts", title: "Imports: Tenancies ▸ Add the receipt PDF…, the sample receipt", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                guard let pdf = try importSamples(context).first(where: { $0.lastPathComponent.hasPrefix("Rent receipt ") }),
                      let receiptId = try await context.dbQueue.read({ db in
                          try Int64.fetchOne(db, sql: """
                              SELECT r.id FROM \(RentReceipt.databaseTableName) r JOIN \(Tenancy.databaseTableName) t ON t.id = r.tenancyId
                              WHERE t.referenceLabel = 'Tenancy 2' ORDER BY r.periodStart DESC LIMIT 1
                              """)
                      }) else { throw SnapshotMissing("The sample receipt PDF") }
                let shortcut = ImportShortcut.receiptPDF(receiptId: receiptId, replacing: [])
                let plan = try await center.snapshotPlan([pdf], intent: shortcut.intent)
                guard let item = plan.items.first else { throw SnapshotMissing("The sample receipt's item") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // Utility invoices… (Tenancies or Recharges) given the sample invoices, the property
            // pre-set: Example Water's next invoice Ready (shown), the re-issued copy a duplicate;
            // with them the property's library invoices not recorded yet ("From library").
            SnapshotRoute(name: "imports-review_invoices", title: "Imports: Utility invoices…, the sample invoices", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                let invoices = try importSamples(context).filter { $0.lastPathComponent.localizedCaseInsensitiveContains("invoice") }
                guard !invoices.isEmpty else { throw SnapshotMissing("The sample invoices") }
                let shortcut = ImportShortcut.utilityInvoices(propertyId: try context.propertyId())
                let pending = try await context.dbQueue.read { db in try shortcut.libraryDocumentIds(db: db) }
                let plan = try await center.snapshotPlan(invoices, intent: shortcut.intent, libraryDocuments: pending)
                guard let item = plan.items(in: .ready).first ?? plan.items.first else { throw SnapshotMissing("The sample invoice's item") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // An insurer's letter with its kind and name corrected: its rules fit the insurer's
            // other letter in the review ("This rule also fits 1 other document", Review).
            SnapshotRoute(name: "imports-review_rule_fits", title: "Imports: a corrected letter, its rules fitting another", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                let (plan, source, _) = try await correctedInsurerLetter(context)
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: source)
                })))
            },
            // The rule applied to them: one of them, "Changed by your rule from …" with its undo.
            SnapshotRoute(name: "imports-review_rule_applied", title: "Imports: a document changed by the rule of another", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                let (plan, source, fits) = try await correctedInsurerLetter(context)
                let applied = try await center.snapshotApplyRule(plan, from: source, to: Set(fits.map(\.itemId)))
                guard let changed = fits.first?.itemId else { throw SnapshotMissing("A document the rule fits") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(applied, selecting: changed)
                })))
            },
            // Settings ▸ Evidence sources ▸ Scan Now on a temporary folder holding the samples
            // (registered in the demo copy): its new files read as "Source folder ▸ Demo papers".
            SnapshotRoute(name: "imports-review_folder", title: "Imports: Scan Now on a source folder, its new files", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                center.discard()
                let plan = try await center.snapshotPlan(folder: try demoSourceFolder(context))
                guard let item = plan.items(in: .needsYou).first ?? plan.items.first else { throw SnapshotMissing("The folder's items") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            SnapshotRoute(name: "imports-history", title: "Imports: the samples imported, in the history", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                center.discard()
                let plan = try await center.snapshotLeavingOutNeedsYou(try await center.snapshotPlan(try importSamples(context)))
                try await center.snapshotApply(plan, entryPoint: "Demo samples")
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in })))
            },
            // After `imports-history` (it needs that run): a document the run filed is changed
            // by hand, so Undo import… is refused with what changed since.
            SnapshotRoute(name: "imports-history_undo_refused", title: "Imports: undo refused, a filed document changed since", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                center.discard()
                await center.reloadRuns()
                if !center.runs.contains(where: { $0.entryPoint == "Demo samples" && $0.undoneAt == nil }) {
                    let plan = try await center.snapshotLeavingOutNeedsYou(try await center.snapshotPlan(try importSamples(context)))
                    try await center.snapshotApply(plan, entryPoint: "Demo samples")
                    center.discard()
                }
                try await center.snapshotRefusedUndo()
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in })))
            },
            // Last (they save a column mapping for Everyday Current to the demo copy): Accounts ▸
            // Edit column mapping… given the sample CSV, its saved mapping to check ("Edit
            // columns…" opens the wizard prefilled; "Use this layout" keeps it).
            SnapshotRoute(name: "imports-review_remap", title: "Imports: Accounts ▸ Edit column mapping…, the saved mapping to check", settleFactor: 1.5) { context in
                let (plan, item, _) = try await remapReview(context)
                let center = context.environment.importCenter
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // Its "Edit columns…": the column-mapping wizard over the review, prefilled with the saved mapping.
            sheet("csv_remap", "Edit columns… (the saved mapping filled in)", settle: 1) { context in
                let (_, item, saved) = try await remapReview(context)
                guard let account = try await context.dbQueue.read({ db in try Account.fetchOne(db, key: saved.accountId) }) else {
                    throw SnapshotMissing("Everyday Current")
                }
                return AnyView(CSVMappingWizardView(account: account, csvText: item.file.text ?? "", existingProfile: saved) { _ in })
            }
        ]
    }

    /// The sample CSV read for Accounts ▸ Edit column mapping… on Everyday Current, after a
    /// mapping for it is saved (to the demo copy): the review, its item and the saved mapping.
    static func remapReview(_ context: SnapshotContext) async throws -> (ImportPlan, ImportItem, ImportProfile) {
        guard let csv = try importSamples(context).first(where: { $0.pathExtension.lowercased() == "csv" }),
              let accountId = context.accountId("Everyday Current") else { throw SnapshotMissing("The sample CSV") }
        let store = ImportProfileStore(dbQueue: context.dbQueue)
        let saved = try store.find(accountId: accountId, format: .csv)
            ?? store.save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0,
                                        csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvBalanceColumnIndex: 3,
                                        csvDateFormat: "dd/MM/yyyy"))
        let center = context.environment.importCenter
        center.discard()
        let plan = try await center.snapshotPlan([csv], intent: ImportShortcut.editColumnMapping(accountId: accountId).intent)
        guard let item = plan.items.first(where: { $0.issues.contains { $0.id == "remap" } }) else { throw SnapshotMissing("The sample CSV's mapping to check") }
        return (plan, item, saved)
    }

    /// The samples read into a review, `select` choosing the document the preview shows.
    static func samplesReview(_ tab: String, _ title: String, modelReader: (any DocumentModelReading)? = nil,
                             select: @escaping (ImportPlan) -> UUID?) -> SnapshotRoute {
        SnapshotRoute(name: "imports-\(tab)", title: title, settleFactor: 1.5) { context in
            let center = context.environment.importCenter
            let plan = try await center.snapshotPlan(try importSamples(context), modelReader: modelReader)
            guard let selected = select(plan) else { throw SnapshotMissing("The sample for \(tab)") }
            return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                center.showSnapshotPlan(plan, selecting: selected)
            })))
        }
    }

    /// Temporary folders routes made, removed when the run ends (`removeTemporaryFolders`).
    private static var temporaryFolders: [URL] = []

    static func removeTemporaryFolders() {
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
        temporaryFolders = []
    }

    /// A temporary folder named "Demo papers" holding copies of the samples, registered as a
    /// source folder in the demo copy (a fresh one each time; removed when the run ends).
    static func demoSourceFolder(_ context: SnapshotContext) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BudgetSnapshots-\(UUID().uuidString)", isDirectory: true)
        temporaryFolders.append(root)
        let folder = root.appendingPathComponent("Demo papers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sample in try importSamples(context) {
            try FileManager.default.copyItem(at: sample, to: folder.appendingPathComponent(sample.lastPathComponent))
        }
        return folder
    }

    /// The files in `ImportSamples` beside the demo database, by name.
    static func importSamples(_ context: SnapshotContext) throws -> [URL] {
        guard let path = context.environment.databasePath else { throw SnapshotMissing("ImportSamples") }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ImportSamples", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !files.isEmpty else { throw SnapshotMissing("ImportSamples") }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Screens

    static func screen(_ screen: String, _ tab: String, _ title: String, _ appScreen: AppScreen, settle: Double = 1,
                       prepare: @escaping @MainActor (SnapshotScreenModels, SnapshotContext) -> Void = { _, _ in }) -> SnapshotRoute {
        SnapshotRoute(name: "\(screen)-\(tab)", title: title, settleFactor: settle) { context in
            AnyView(ContentView(environment: context.environment,
                                snapshotSetup: SnapshotSetup(screen: appScreen, prepare: { models in prepare(models, context) })))
        }
    }

    static var screens: [SnapshotRoute] {
        [
            screen("dashboard", "main", "Dashboard", .dashboard, settle: 1.5),
            screen("search", "main", "Search", .search),
            screen("search", "query", "Search: “greenleaf”", .search) { models, _ in models.search.queryText = "greenleaf" },
            // Show in Search from another screen: the latest rent credit, its row selected.
            screen("search", "revealed", "Search: a transaction shown from Property", .search) { models, context in
                if let transaction = context.latestRentCredit() { models.search.reveal(transaction) }
            },
            screen("budget", "main", "Budget grid", .budgetGrid, settle: 1.5),
            screen("forecast", "compare", "Forecast: Compare", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .compare },
            screen("forecast", "differences", "Forecast: Differences", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .differences },
            screen("forecast", "grid", "Forecast: Grid", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .grid },
            screen("accounts", "main", "Accounts", .accounts),
            screen("accounts", "euro_current", "Accounts: Euro Current", .accounts) { models, context in
                models.accounts.selectedAccountId = context.accountId("Euro Current")
            },
            screen("documents", "main", "Documents", .documents),
            screen("documents", "selected", "Documents: a rent receipt selected", .documents) { models, context in
                models.documents.selectedId = context.documentId(kind: .rentReceipt)
            },
            screen("missing_evidence", "main", "Missing evidence (2025/26)", .missingEvidence) { models, _ in
                models.missingEvidence.periodChoice = .taxYear(2025)
            },
            screen("missing_evidence", "all", "Missing evidence (2025/26, satisfied too)", .missingEvidence) { models, _ in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.missingOnly = false
            },
            screen("rules", "main", "Rules", .rules),
            // The learnt import rules: a document type, a link, a statement account (demo).
            screen("rules", "import", "Rules: Import rules", .rules) { models, _ in models.rules.tab = .importRules },
            // "Show on Rules page" from an import's review: the Import rules tab, that rule selected.
            screen("rules", "import_shown", "Rules: an import rule shown from the review", .rules) { models, context in
                let id = (try? context.dbQueue.read { db in
                    try Int64.fetchOne(db, sql: "SELECT id FROM \(ImportRule.databaseTableName) ORDER BY id DESC LIMIT 1")
                }) ?? nil
                if let id { models.rules.showImportRule(id) } else { models.rules.tab = .importRules }
            },
            screen("categories", "main", "Categories", .categories),
            screen("uncategorized", "main", "Uncategorized", .uncategorized),
            // The document importer with nothing in progress (no import history yet: `imports-history` comes last).
            screen("imports", "main", "Imports", .imports),
            // An invented review with every section filled (read only): the invoice with two
            // possible debits selected, an unknown scan, a statement, figures to check. (The
            // reviews of real files are `importRoutes`.)
            screen("imports", "review_link", "Imports: review, a link to choose", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.invoiceId)
            },
            screen("imports", "review_kind", "Imports: review, an unknown scan", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.scanId)
            },
            screen("imports", "review_unread_lines", "Imports: review, a statement with lines not read", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.statementId)
            },
            screen("imports", "review_figures", "Imports: review, a figure confirmed and one to check", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.figuresId)
            },
            // A receipt read with learnt rules (each with "Show on Rules page"), its date to check
            // with "Remember for this issuer", and what Confirm import will remember.
            screen("imports", "review_learnt", "Imports: review, learnt rules used and what will be remembered", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.learntId)
            },
            // A Ready receipt linked to a demo debit, its peek opened in place.
            screen("imports", "review_peek", "Imports: review, a linked transaction's peek opened", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                let center = context.environment.importCenter
                center.showSnapshotPlan(demo.plan, selecting: demo.insuranceId)
                center.expandedPeeks = Set([demo.linkedTransactionId].compactMap { $0 })
            },
            // The same receipt's "Link to a transaction…" search, open over its preview.
            screen("imports", "review_link_search", "Imports: review, the link search open", .imports, settle: 2.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                let center = context.environment.importCenter
                center.showSnapshotPlan(demo.plan, selecting: demo.insuranceId)
                center.expandedPeeks = []
                center.linkSearchItemId = demo.insuranceId
            },
            // A statement whose closing doesn't match (the figures, a reason, Import anyway), its
            // row that looks already saved indented under it, one row skipped.
            screen("imports", "review_balance", "Imports: review, a statement's closing that doesn't match", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.checkedId)
            },
            screen("imports", "review_row", "Imports: review, a statement's row to keep or skip", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.rowId)
            },
            // The statement left out: its rows already imported are out with it (no Put back of their own).
            screen("imports", "review_left_out_rows", "Imports: review, a statement's rows left out with it", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                var plan = demo.plan
                for index in plan.items.indices where plan.items[index].id == demo.statementId || plan.items[index].parentId == demo.statementId {
                    plan.items[index].isLeftOut = true
                }
                let rows = plan.items.first { $0.parentId == demo.statementId }?.id
                context.environment.importCenter.showSnapshotPlan(plan, selecting: rows)
            },
            SnapshotRoute(name: "settings-main", title: "Settings window") { _ in AnyView(SnapshotStandaloneCanvas(content: SettingsView())) },
            // Settings ▸ Sync: off for the real database (no switch), and the DEBUG demo's live pane.
            SnapshotRoute(name: "settings-sync", title: "Settings ▸ Sync, off") { _ in
                AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sync)))
            },
            SnapshotRoute(name: "settings-sync_demo", title: "Settings ▸ Sync, the demo syncing") { _ in
                AnyView(SnapshotStandaloneCanvas(content: SyncSettingsPane(status: .syncing(.pulling), isRunning: true, report: nil,
                                                                           onSyncNow: {})
                    .scenePadding().frame(width: 640)))
            }
        ]
    }

    static var propertyTabs: [SnapshotRoute] {
        let august = DateInterval(start: MonthRange.of(year: 2026, month: 8).start, end: MonthRange.of(year: 2026, month: 9).start)
        return PropertyViewModel.Tab.allCases.map { tab in
            screen("property", tab.rawValue.lowercased(), "Property: \(tab.rawValue)", .property, settle: 1.3) { models, _ in
                models.property.tab = tab
            }
        } + [
            screen("property", "overview_month", "Property: Overview, August's transactions open", .property, settle: 1.5) { models, _ in
                models.property.tab = .overview
                models.property.sidePanel = .month(august)
            },
            screen("property", "money_month", "Property: Money, August's transactions open", .property, settle: 1.5) { models, _ in
                models.property.tab = .money
                models.property.sidePanel = .month(august)
            },
            screen("property", "money_figure", "Property: Money, the Costs figure open", .property, settle: 1.5) { models, _ in
                models.property.tab = .money
                models.property.sidePanel = .figure(id: "costs", title: "Costs", drillDown: .costs(categoryId: nil))
            },
            screen("property", "money_figure_rent", "Property: Money, Rent received open", .property, settle: 1.5) { models, _ in
                models.property.tab = .money
                models.property.sidePanel = .figure(id: "received", title: "Rent received", drillDown: .rentCredits)
            },
            screen("property", "overview_loan_5y", "Property: Overview, the loan five years each side", .property, settle: 1.3) { models, _ in
                models.property.tab = .overview
                models.property.loanRange = .fiveYears
            },
            screen("property", "overview_loan_end", "Property: Overview, the loan to the end", .property, settle: 1.3) { models, _ in
                models.property.tab = .overview
                models.property.loanRange = .toTheEnd
            },
            // The running tenancy's latest paid statement, and August's recharges.
            screen("property", "recharges_statement", "Property: Recharges, a paid statement open", .property, settle: 1.5) { models, context in
                models.property.tab = .recharges
                if let (statement, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeStatement(id: statement, tenancyId: tenancy)
                }
            },
            // The running tenancy's latest receipt with its PDF and a credit.
            screen("property", "tenancies_receipt", "Property: Tenancies, a receipt open", .property, settle: 1.6) { models, context in
                models.property.tab = .tenancies
                if let (receipt, tenancy) = context.latestReceiptWithPDF() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .receipt(id: receipt, tenancyId: tenancy)
                }
            },
            screen("property", "recharges_month", "Property: Recharges, August's month open", .property, settle: 1.5) { models, context in
                models.property.tab = .recharges
                if let (_, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeMonth(august.start, tenancyId: tenancy)
                }
            }
        ]
    }

    static var taxTabs: [SnapshotRoute] {
        let tabs = TaxYearsViewModel.Tab.allCases.map { tab in
            screen("tax_years", tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"), "Tax years: \(tab.rawValue) (Person A, 2025/26)",
                   .taxYears, settle: 1.5) { models, context in
                models.taxYears.selection = context.taxYear("Person A", 2025)
                models.taxYears.tab = tab
            }
        }
        let filed = [TaxYearsViewModel.Tab.accounts, .taxReturn, .filing].map { tab in
            screen("tax_years", "filed_" + tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"),
                   "Tax years: \(tab.rawValue) (Person A, 2024/25, filed)", .taxYears, settle: 1.5) { models, context in
                models.taxYears.selection = context.taxYear("Person A", 2024)
                models.taxYears.tab = tab
            }
        }
        return tabs + filed
    }

    // MARK: Sheets

    static func sheet(_ name: String, _ title: String, settle: Double = 0.6,
                      _ make: @escaping @MainActor (SnapshotContext) async throws -> AnyView) -> SnapshotRoute {
        SnapshotRoute(name: "sheet-\(name)", title: "Sheet: \(title)", settleFactor: settle) { context in
            AnyView(SnapshotSheetCanvas(sheet: try await make(context)))
        }
    }

    static var sheets: [SnapshotRoute] {
        [
            // Property
            sheet("property_form", "Edit property") { context in
                let model = await context.propertyModel()
                return AnyView(PropertyFormSheet(viewModel: model, draft: PropertyDraft(model.property)))
            },
            sheet("owners", "Owners") { context in AnyView(OwnersSheet(viewModel: await context.propertyModel())) },
            sheet("owners_error", "Owners (shares not adding up: Save's error)") { context in
                // Save's real message: the shares as entered are refused (the write rolls back).
                let model = await context.propertyModel()
                let propertyId = try context.propertyId()
                let people = model.snapshot.people
                guard let a = people.first(where: { $0.name == "Person A" })?.id, let b = people.first(where: { $0.name == "Person B" })?.id else {
                    throw SnapshotMissing("Person A and Person B")
                }
                let purchase = model.property?.purchaseDate
                let error = model.setOwners([PropertyOwner(propertyId: propertyId, personId: a, shareBasisPoints: 6_000, fromDate: purchase),
                                             PropertyOwner(propertyId: propertyId, personId: b, shareBasisPoints: 3_000, fromDate: purchase)])
                    ?? "The shares don't add up to 100%."
                return AnyView(OwnersSheet(viewModel: model, rows: [OwnersSheet.Row(personId: a, shareText: "60", from: purchase),
                                                                    OwnersSheet.Row(personId: b, shareText: "30", from: purchase)],
                                           error: error))
            },
            sheet("person_form", "Edit person") { context in
                let model = await context.propertyModel()
                guard let person = model.snapshot.people.first(where: { $0.name == "Person A" }) else { throw SnapshotMissing("Person A") }
                return AnyView(PersonFormSheet(viewModel: model, person: person))
            },
            sheet("link_account", "Link account") { context in AnyView(LinkAccountSheet(viewModel: await context.propertyModel())) },
            sheet("mortgage_terms", "Mortgage terms") { context in AnyView(MortgageTermsSheet(viewModel: await context.propertyModel())) },
            sheet("tenancy_form", "Edit tenancy") { context in
                let model = await context.propertyModel()
                guard let tenancy = model.snapshot.tenancies.first(where: { $0.referenceLabel == "Tenancy 2" }) else { throw SnapshotMissing("Tenancy 2") }
                return AnyView(TenancyFormSheet(viewModel: model, draft: TenancyDraft(tenancy, rents: model.snapshot.rents[tenancy.id!] ?? [],
                                                                                   propertyId: tenancy.propertyId)))
            },
            sheet("tenancy_form_new", "New tenancy") { context in
                let model = await context.propertyModel()
                return AnyView(TenancyFormSheet(viewModel: model, draft: TenancyDraft(nil, rents: [], propertyId: try context.propertyId())))
            },
            sheet("tenancy_documents", "Tenancy documents") { context in
                let model = await context.propertyModel()
                guard let tenancy = model.snapshot.tenancies.last else { throw SnapshotMissing("a tenancy") }
                return AnyView(PropertyDocumentsSheet(viewModel: model, entity: EvidenceEntity(type: .tenancy, id: tenancy.id!),
                                                      title: "Documents · \(tenancy.referenceLabel)"))
            },
            sheet("recharge_statement_paid", "Recharge statement (paid)") { context in
                try await context.statementSheet(status: .paid)
            },
            sheet("recharge_statement_sent", "Recharge statement (sent)") { context in
                try await context.statementSheet(status: .sent)
            },
            sheet("recharge_statement_draft", "Recharge statement (draft, email)") { context in
                try await context.statementSheet(status: .draft)
            },
            sheet("utility_providers", "Utility providers") { context in
                AnyView(UtilityProvidersSheet(dbQueue: context.dbQueue, propertyId: try context.propertyId()))
            },
            sheet("utility_provider_form", "Edit utility provider") { context in
                let propertyId = try context.propertyId()
                guard let provider = try await context.dbQueue.read({ db in try Recharges.providers(db: db, propertyId: propertyId).first }) else {
                    throw SnapshotMissing("a utility provider")
                }
                return AnyView(UtilityProviderFormSheet(dbQueue: context.dbQueue, provider: provider))
            },
            // Tax years
            sheet("tax_line_sources", "Rental accounts: line sources") { context in
                let model = await context.taxModel()
                guard let accounts = model.accounts, let line = accounts.expenses.first(where: { !$0.sources.isEmpty }) else {
                    throw SnapshotMissing("a rental accounts line")
                }
                return AnyView(TaxLineSourcesSheet(viewModel: model, line: line, currency: accounts.currency, openTransaction: { _ in }))
            },
            sheet("tax_line_sources_not_claimed", "Rental accounts: line sources with one not claimed (2024/25, filed)") { context in
                let model = await context.taxModel(year: 2024)
                guard let accounts = model.accounts, let line = accounts.notClaimedLines.first else {
                    throw SnapshotMissing("a line with a source not claimed")
                }
                return AnyView(TaxLineSourcesSheet(viewModel: model, line: line, currency: accounts.currency, openTransaction: { _ in }))
            },
            sheet("tax_manual_item", "Manual item") { context in
                let model = await context.taxModel()
                guard let item = model.page?.manualItems.first else { throw SnapshotMissing("a manual item") }
                return AnyView(TaxManualItemSheet(viewModel: model, draft: ManualItemDraft(item)))
            },
            sheet("tax_rate", "HMRC rate") { context in
                let model = await context.taxModel()
                guard let page = model.page else { throw SnapshotMissing("the tax year page") }
                return AnyView(TaxRateSheet(viewModel: model, year: page.row.year, current: page.rates.first { $0.currencyCode == "EUR" }))
            },
            sheet("tax_split", "Split") { context in
                let model = await context.taxModel()
                guard let page = model.page else { throw SnapshotMissing("the tax year page") }
                return AnyView(TaxSplitSheet(viewModel: model, page: page, draft: TaxSettingsTab.SplitDraft(expenseType: .repairs, shareBasisPoints: 5_000)))
            },
            sheet("tax_rule", "Attribution rule") { context in
                let model = await context.taxModel()
                guard let page = model.page, let row = page.rules.first(where: { $0.expenseType == .insurance }) ?? page.rules.first else {
                    throw SnapshotMissing("an attribution rule")
                }
                return AnyView(TaxRuleSheet(viewModel: model, year: page.row.year, row: row))
            },
            sheet("employment", "Employment") { context in
                let model = await context.taxModel()
                guard let row = model.page?.income.employments.first else { throw SnapshotMissing("an employment") }
                return AnyView(EmploymentSheet(viewModel: model, employment: row.employment))
            },
            sheet("employment_income", "Pay and tax (P60)") { context in
                let model = await context.taxModel()
                guard let income = model.page?.income.employments.first?.incomes.first else { throw SnapshotMissing("employment income") }
                return AnyView(EmploymentIncomeSheet(viewModel: model, income: income))
            },
            sheet("benefit", "Benefit in kind") { context in
                let model = await context.taxModel()
                guard let benefit = model.page?.income.employments.first?.benefits.first else { throw SnapshotMissing("a benefit") }
                return AnyView(BenefitSheet(viewModel: model, benefit: benefit))
            },
            sheet("other_income", "Other income") { context in
                let model = await context.taxModel()
                guard let income = model.page?.income.otherIncomes.first else { throw SnapshotMissing("other income") }
                return AnyView(OtherIncomeSheet(viewModel: model, income: income))
            },
            sheet("pension", "Pension contribution") { context in
                let model = await context.taxModel()
                guard let pension = model.page?.income.pensions.first else { throw SnapshotMissing("a pension contribution") }
                return AnyView(PensionSheet(viewModel: model, contribution: pension))
            },
            sheet("hmrc_payment", "HMRC payment") { context in
                let model = await context.taxModel()
                guard let page = model.page, let payment = page.income.payments.first else { throw SnapshotMissing("an HMRC payment") }
                return AnyView(HMRCPaymentSheet(viewModel: model, payment: payment, yearStatus: page.row.status, origin: .incomeRecord))
            },
            // Documents and Missing evidence
            sheet("link_transaction", "Link to transaction", settle: 1.2) { context in
                let model = DocumentsViewModel(dbQueue: context.dbQueue, library: context.library)
                model.load()
                await context.settle(0.8)
                return AnyView(LinkTransactionSheet(documentName: "Rent receipt T2-024.pdf", viewModel: model))
            },
            sheet("link_document", "Link document", settle: 1.2) { context in
                let id = try context.transactionId(description: "BOILER REPAIR LDA")
                let model = TransactionDocumentsModel(transactionId: id, library: context.library, dbQueue: context.dbQueue)
                model.load()
                return AnyView(LinkDocumentSheet(model: model, transactionName: "BOILER REPAIR LDA"))
            },
            sheet("link_evidence", "Missing evidence: link", settle: 1.2) { context in
                let model = await context.missingEvidenceModel()
                guard let item = model.items.first(where: { $0.status == .missing }) else { throw SnapshotMissing("a missing item") }
                return AnyView(LinkEvidenceSheet(item: item, viewModel: model))
            },
            sheet("waive_evidence", "Missing evidence: waive") { context in
                let model = await context.missingEvidenceModel()
                guard let item = model.items.first(where: { $0.status == .missing }) else { throw SnapshotMissing("a missing item") }
                return AnyView(WaiveEvidenceSheet(item: item, viewModel: model))
            },
            sheet("evidence_rules", "Evidence rules") { context in AnyView(EvidenceRulesSheet(viewModel: await context.missingEvidenceModel())) },
            sheet("evidence_rule_editor", "Evidence rule editor") { context in
                let model = await context.missingEvidenceModel()
                return AnyView(EvidenceRuleEditorSheet(viewModel: model, requirement: model.requirements.first))
            },
            sheet("property_rules", "Property evidence rules") { context in AnyView(PropertyRulesSheet(viewModel: await context.missingEvidenceModel())) },
            sheet("property_rules_preview", "Property evidence rules (a group chosen)") { context in
                let model = await context.missingEvidenceModel()
                // The demo's property group has its rules already: the first expense group with rules to add.
                let group = model.categoryGroups.filter { $0.sectionType == .expense }.first { group in
                    guard let id = group.id, case .success(let rules) = model.propertyRulesPreview(groupId: id, mortgageAccountIds: []) else { return false }
                    return !rules.isEmpty
                }
                guard let group else { throw SnapshotMissing("an expense group without rules") }
                return AnyView(PropertyRulesSheet(viewModel: model, groupId: group.id))
            },
            // Imports: a correction's rule checked against the other documents of the review
            // (invented documents: the sheet takes the fits as worked out, nothing is read).
            sheet("import_rule_fits", "Apply your rule to other documents") { _ in
                func fit(_ name: String, _ changes: [ImportRuleChange]) -> ImportRuleFit {
                    ImportRuleFit(itemId: UUID(), documentName: name, changes: changes)
                }
                let kind = ImportRuleChange(aspect: .kind, label: "Kind", before: .text("Unknown"), after: .text("Insurance receipt"),
                                            resolution: .chooseKind(.insuranceReceipt))
                let name = ImportRuleChange(aspect: .name, label: "Name", before: .text("Example Seguros, S.A."),
                                            after: .text("Seguradora Exemplo"), resolution: .setIssuer("Seguradora Exemplo"))
                // A long name and a long payment label: they wrap, never clipped.
                let longName = ImportRuleChange(aspect: .name, label: "Name",
                                                before: .text("Example Seguros Companhia de Seguros Multirriscos e Habitação, S.A. (Sucursal Lisboa)"),
                                                after: .text("Example Seguros Companhia de Seguros Multirriscos e Habitação"),
                                                resolution: .setIssuer("Example Seguros Companhia de Seguros Multirriscos e Habitação"))
                let record = ImportRuleChange(aspect: .link(.record), label: "Link", before: .text("To check: Property A"),
                                              after: .text("Property A"), resolution: .chooseLink(.property(1)))
                let amount = ImportRuleChange(aspect: .figure(.amount), label: "Amount", before: .figure(.money(966, .eur)),
                                              after: .figure(.money(124_510, .eur)), resolution: .confirmFigure(.amount, .money(124_510, .eur)))
                let paid = ImportRuleChange(aspect: .link(.transaction), label: "Paid by", before: .none,
                                            after: .text("05/10/2025 · SEPA DD EXAMPLE SEGUROS COMPANHIA DE SEGUROS MULTIRRISCOS ADC/0000123456789 · −€1,245.10"),
                                            resolution: .chooseLink(.transaction(1)))
                return AnyView(ImportRuleFitsSheet(
                    sourceName: "Insurance receipt 2025-03-05.pdf",
                    rules: ["Kind: Insurance receipt", "Name: Seguradora Exemplo"],
                    fits: [fit("Insurance receipt 2025-06-05.pdf", [kind, name]),
                           fit("Example Seguros multi-risk home policy, second instalment 2025-09-05.pdf", [kind, name, amount]),
                           fit("Letter 2025-10-01.pdf", [longName, record, paid])],
                    apply: { _ in }, cancel: {}))
            },
            // Polished sheets, for comparison
            sheet("ref_add_account", "Reference: Add account") { context in
                let model = AccountsViewModel(dbQueue: context.dbQueue)
                _ = model.load()
                return AnyView(AddAccountSheet(viewModel: model))
            },
            sheet("ref_update_balance", "Reference: Update balance") { context in
                let model = AccountsViewModel(dbQueue: context.dbQueue)
                _ = model.load()
                guard let row = model.overview?.groups.first?.rows.first else { throw SnapshotMissing("an account row") }
                return AnyView(UpdateBalanceSheet(viewModel: model, row: row))
            },
            sheet("ref_edit_transaction", "Reference: Edit transaction") { context in
                let model = SearchViewModel(dbQueue: context.dbQueue)
                model.load()
                let id = try context.transactionId(description: "GREENLEAF MARKET")
                guard let transaction = try await context.dbQueue.read({ db in try Transaction.fetchOne(db, key: id) }) else {
                    throw SnapshotMissing("a transaction")
                }
                return AnyView(EditTransactionSheet(
                    transaction: transaction, categories: model.categories, groups: model.groups, recentIds: model.recentCategoryIds,
                    createCategory: model.createCategory, transfer: model.transferActions, manual: model.manualActions,
                    onSave: { _ in .saved }))
            }
        ]
    }
}

// MARK: - Demo records

extension SnapshotContext {
    /// The latest paid recharge statement of the latest tenancy, and that tenancy.
    func latestPaidStatement() -> (Int64, Int64)? {
        try? dbQueue.read { db in
            guard let tenancy = try Tenancy.order(Column("startDate").desc).fetchOne(db)?.id,
                  let statement = try RechargeStatement.filter(Column("tenancyId") == tenancy && Column("status") == RechargeStatementStatus.paid.rawValue)
                    .order(Column("month").desc).fetchOne(db)?.id else { return nil }
            return (statement, tenancy)
        }
    }

    /// The latest tenancy's latest receipt that has a PDF and a credit linked, and that tenancy.
    func latestReceiptWithPDF() -> (Int64, Int64)? {
        try? dbQueue.read { db in
            guard let tenancy = try Tenancy.order(Column("startDate").desc).fetchOne(db)?.id,
                  let receipt = try Int64.fetchOne(db, sql: """
                      SELECT r.id FROM rentReceipt r
                      WHERE r.tenancyId = ?
                        AND EXISTS (SELECT 1 FROM documentLink l WHERE l.entityType = ? AND l.entityId = r.id)
                        AND EXISTS (SELECT 1 FROM rentReceiptPayment p WHERE p.rentReceiptId = r.id)
                      ORDER BY r.periodStart DESC LIMIT 1
                      """, arguments: [tenancy, EvidenceEntityType.rentReceipt.rawValue]) else { return nil }
            return (receipt, tenancy)
        }
    }

    /// The latest credit linked to a rent receipt.
    func latestRentCredit() -> Transaction? {
        try? dbQueue.read { db in
            try Transaction.fetchOne(db, sql: """
                SELECT t.* FROM transaction_ t JOIN rentReceiptPayment p ON p.transactionId = t.id
                ORDER BY t.date DESC LIMIT 1
                """)
        }
    }

    func accountId(_ name: String) -> Int64? {
        try? dbQueue.read { db in try Account.filter(Column("name") == name).fetchOne(db)?.id }
    }

    func propertyId() throws -> Int64 {
        guard let id = try dbQueue.read({ db in try Property.order(Column("id")).fetchOne(db)?.id }) else { throw SnapshotMissing("a property") }
        return id
    }

    func documentId(kind: DocumentKind) -> Int64? {
        try? dbQueue.read { db in try EvidenceDocument.filter(Column("kind") == kind.rawValue).order(Column("id")).fetchOne(db)?.id }
    }

    func transactionId(description: String) throws -> Int64 {
        guard let id = try dbQueue.read({ db in
            try Transaction.filter(Column("rawDescription") == description).order(Column("date").desc).fetchOne(db)?.id
        }) else { throw SnapshotMissing("“\(description)”") }
        return id
    }

    func taxYear(_ personName: String, _ startYear: Int) -> TaxYearsViewModel.Selection? {
        guard let personId = try? dbQueue.read({ db in try Person.filter(Column("name") == personName).fetchOne(db)?.id }) else { return nil }
        return TaxYearsViewModel.Selection(personId: personId, startYear: startYear)
    }

    /// The first property's page model, loaded.
    func propertyModel() async -> PropertyViewModel {
        let model = PropertyViewModel(dbQueue: dbQueue, library: library)
        model.propertyId = try? propertyId()
        model.start()
        await settle(0.6)
        return model
    }

    /// Person A's 2025/26 page (or `year`'s), loaded.
    func taxModel(tab: TaxYearsViewModel.Tab = .accounts, year: Int = 2025) async -> TaxYearsViewModel {
        let model = TaxYearsViewModel(dbQueue: dbQueue, library: library)
        model.selection = taxYear("Person A", year)
        model.tab = tab
        model.start()
        await settle(0.8)
        return model
    }

    /// The 2025/26 checklist, loaded.
    func missingEvidenceModel() async -> MissingEvidenceViewModel {
        let model = MissingEvidenceViewModel(dbQueue: dbQueue, library: library)
        model.periodChoice = .taxYear(2025)
        model.start()
        await settle(0.8)
        return model
    }

    /// The statement sheet for Tenancy 2's latest statement in `status`.
    func statementSheet(status: RechargeStatementStatus) async throws -> AnyView {
        let propertyId = try propertyId()
        let found = try await dbQueue.read { db -> (Tenancy, RechargeStatement)? in
            guard let tenancy = try Tenancy.filter(Column("propertyId") == propertyId && Column("referenceLabel") == "Tenancy 2").fetchOne(db),
                  let statement = try RechargeStatement.filter(Column("tenancyId") == tenancy.id! && Column("status") == status.rawValue)
                    .order(Column("month").desc).fetchOne(db) else { return nil }
            return (tenancy, statement)
        }
        guard let (tenancy, statement) = found else { throw SnapshotMissing("a \(status.rawValue) statement") }
        let model = RechargeStatementModel(dbQueue: dbQueue, library: library, propertyId: propertyId, tenancy: tenancy, currency: .eur,
                                           target: RechargeStatementTarget(month: statement.month, statementId: statement.id))
        return AnyView(RechargeStatementSheet(model: model))
    }
}
#endif
