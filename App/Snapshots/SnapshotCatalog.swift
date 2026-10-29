// App/Snapshots/SnapshotCatalog.swift
#if SNAPSHOTS
import SwiftUI
import CoreText
import CryptoKit
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

/// The Dashboard's Widgets popover content, on its own, with some widgets hidden and some without data.
private struct WidgetsPopoverPreview: View {
    @State private var hidden = "topCategories,evidence"
    @State private var layout = "{\"sections\":{},\"v\":2}"
    @Environment(\.theme) private var theme

    var body: some View {
        DashboardWidgetsList(available: Set(DashboardCardVisibility.Card.allCases).subtracting([.propertyMonth, .tenancyCashFlow, .propertyReturn, .mortgage]),
                             hiddenCards: $hidden, storedLayout: $layout)
            .background(theme.surface)
            .padding(20)
    }
}

/// Every route the harness renders: each sidebar screen, each tab of Forecast, Property and
/// Tax years, the main sheets of the new screens, a few polished sheets to compare with, and
/// the shared components' gallery (`ComponentGallery`, `gallery-*`).
/// Records are found by the demo database's names ("Person A", "Tenancy 2") — the app doesn't
/// link the demo builder (`BudgetDemo`).
@MainActor
enum SnapshotCatalog {
    /// `importRoutes` then `kindRoutes` last: `imports-history` writes to the demo copy, the kind routes add custom kinds to it; the attribution check after them
    /// (it imports too). `settings-sign-in` and the check add synthetic app users to the demo copy; the sharing routes
    /// before them (`SharingSnapshots`) add Person B as a member with no password, so she stays a member there. The
    /// member's own-database routes (`SharingSnapshots.memberRoutes`) take A's private records out of the demo copy, so they come last.
    static var routes: [SnapshotRoute] {
        screens + propertyTabs + taxTabs + sheets + ComponentGallery.routes + SharingSnapshots.routes + AuthSnapshots.routes + [AuthSnapshots.lockedContentRoute] + AuthSnapshots.lockedToolbarRoutes + importRoutes
            + kindRoutes + waitingRoutes + transactionDocumentsRoutes + evidencePanelRoutes + [AuthSnapshots.attributionRoute] + SharingSnapshots.memberRoutes + [AuthSnapshots.launchLoadsOnceRoute]
            + panelWidthRoutes
    }

    // MARK: Resizable panels

