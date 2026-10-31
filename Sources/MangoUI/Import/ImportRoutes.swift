import SwiftUI
import BudgetCore

/// The iPhone import's snapshot routes (iPhone import spec): the entry on Accounts, the reading state, the statement
/// review and its states (lease held, offline, no import access, a member, nothing new, no account, another account,
/// warnings), the document review, an unreadable file, and the closing summary. Synthetic names and a drawn PDF in a
/// temporary tray; nothing is written.
enum ImportRoutes {
    /// A statement or bill checked in a sheet, at the position shown.
    @MainActor
    private static func sheet(_ model: PhoneImportModel) -> AnyView {
        AnyView(PhoneImportSheet(model: model, onClose: {}))
    }

    private static let statementName = "statement-2026-09-current-account.pdf"

    @MainActor
    private static func files(_ names: [(String, PhoneImportBatch.Kind?)]) -> PhoneImportBatch {
        PhoneImportBatch(files: names.map { PhoneImportBatch.File(id: UUID(), name: $0.0, kind: $0.1) })
    }

    @MainActor
    private static func statementModel(route: PadImportRoute? = .importHere, summary: StatementImportSummary? = nil,
                                       preset: PhoneImportModel.Preset = .init(), choices: [PhoneImportAccount] = accounts,
                                       refusal: String? = nil) -> PhoneImportModel {
        let review = CheckSamples.statement(route: route, canFinishOnMac: true, refusal: refusal, summary: summary)
        return PhoneImportModel(batch: files([(statementName, .statement), ("Electricity invoice October 2026.pdf", .document),
                                             ("receipt-photo.heic", .document)]),
                                stage: .reviewing, review: review, preset: preset, accountChoices: choices)
    }

    private static let accounts = [PhoneImportAccount(id: 1, name: "Current account"), PhoneImportAccount(id: 2, name: "Savings")]

    @MainActor
    private static func summary(rows: Int = 14, skipped: Int = 3, accountId: Int64? = 1, name: String? = "Current account",
                                checks: [String] = [], notes: [String] = [], duplicateOf: String? = nil,
                                balanceMatches: Bool = true) -> StatementImportSummary {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        return StatementImportSummary(
            check: CheckAndLinkCheck(title: "Example Bank statement 2026-09", fileName: statementName, notes: notes, duplicateOf: duplicateOf),
            accountId: accountId, accountName: name.map { CheckedValue(value: $0, origin: .known) }, currency: .eur,
            periodStart: CheckedValue(value: day(2026, 9, 1), origin: .read), periodEnd: CheckedValue(value: day(2026, 9, 30), origin: .read),
            openingBalance: CheckedValue(value: 241_055, origin: .read), closingBalance: CheckedValue(value: 198_210, origin: .read),
            rowsToAdd: rows, alreadyImported: skipped, checks: checks, balanceMatches: balanceMatches)
    }

    @MainActor
    private static func documentModel(alreadySaved: String? = nil, refusal: String? = nil) -> PhoneImportModel {
        let review = alreadySaved == nil ? CheckSamples.utility(refusal: refusal) : CheckSamples.savedBefore(alreadySaved!)
        return PhoneImportModel(batch: files([("Electricity invoice October 2026.pdf", .document), (statementName, .statement)]),
                                stage: .reviewing, review: review)
    }

    @MainActor
    private static func summaryModel(skipped: Bool) -> PhoneImportModel {
        let names = ["statement-2026-09-current-account.pdf", "statement-2026-09-savings.pdf", "Electricity invoice October 2026.pdf"]
            + (skipped ? ["scan-0042.docx", "statement-2026-08-current-account.pdf"] : [])
        var batch = PhoneImportBatch(files: names.map { PhoneImportBatch.File(id: UUID(), name: $0) })
        let ids = batch.files.map(\.id)
        batch.finish(ids[0], .imported(accountId: 1, accountName: "Current account", rows: 14, skipped: 3, runId: 11))
        batch.finish(ids[1], .imported(accountId: 2, accountName: "Savings", rows: 14, skipped: 2, runId: 12))
        batch.finish(ids[2], .saved(documentId: 7, title: "Electricity invoice October 2026", linked: true))
        if skipped {
            batch.setKind(.cantRead, for: ids[3], problem: ImportInboxCopy.unsupported)
            batch.finish(ids[3], .cantRead(reason: ImportInboxCopy.unsupported))
            batch.finish(ids[4], .notImported)
        }
        return PhoneImportModel(batch: batch, stage: .done, uncategorised: 4)
    }