    /// The side panels at a remembered width other than the default (last: the widths stay in the
    /// snapshot defaults), and the salary calculator with a percentage bonus and a moved split.
    static var panelWidthRoutes: [SnapshotRoute] {
        func width(_ kind: String, _ value: Double) { SnapshotMode.defaults.set(value, forKey: PaneSizing.widthKey(kind)) }
        return [
            screen("property", "recharges_statement_narrow", "Property: Recharges, the statement panel at its narrowest", .property, settle: 1.5) { models, context in
                width("property", 280)
                models.property.tab = .recharges
                if let (statement, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeStatement(id: statement, tenancyId: tenancy)
                }
            },
            screen("property", "recharges_statement_wide", "Property: Recharges, the statement panel dragged wide", .property, settle: 1.5) { models, context in
                width("property", 2000)
                models.property.tab = .recharges
                if let (statement, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeStatement(id: statement, tenancyId: tenancy)
                }
            },
            screen("documents", "panel_wide", "Documents: the detail dragged wide", .documents) { models, context in
                width("documents", 2000)
                models.documents.selectedId = (try? context.demoCustomKinds())?.documentId
            },
            screen("salary", "bonus_percent", "UK Salary Calculator: a 10% bonus on the new salary, the split moved left", .salary) { models, _ in
                SnapshotMode.defaults.set(0.43, forKey: PaneSizing.splitKey("salary"))
                models.salary.current.grossAnnual = 4_000_000
                models.salary.offer.grossAnnual = 5_200_000
                models.salary.offer.bonusPercentBP = 1000
            }
        ]
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

    /// The samples read into a review once per run and handed to every route that starts from them
    /// (the review plan is a value; each route only resolves it further). Reading the samples takes
    /// seconds, and ten routes begin with the same read. The cache is dropped whenever a route
    /// changes what the read depends on (`forgetSamplesPlans`: the history route imports the
    /// samples, the folder route registers a source folder). Keyed by the model stand-in:
    /// none, available or unavailable.
    private static var samplesPlans: [String: ImportPlan] = [:]

    static func forgetSamplesPlans() { samplesPlans = [:] }

    static func samplesPlan(_ context: SnapshotContext, modelReader: (any DocumentModelReading)? = nil,
                            modelKey: String = "none") async throws -> ImportPlan {
        if let cached = samplesPlans[modelKey] {
            // The same item ids come back, so the screen the last route left behind (its selection,
            // the groups it opened) must not see them as already shown: start from a clean review.
            context.environment.importCenter.discard()
            return cached
        }
        let plan = try await context.environment.importCenter.snapshotPlan(try importSamples(context), modelReader: modelReader)
        samplesPlans[modelKey] = plan
        return plan
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
                var plan = try await samplesPlan(context)
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
                         modelReader: SnapshotModelReader(), modelKey: "model") { plan in
                plan.items.first { $0.file.fileName == "Letter.pdf" }?.id
            },
            // The letter's kind and issuer ticked off in place ("Checked", Undo), its date still to check.
            SnapshotRoute(name: "imports-review_model_checked", title: "Imports: the samples, the model's kind and issuer checked", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                var plan = try await samplesPlan(context, modelReader: SnapshotModelReader(), modelKey: "model")
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
                var plan = try await samplesPlan(context, modelReader: SnapshotModelReader(), modelKey: "model")
                guard let letter = plan.items.first(where: { $0.file.fileName == "Letter.pdf" }) else { throw SnapshotMissing("The sample letter") }
                plan = try await center.snapshotResolve(plan, itemId: letter.id, .markAllChecked)
                let checked = plan
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(checked, selecting: letter.id)
                })))
            },
            // The same letter with the model unavailable: why, and the kind to choose.
            samplesReview("review_model_off", "Imports: the samples, the on-device model unavailable",
                         modelReader: SnapshotModelReader(isAvailable: false), modelKey: "model-off") { plan in
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
                forgetSamplesPlans()  // a source folder is registered in the demo copy now
                guard let item = plan.items(in: .needsYou).first ?? plan.items.first else { throw SnapshotMissing("The folder's items") }
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(plan, selecting: item.id)
                })))
            },
            // "New kind…": the letter nothing recognises filed as a kind made in this review (saved at Confirm import).
            SnapshotRoute(name: "imports-review_new_kind", title: "Imports: the samples, a letter filed as a new kind", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                var plan = try await samplesPlan(context)
                guard let letter = plan.items.first(where: { $0.file.fileName == "Letter.pdf" }) else { throw SnapshotMissing("The sample letter") }
                plan = try await center.snapshotResolve(plan, itemId: letter.id, .createKind(name: "Chimney inspection", area: .property))
                let made = plan
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in
                    center.showSnapshotPlan(made, selecting: letter.id)
                })))
            },
            SnapshotRoute(name: "imports-history", title: "Imports: the samples imported, in the history", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                center.discard()
                let plan = try await center.snapshotLeavingOutNeedsYou(try await center.snapshotPlan(try importSamples(context)))
                forgetSamplesPlans()  // the samples are imported now: a new read finds them in the library
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
                    forgetSamplesPlans()
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

    // MARK: Set aside and the waiting list

    /// Invented files an import left out (written beside the demo copy; nothing personal): the sheet's rows and the
    /// waiting list's. The first has a long name, to check it truncates in the middle.
    private static func setAsideDemoFiles(_ context: SnapshotContext) throws -> [SetAsideFile] {
        guard let path = context.environment.databasePath else { throw SnapshotMissing("The demo copy") }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("SetAsideDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let specs: [(String, [String], String, String)] = [
            ("Example Seguros home insurance renewal notice and schedule of cover 2025-2026 final version.pdf",
             ["Example Seguros, S.A. NIF 503504564", "Apolice 0001 - aviso de renovacao", "Synthetic demo document - not a real record."],
             "Not recognised", "Unknown"),
            ("Scan 0042.pdf", ["Synthetic demo scan 0042", "Synthetic demo document - not a real record."], ImportSetAside.leftOutReason, "Other"),
            ("Invoice 12 copy.pdf", ["Example Energia, S.A. NIF 500000000", "Fatura 12", "Synthetic demo document - not a real record."],
             "Possibly a duplicate of Invoice 12.pdf", "Utility invoice"),
            ("Boiler service note.pdf", ["Boiler service - Flat 3", "Synthetic demo document - not a real record."], ImportSetAside.leftOutReason, "Other")
        ]
        return try specs.map { name, lines, reason, kind in
            let url = folder.appendingPathComponent(name)
            try textPDF(lines, to: url)
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return SetAsideFile(url: url, fileName: name, sha256: sha, byteCount: Int64(data.count), text: nil, textStatus: .unknown,
                                reason: reason, recognisedAs: kind)
        }
    }

    /// "Files not imported" over the Imports screen's window, and "Waiting for later" above the history with the
    /// files kept for later (the real keep, then the real re-read: a file the recognisers now know shows its suggestion).
    static var waitingRoutes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "imports-set_aside", title: "Imports: Files not imported, the sheet", settleFactor: 1) { context in
                let files = try setAsideDemoFiles(context)
                let sheet = SetAsideSheet(files: files, actions: .of(context.environment.importCenter), done: {})
                return AnyView(SnapshotSheetCanvas(sheet: sheet))
            },
            SnapshotRoute(name: "imports-waiting", title: "Imports: Waiting for later above the history", settleFactor: 1.5) { context in
                let center = context.environment.importCenter
                center.discard()
                let files = try setAsideDemoFiles(context)
                let kept = try await center.keepForLater(files)
                if !kept.failed.isEmpty || kept.kept.count != files.count { throw SnapshotMissing("Every demo file kept (\(kept))") }
                await center.session.reloadWaiting()
                await center.reloadRuns()
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in })))
            }
        ]
    }

    // MARK: A transaction's documents

    /// Missing evidence's side panel (2025/26): on a row with no transaction (the property's deed or
    /// mortgage contract); on the home insurance debit whose receipt is filed as a bank debit advice
    /// (Missing, and why); on the same debit with its receipt unlinked (suggested, Link); and once
    /// that receipt is linked through the page (the row Done in place, the panel still on it). Each
    /// sets the receipt up as it needs it (after the imports, before the member's routes).
    static let longPlumberDescription = "PLUMBER SERVICES EXEMPLO LDA LISBOA REF 2026-03-05 FATURA 000123 BATHROOM LEAK REPAIR"

    static var evidencePanelRoutes: [SnapshotRoute] {
        [
            screen("missing_evidence", "panel_no_transaction", "Missing evidence: the panel on a record's row (no transaction)", .missingEvidence,
                   settle: 1.5) { models, context in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.missingOnly = false
                let items = (try? context.dbQueue.read { db in try MissingEvidence.items(db: db, taxYear: UKTaxYear(startYear: 2025)) }) ?? []
                // A one-off record's rule first (a deed, a contract), else a record still missing its document, else any record.
                let records = items.filter { $0.target.entity.type != .transaction }
                let single = records.first { if case .single = $0.requirement.scope { return true } else { return false } }
                models.missingEvidence.selectedItemId = (single ?? records.first { $0.status == .missing } ?? records.first)?.id
            },
            screen("missing_evidence", "panel_wrong_kind", "Missing evidence: the panel on a debit whose document isn't of a kind it needs",
                   .missingEvidence, settle: 1.5) { models, context in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.selectedItemId = try? context.homeInsuranceItem(receiptKind: .bankDebitAdvice, linked: true).id
            },
            screen("missing_evidence", "panel_suggestions", "Missing evidence: the panel suggesting the debit's receipt", .missingEvidence,
                   settle: 1.5) { models, context in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.selectedItemId = try? context.homeInsuranceItem(receiptKind: .insuranceReceipt, linked: false).id
            },
            // A bank description too long for the panel's title: it truncates in the middle.
            screen("missing_evidence", "panel_long_title", "Missing evidence: the panel on a debit with a long description",
                   .missingEvidence, settle: 1.5) { models, context in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.selectedItemId = try? context.plumberItem(description: Self.longPlumberDescription).id
            },
            // Inside Tax years (2025/26, Person A, Property A's rules): the page goes narrow beside the panel.
            // Selected once the tab shows (opening the tab closes a panel left open on the standalone screen).
            screen("tax_years", "missing_evidence_panel", "Tax years: Missing evidence with the panel on the wrong-kind debit",
                   .taxYears, settle: 2) { models, context in
                models.taxYears.selection = context.taxYear("Person A", 2025)
                models.taxYears.tab = .missingEvidence
                let id = try? context.homeInsuranceItem(receiptKind: .bankDebitAdvice, linked: true).id
                let model = models.missingEvidence
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.8))
                    model.selectedItemId = id
                }
            },
            // Linked through the page's own path once the panel shows: the row turns Done where it is
            // (Missing only still lists it), the panel stays on it, the summary counts one more.
            screen("missing_evidence", "panel_linked", "Missing evidence: the panel after linking the receipt (status updated)", .missingEvidence,
                   settle: 2.5) { models, context in
                let model = models.missingEvidence
                model.periodChoice = .taxYear(2025)
                guard let item = try? context.homeInsuranceItem(receiptKind: .insuranceReceipt, linked: false),
                      let receipt = try? context.homeInsuranceReceipt() else { return }
                model.selectedItemId = item.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    model.link(documentId: receipt.id!, to: item) { _ in }
                }
            }
        ]
    }

    /// The paperclip's popover over a debit with three invented documents (adds them to the demo copy, after the imports):
    /// a repair invoice also on another transaction, a transfer proof, and a receipt whose file isn't on this Mac.
    static var transactionDocumentsRoutes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "budget-transaction-documents", title: "Budget: a transaction's documents (paperclip popover)", settleFactor: 1.2) { context in
                let id = try context.transactionId(description: "BOILER REPAIR LDA")
                let other = try await context.dbQueue.read { db in
                    try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE id != ? ORDER BY id LIMIT 1", arguments: [id])
                }
                guard let other, let path = context.environment.databasePath else { throw SnapshotMissing("A second transaction") }
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("TransactionDocuments", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                func day(_ month: Int, _ d: Int) -> Date {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "UTC")!
                    return calendar.date(from: DateComponents(year: 2025, month: month, day: d))!
                }
                @MainActor func add(_ name: String, _ kind: DocumentKind, _ date: Date, _ amount: Int, canonical: String, role: String?, alsoOn: Int64? = nil,
                         onThisMac: Bool = true) throws {
                    let url = folder.appendingPathComponent(name)
                    try textPDF([canonical, "Synthetic demo document - not a real record."], to: url)
                    let metadata = EvidenceMetadata(kind: kind, docDate: date, amountMinorUnits: amount, currency: .eur, canonicalName: canonical)
                    let document = try context.library.add(url, metadata: metadata).document
                    guard let documentId = document.id else { throw SnapshotMissing("A document id") }
                    _ = try context.library.link(documentId, to: .transaction(id), role: role)
                    if let alsoOn { _ = try context.library.link(documentId, to: .transaction(alsoOn)) }
                    if !onThisMac { try FileManager.default.removeItem(at: context.library.fileURL(for: document)) }
                }
                try add("repair-invoice.pdf", .repairInvoice, day(3, 2), 28_000, canonical: "20250302 - Property - Repair bill - Boiler Repair Lda - 280.00",
                        role: "Invoice", alsoOn: other)
                try add("transfer-proof.pdf", .bankTransferProof, day(3, 4), 28_000, canonical: "20250304 - Bank - Transfer proof - Boiler Repair Lda", role: "Payment proof")
                try add("receipt-elsewhere.pdf", .other, day(3, 9), 28_000, canonical: "20250309 - Other - Receipt - Boiler Repair Lda - signed by the engineer on site",
                        role: nil, onThisMac: false)
                let documents = try await context.dbQueue.read { db in
                    try TransactionDocuments.documents(db: db, transactionId: id, catalog: DocumentKindCatalog.load(db: db))
                }
                return AnyView(SnapshotSheetCanvas(sheet: TransactionDocumentsList(documents: documents, library: context.library,
                    onDevice: Set(documents.filter { context.library.isOnThisDevice(storedRelativePath: $0.storedRelativePath) }.map(\.id)),
                    selected: documents.last?.id)))
            }
        ]
    }

    // MARK: Custom kinds

    /// Custom kinds in the demo copy (after the imports: they write to it): the Documents screen with a
    /// document of a custom kind selected (its pill and kind picker), the Kinds sheet with a rename and
    /// a merge staged, the same sheet refusing a Save that would change a filed year, and New kind…
    /// with a name that's already a kind's.
    static var kindRoutes: [SnapshotRoute] {
        [
            screen("documents", "kinds", "Documents: a document of a custom kind selected", .documents) { models, context in
                models.documents.selectedId = (try? context.demoCustomKinds())?.documentId
            },
            sheet("document_kinds", "Kinds (a rename and a merge staged)", settle: 1) { context in
                let kinds = try context.demoCustomKinds()
                let model = DocumentsViewModel(dbQueue: context.dbQueue, library: context.library)
                var draft = CustomKindsDraft(rows: try await context.dbQueue.read { db in try CustomDocumentKinds.rows(db: db) })
                draft.rename(kinds.lift, name: "Lift maintenance", area: .property)
                draft.merge(kinds.fees, into: .builtIn(.other))
                let editing = DocumentKindsSheet.Editing(kindId: kinds.boiler, mode: .merge, name: "Boiler service", area: .property,
                                                         target: .builtIn(.repairInvoice))
                return AnyView(DocumentKindsSheet(viewModel: model, initial: draft, editing: editing))
            },
            sheet("document_kinds_refused", "Kinds (Save refused: a filed year would change)", settle: 1) { context in
                let kinds = try context.demoCustomKinds()
                let model = DocumentsViewModel(dbQueue: context.dbQueue, library: context.library)
                var draft = CustomKindsDraft(rows: try await context.dbQueue.read { db in try CustomDocumentKinds.rows(db: db) })
                draft.merge(kinds.boiler, into: .builtIn(.repairInvoice))
                let refusal = CustomDocumentKinds.Failure.changesFiledYear(
                    years: ["2024/25"], documents: ["20250310 - Property - Boiler service - Boiler Repair Lda"])
                return AnyView(DocumentKindsSheet(viewModel: model, initial: draft, error: DocumentKindsSheet.refusal(refusal, draft: draft)))
            },
            // A custom-kind document wherever documents are listed: a tenancy's documents, the property's
            // profile, a transaction's documents, the document picker (Lift service, not linked yet).
            sheet("tenancy_documents_custom_kind", "Tenancy documents (a custom-kind document)", settle: 1) { context in
                try context.demoCustomKinds()
                let model = await context.propertyModel()
                guard let tenancy = model.snapshot.tenancies.last else { throw SnapshotMissing("a tenancy") }
                return AnyView(PropertyDocumentsSheet(viewModel: model, entity: EvidenceEntity(type: .tenancy, id: tenancy.id!),
                                                      title: "Documents · \(tenancy.referenceLabel)"))
            },
            screen("property", "profile_custom_kind", "Property: Profile, a custom-kind document", .property, settle: 1.3) { models, context in
                _ = try? context.demoCustomKinds()
                models.property.tab = .profile
            },
            sheet("link_document_custom_kind", "Link document (a custom-kind document to pick)", settle: 1.2) { context in
                try context.demoCustomKinds()
                let id = try context.transactionId(description: "BOILER REPAIR LDA")
                let model = TransactionDocumentsModel(transactionId: id, library: context.library, dbQueue: context.dbQueue)
                model.load()
                return AnyView(LinkDocumentSheet(model: model, transactionName: "BOILER REPAIR LDA"))
            },
            sheet("edit_transaction_custom_kind", "Edit transaction (its custom-kind document)", settle: 1.2) { context in
                try context.demoCustomKinds()
                let model = SearchViewModel(dbQueue: context.dbQueue)
                model.load()
                let id = try context.transactionId(description: "BOILER REPAIR LDA")
                guard let transaction = try await context.dbQueue.read({ db in try Transaction.fetchOne(db, key: id) }) else {
                    throw SnapshotMissing("a transaction")
                }
                return AnyView(EditTransactionSheet(
                    transaction: transaction, categories: model.categories, groups: model.groups, recentIds: model.recentCategoryIds,
                    createCategory: model.createCategory, transfer: model.transferActions, manual: model.manualActions,
                    onSave: { _, _, done in done(.saved) }))
            },
            sheet("new_kind", "New kind… (a name that's already a kind's)") { context in
                _ = try context.demoCustomKinds()
                let catalog = try await context.dbQueue.read { db in try DocumentKindCatalog.load(db: db) }
                return AnyView(NewKindPopover(choices: ImportKindChoice.choices(catalog: catalog, pending: []), initialName: "repair bill",
                                              create: { _, _ in }, cancel: {}))
            },
            sheet("filed_year_edit", "An edit that would change a filed return (plan Task 14)") { _ in
                // Synthetic: a debit categorised as Repairs in a filed 2022/23 with a loss carried forward.
                typealias Line = FiledYearEditCheck.Question.Line
                let question = FiledYearEditCheck.Question(edit: "Categorised as Repairs", years: [
                    .init(startYear: 2022, isPaid: false, people: ["Person A"], lines: [
                        Line(person: nil, box: "SA106 Land and property abroad box 17 Allowable property expenses", before: "£1,100.00", after: "£1,350.00"),
                        Line(person: nil, box: "SA106 Land and property abroad box 18 Net profit or loss", before: "£8,900.00", after: "£8,650.00"),
                        Line(person: nil, box: "SA106 Land and property abroad box 24 Adjusted profit or loss for the year", before: "£8,900.00", after: "£8,650.00")
                    ]),
                    .init(startYear: 2023, isPaid: true, people: ["Person A"], lines: [
                        Line(person: nil, box: "SA calculation: payments on account", before: "£6,172.80", after: "£6,147.80")
                    ])
                ], markYears: [2022])
                return AnyView(FiledYearEditSheet(question: question, onAnswer: { _ in }))
            },
            sheet("filed_year_checking", "A save being checked against the filed returns (plan Task 14)") { _ in
                AnyView(SheetScaffold(title: "Edit Rule", subtitle: "Transactions whose description matches are filed into the category when imported.",
                                      width: 480, onCancel: {}, primary: SheetAction("Save") {}) {
                    SheetForm {
                        LabeledContent("Pattern") { Text("BUILDER LTD") }
                        LabeledContent("Category") { Text("Repairs") }
                    }
                    Color.clear.frame(height: 48)
                }
                .filedYearGate(FiledYearGate.checking()))
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
                             modelKey: String = "none", select: @escaping (ImportPlan) -> UUID?) -> SnapshotRoute {
        SnapshotRoute(name: "imports-\(tab)", title: title, settleFactor: 1.5) { context in
            let center = context.environment.importCenter
            let plan = try await samplesPlan(context, modelReader: modelReader, modelKey: modelKey)
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

    static let dashboardMoneyTiles = [DashboardTile.netWorth, DashboardTile.currentMonth, DashboardTile.year, DashboardTile.yearChange,
                                      DashboardTile.topCategories, DashboardTile.upcomingBills, DashboardTile.accounts]

    static var screens: [SnapshotRoute] {
        [
            screen("dashboard", "main", "Dashboard", .dashboard, settle: 1.5),
            // A customised layout: net worth 70% of its row, the first Money row tall, Tax & documents rows resized.
            screen("dashboard", "layout_custom", "Dashboard: net worth 70% of its row, a tall row", .dashboard, settle: 1.5) { _, _ in
                let money = Self.dashboardMoneyTiles
                var layout = DashboardLayout()
                layout.setFractions([0.7, 0.3], row: 0, in: .money, natural: money)
                layout.setHeight(300, row: 0, in: .money, natural: money)
                layout.setHeight(260, row: 2, in: .money, natural: money)
                layout.setFractions([0.25, 0.5, 0.25], row: 2, in: .money, natural: money)
                SnapshotMode.defaults.set(layout.storedString, forKey: DashboardLayout.storageKey)
            },
            // The same tiles squeezed to their minimum, and stretched: content adapts (chart drops, lists shorten / grow).
            screen("dashboard", "layout_small", "Dashboard: tiles squeezed small (Money rows 100 / 130 / 120 pt)", .dashboard, settle: 1.5) { _, _ in
                var layout = DashboardLayout()
                let money = Self.dashboardMoneyTiles
                layout.setHeight(100, row: 0, in: .money, natural: money)
                layout.setHeight(130, row: 1, in: .money, natural: money)
                layout.setHeight(120, row: 2, in: .money, natural: money)
                layout.setFractions([0.25, 0.75], row: 0, in: .money, natural: money)
                layout.setFractions([0.8, 0.2], row: 1, in: .money, natural: money)
                SnapshotMode.defaults.set(layout.storedString, forKey: DashboardLayout.storageKey)
            },
            screen("dashboard", "layout_large", "Dashboard: tiles stretched tall (Money rows 340 / 300 / 330 pt)", .dashboard, settle: 1.5) { _, _ in
                var layout = DashboardLayout()
                let money = Self.dashboardMoneyTiles
                layout.setHeight(340, row: 0, in: .money, natural: money)
                layout.setHeight(300, row: 1, in: .money, natural: money)
                layout.setHeight(330, row: 2, in: .money, natural: money)
                SnapshotMode.defaults.set(layout.storedString, forKey: DashboardLayout.storageKey)
            },
            // The toolbar's Widgets popover (a popover can't open in the off-screen window, so its content on its own).
            SnapshotRoute(name: "dashboard-widgets_popover", title: "Dashboard: the Widgets popover (two hidden, property widgets without a property)") { _ in
                AnyView(WidgetsPopoverPreview())
            },
            screen("search", "main", "Search", .search),
            screen("search", "query", "Search: “greenleaf”", .search) { models, _ in models.search.queryText = "greenleaf" },
            // Show in Search from another screen: the latest rent credit, its row selected.
            screen("search", "revealed", "Search: a transaction shown from Property", .search) { models, context in
                if let transaction = context.latestRentCredit() { models.search.reveal(transaction) }
            },
            screen("budget", "main", "Budget grid", .budgetGrid, settle: 1.5),
            screen("forecast", "compare", "Forecast: Compare", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .compare },
            // Four scenarios ticked and Combined on: the demo's two, and two job offers that both change the
            // salary and the pension (one with a long name), so the overlap notices show, as in the 2026-10-28 report.
            screen("forecast", "compare_combined", "Forecast: Compare, four scenarios and Combined", .forecast, settle: 3) { models, _ in
                let lab = models.scenarioLab
                if let choices = try? lab.offerChoices(),
                   let salary = choices.salaries.max(by: { $0.amountMinorUnits < $1.amountMinorUnits })?.id {
                    func offer(_ gross: Int, gap: Int) -> OfferScenarioSpec {
                        OfferScenarioSpec(current: SalaryInputs(grossAnnual: 5_000_000, taxYearStart: 2026),
                                          offer: SalaryInputs(grossAnnual: gross, taxYearStart: 2026),
                                          salaryEntryId: salary, pensionEntryId: choices.pensions.first?.id,
                                          startMonth: MonthRange.of(year: 2027, month: 1).start, noticeGapMonths: gap)
                    }
                    _ = lab.createOffer(name: "Offer at 60k", spec: offer(6_000_000, gap: 0))
                    _ = lab.createOffer(name: "An offer with a rather long name to truncate in the middle", spec: offer(6_600_000, gap: 1))
                }
                lab.tab = .compare
                lab.showCombined = true
            },
            screen("forecast", "differences", "Forecast: Differences", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .differences },
            screen("forecast", "grid", "Forecast: Grid", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .grid },
            screen("salary", "main", "UK Salary Calculator: a £52,000 offer against £40,000", .salary) { models, _ in
                models.salary.offer.grossAnnual = 5_200_000
            },
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
            screen("missing_documents", "main", "Missing documents", .missingDocuments, settle: 2),
            screen("missing_documents", "tenancy", "Missing documents: Tenancy, due soon or overdue", .missingDocuments, settle: 2) { models, _ in
                models.missingDocuments.area = .tenancy
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
            // A repair bill two debits of one merchant add up to: Keep both links, or File without a link.
            screen("imports", "review_instalments", "Imports: review, a bill paid in two instalments", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.instalmentsId)
            },
            // A bill several pairs of debits add up to: Keep this pair, for each.
            screen("imports", "review_instalment_pairs", "Imports: review, which pair of instalments", .imports, settle: 1.5) { _, context in
                let demo = ImportReviewDemo.make(context)
                context.environment.importCenter.showSnapshotPlan(demo.plan, selecting: demo.pairsId)
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
                                                                           onSyncNow: {}, isDemo: true)
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
            // The running tenancy's latest bill that isn't settled yet.
            screen("property", "bills_panel", "Property: Recharges, the bills section with the latest open bill beside it", .property, settle: 1.6) { models, context in
                models.property.tab = .recharges
                if let (key, month, tenancy) = context.latestOpenBill() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .utilityBill(providerKey: key, month: month, tenancyId: tenancy)
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
        let filed = [TaxYearsViewModel.Tab.accounts, .taxReturn].map { tab in
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
            let sheet = try await make(context)
            // The kinds' names, custom ones included, as ContentView hands them to its sheets.
            let kinds = (try? await context.dbQueue.read { db in try DocumentKindCatalog.load(db: db) }) ?? DocumentKindCatalog(customKinds: [])
            return AnyView(SnapshotSheetCanvas(sheet: sheet).environment(\.documentKinds, kinds))
        }
    }

    static var sheets: [SnapshotRoute] {
        [
            // The salary simulator's Offer column: "Try in Forecast…" over a £52,000 offer against £40,000.
            sheet("try_in_forecast", "Try in Forecast… (an offer against the demo's budget)", settle: 1) { context in
                var offer = SalaryInputs.typicalCurrent(today: AppClock.now)
                offer.grossAnnual = 5_200_000
                let host = try TryInForecastViewModel(offer: offer, current: .typicalCurrent(today: AppClock.now), edit: nil,
                                                      lab: ScenarioLabViewModel(dbQueue: context.dbQueue))
                host.model.noticeGapMonths = 1
                host.model.signingBonus = 500_000
                return AnyView(TryInForecastSheet(host: host, onSaved: {}))
            },
            // Property
            sheet("property_form", "Edit property") { context in
                let model = await context.propertyModel()
                return AnyView(PropertyFormSheet(viewModel: model, draft: PropertyDraft(model.property)))
            },
            sheet("property_address", "Edit address") { context in
                let model = await context.propertyModel()
                guard let property = model.property else { throw SnapshotMissing("the demo property") }
                return AnyView(PropertyAddressSheet(viewModel: model, property: property) { _ in })
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
                // Tried and rolled back: the write's own refusal.
                let owners = [PropertyOwner(propertyId: propertyId, personId: a, shareBasisPoints: 6_000, fromDate: purchase),
                              PropertyOwner(propertyId: propertyId, personId: b, shareBasisPoints: 3_000, fromDate: purchase)]
                var error = "The shares don't add up to 100%."
                do {
                    try await context.dbQueue.write { db in
                        try db.inSavepoint {
                            _ = try Properties.setOwners(db: db, propertyId: propertyId, owners)
                            return .rollback
                        }
                    }
                } catch let refusal {
                    error = PropertyMessages.text(for: refusal)
                }
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
                    onSave: { _, _, done in done(.saved) }))
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

    /// The latest tenancy's latest utility bill not yet paid by the tenant: its provider row's key, month and the tenancy.
    func latestOpenBill() -> (String, Date, Int64)? {
        try? dbQueue.read { db in
            guard let tenancy = try Tenancy.order(Column("startDate").desc).fetchOne(db), let id = tenancy.id else { return nil }
            let grid = try UtilityBills.read(db: db, propertyId: tenancy.propertyId, tenancyId: id)
            guard let bill = grid.bills.last(where: { $0.stage != .paidByTenant }),
                  let row = grid.rows.first(where: { $0.providerId == bill.providerId }) else { return nil }
            return (row.id, bill.month, id)
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

    /// The demo's 2026 home insurance receipt (the 1 Mar 2026 debit's, in 2025/26).
    func homeInsuranceReceipt() throws -> EvidenceDocument {
        guard let document = try dbQueue.read({ db in
            try EvidenceDocument.filter(Column("originalFileName") == "Home insurance receipt 2026.pdf").fetchOne(db)
        }) else { throw SnapshotMissing("Home insurance receipt 2026.pdf") }
        return document
    }

    /// The 5 Mar 2026 plumber debit's checklist item (2025/26), its description changed to `description`.
    func plumberItem(description: String) throws -> MissingEvidence.Item {
        let year = UKTaxYear(startYear: 2025)
        let transactionId = try dbQueue.write { db -> Int64? in
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE rawDescription IN ('PLUMBER SERVICES', ?) AND date >= ? AND date < ?",
                                        arguments: [description, year.start, year.end])
            if let id { try db.execute(sql: "UPDATE transaction_ SET rawDescription = ? WHERE id = ?", arguments: [description, id]) }
            return id
        }
        guard let transactionId else { throw SnapshotMissing("The 2025/26 plumber debit") }
        let items = try dbQueue.read { db in try MissingEvidence.items(db: db, taxYear: year) }
        guard let item = items.first(where: { $0.target.entity == .transaction(transactionId) }) else { throw SnapshotMissing("The plumber item") }
        return item
    }

    /// The home insurance debit's checklist item (2025/26), with its receipt filed as `receiptKind`
    /// and linked to it or not (the demo copy changed to match).
    func homeInsuranceItem(receiptKind: DocumentKind, linked: Bool) throws -> MissingEvidence.Item {
        var receipt = try homeInsuranceReceipt()
        let year = UKTaxYear(startYear: 2025)
        let transactionId = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE rawDescription = 'SEGUROS EXEMPLO HOME POLICY' AND date >= ? AND date < ?",
                               arguments: [year.start, year.end])
        }
        guard let transactionId, let documentId = receipt.id else { throw SnapshotMissing("The 2025/26 home insurance debit") }
        try dbQueue.write { db in
            receipt.kind = receiptKind
            try receipt.update(db)
            if linked {
                _ = try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(transactionId))
            } else {
                _ = try EvidenceLinks.unlink(db: db, documentId: documentId, from: .transaction(transactionId))
            }
        }
        let items = try dbQueue.read { db in try MissingEvidence.items(db: db, taxYear: year) }
        guard let item = items.first(where: { $0.target.entity == .transaction(transactionId) }) else { throw SnapshotMissing("The home insurance item") }
        return item
    }

    func propertyId() throws -> Int64 {
        guard let id = try dbQueue.read({ db in try Property.order(Column("id")).fetchOne(db)?.id }) else { throw SnapshotMissing("a property") }
        return id
    }

    /// The demo copy's custom kinds (made once): Boiler service — the demo's boiler repair invoice
    /// filed under it and linked to the property and its tenancies too — Lift service (the first
    /// document not linked to anything, filed under it) and Club fees.
    @discardableResult
    func demoCustomKinds() throws -> (boiler: Int64, lift: Int64, fees: Int64, documentId: Int64?) {
        let made = try dbQueue.write { db -> (boiler: Int64, lift: Int64, fees: Int64, documentId: Int64?) in
            let catalog = try DocumentKindCatalog.load(db: db)
            func kind(_ name: String, _ area: DocumentArea) throws -> Int64 {
                if let id = catalog.custom(named: name)?.id { return id }
                guard let id = try CustomDocumentKinds.create(db: db, name: name, area: area, now: AppClock.now).id else {
                    throw SnapshotMissing("The custom kind \(name)")
                }
                return id
            }
            let boiler = try kind("Boiler service", .property), lift = try kind("Lift service", .property), fees = try kind("Club fees", .other)
            var document = try EvidenceDocument.filter(Column("originalFileName") == "Boiler repair invoice.pdf").fetchOne(db)
            if document?.customKindId == nil, document?.kind == .other {
                document?.customKindId = boiler
                try document?.update(db)
            }
            if try EvidenceDocument.filter(Column("customKindId") == lift).fetchCount(db) == 0,
               var unlinked = try EvidenceDocument.fetchOne(db, sql: """
                   SELECT * FROM \(EvidenceDocument.databaseTableName) WHERE id NOT IN (SELECT documentId FROM \(DocumentLink.databaseTableName))
                   ORDER BY id LIMIT 1
                   """) {
                unlinked.kind = .other
                unlinked.customKindId = lift
                try unlinked.update(db)
            }
            return (boiler, lift, fees, document?.id)
        }
        if let documentId = made.documentId {
            let tenancyIds = try dbQueue.read { db in try Tenancy.fetchAll(db).compactMap(\.id) }
            for entity in [try? propertyId()].compactMap({ $0 }).map({ EvidenceEntity(type: .property, id: $0) })
                + tenancyIds.map({ EvidenceEntity(type: .tenancy, id: $0) }) {
                _ = try? library.link(documentId, to: entity)
            }
        }
        return made
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
        model.start("snapshot")
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