    static let all: [DemoRoute] = [
        // Entry: Accounts with the Import button in its header.
        DemoRoute(name: "import-entry", minimumFigures: 16) { context in
            let today = context.today
            let source = PhoneImportSource(inbox: ImportInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-import-inbox")),
                                           engine: CheckSamples.UnusedEngine(), writer: DeviceWriter(db: context.dbQueue, viewer: { .demoAdmin }, afterWrite: {}))
            let model = AccountsViewModel(dbQueue: context.dbQueue, today: { today }, preloaded: AccountsViewModel.readNow(context.dbQueue, today: today))
            return AnyView(AccountsView(model: model, syncStatus: context.syncStatus)
                .environment(\.phoneImport, PhoneImportCoordinator(snapshotSource: source)))
        },
        // Reading three files: two ticked, one still being read.
        DemoRoute(name: "import-reading", minimumFigures: 0) { _ in
            var batch = files([("statement-2026-09-current-account.pdf", .statement), ("Electricity invoice October 2026.pdf", .document),
                               ("receipt-photo.heic", nil)])
            batch.overflowNote = ImportInboxCopy.overflow(added: 3, offered: 3 + 0)
            batch.overflowNote = nil
            return sheet(PhoneImportModel(batch: batch, stage: .reading))
        },
        DemoRoute(name: "import-statement", minimumFigures: 5) { _ in
            sheet(statementModel(summary: summary()))
        },
        DemoRoute(name: "import-statement-warnings", minimumFigures: 5, figuresBelowFold: 0) { _ in
            sheet(statementModel(summary: summary(checks: ["The closing balance differs from the saved data by €12.00",
                                                          "3 rows fall outside the period", "1 row looks like a duplicate of an older one"],
                                                  notes: ["Last import was through 2026-08-31: no gap"], balanceMatches: false)))
        },
        DemoRoute(name: "import-statement-all-in", minimumFigures: 5) { _ in
            sheet(statementModel(summary: summary(rows: 0, skipped: 17, duplicateOf: "Example Bank statement 2026-09")))
        },
        DemoRoute(name: "import-statement-held", minimumFigures: 5) { _ in
            sheet(statementModel(route: .heldBy(deviceName: "The Mac", since: CheckSamples.importStarted), summary: summary()))
        },
        DemoRoute(name: "import-statement-offline", minimumFigures: 5) { _ in
            sheet(statementModel(route: .offline, summary: summary()))
        },
        DemoRoute(name: "import-statement-send", minimumFigures: 5) { _ in
            sheet(statementModel(route: .sendToMac, summary: summary()))
        },
        DemoRoute(name: "import-statement-member", minimumFigures: 5) { _ in
            sheet(statementModel(route: .ownerImports, summary: summary()))
        },
        DemoRoute(name: "import-statement-account", minimumFigures: 5) { _ in
            sheet(statementModel(summary: summary(accountId: nil, name: nil)))
        },
        DemoRoute(name: "import-statement-other-account", minimumFigures: 5) { _ in
            sheet(statementModel(summary: summary(accountId: 2, name: "Savings"),
                                 preset: .init(accountId: 1, accountName: "Current account")))
        },
        DemoRoute(name: "import-statement-refused", minimumFigures: 5) { _ in
            sheet(statementModel(summary: summary(), refusal: DeviceWriteCopy.filedYear(years: ["2024/25"])))
        },
        DemoRoute(name: "import-document", minimumFigures: 4) { _ in
            sheet(documentModel())
        },
        DemoRoute(name: "import-document-saved-before", minimumFigures: 3) { _ in
            sheet(documentModel(alreadySaved: "Water bill October 2026"))
        },
        DemoRoute(name: "import-cant-read", minimumFigures: 1) { _ in
            var batch = files([("scan-0042.docx", .cantRead), (statementName, .statement)])
            batch.setKind(.cantRead, for: batch.files[0].id, problem: ImportInboxCopy.unsupported)
            return sheet(PhoneImportModel(batch: batch, stage: .reviewing))
        },
        DemoRoute(name: "import-done", minimumFigures: 3) { _ in
            sheet(summaryModel(skipped: false))
        },
        DemoRoute(name: "import-done-skipped", minimumFigures: 3) { _ in
            sheet(summaryModel(skipped: true))
        },
    ]
}
