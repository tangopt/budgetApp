import GRDB
import Foundation

/// What a reader may look at besides its files: the user's intent and the people, properties,
/// accounts and providers on record.
public struct ImportContext: Sendable {
    public var intent: ImportIntent
    public var properties: [Property]
    public var people: [Person]
    public var accounts: [Account]
    public var providers: [UtilityProvider]
    public var now: Date
    /// The enabled learnt figure positions (`LearntFigures`), read by the readers.
    public var learntFigures: [ImportRule]
    /// The known parties' NIFs (`IssuerKey.knownParties`), never an issuer's key.
    public var knownParties: Set<String>
    /// The custom kinds a file may be read as: the saved ones, and the review's pending ones
    /// (`pending(_:)`).
    public var customKinds = ImportKindNames()

    public init(intent: ImportIntent = .none, properties: [Property] = [], people: [Person] = [], accounts: [Account] = [],
                providers: [UtilityProvider] = [], now: Date = Date(), learntFigures: [ImportRule] = [], knownParties: Set<String> = []) {
        self.intent = intent
        self.properties = properties
        self.people = people
        self.accounts = accounts
        self.providers = providers
        self.now = now
        self.learntFigures = learntFigures
        self.knownParties = knownParties
    }

    public static func load(db: Database, intent: ImportIntent, now: Date) throws -> ImportContext {
        ImportContext(intent: intent, properties: try Properties.all(db: db), people: try Person.fetchAll(db),
                      accounts: try Account.fetchAll(db), providers: try UtilityProvider.fetchAll(db), now: now,
                      learntFigures: try ImportLearning.figureRules(db: db), knownParties: try IssuerKey.knownParties(db: db))
            .withCustomKinds(ImportKindNames(catalog: try DocumentKindCatalog.load(db: db), pending: []))
    }

    func withCustomKinds(_ kinds: ImportKindNames) -> ImportContext {
        var context = self
        context.customKinds = kinds
        return context
    }

    /// The context with the review's pending kinds (`ImportPlan.pendingKinds`) besides the saved ones.
    func pending(_ kinds: [PendingDocumentKind]) -> ImportContext {
        guard !kinds.isEmpty else { return self }
        var context = self
        for kind in kinds {
            context.customKinds.kinds[.pending(kind.id)] = ImportCustomKind(key: .pending(kind.id), name: kind.name, area: kind.area)
        }
        return context
    }

    /// The context without the learnt rules the user overrode on an item (`declined`).
    func declining(_ declined: Set<Int64>) -> ImportContext {
        guard !declined.isEmpty else { return self }
        var context = self
        context.learntFigures.removeAll { $0.id.map(declined.contains) ?? true }
        return context
    }
}

/// Turns recognised files into proposed review items. Readers get every file of their kinds at
/// once (batch-level planners).
///
/// Contract: the pipeline runs every reader inside one write transaction that always rolls back
/// (`dbQueue.write { db in try db.inSavepoint { ...; return .rollback } }`). A reader may make
/// changes only inside that pass (e.g. `RentReceiptImport.preview`); nothing it does persists.
public protocol ImportReader: Sendable {
    func handles(_ kind: ImportKind) -> Bool
    func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem]

    /// Slow per-file reading (layout, OCR) a reader needs, done by the pipeline in the
    /// file-reading stage (off the main actor, outside the write transaction) for each file
    /// whose kind it handles; `propose` then only parses what is stored on the file.
    /// Default: the file as it is.
    func prepare(_ file: ImportFile, recognition: ImportRecognition) -> ImportFile
}

extension ImportReader {
    public func prepare(_ file: ImportFile, recognition: ImportRecognition) -> ImportFile { file }
}

public enum ImportReaders {
    /// Every built-in reader, in the order the pipeline asks them (the first that handles a
    /// kind reads it).
    public static func defaultReaders(providers: [UtilityProvider]) -> [any ImportReader] {
        [
            RentReceiptsExportReader(),
            RentReceiptPDFReader(),
            TransferAdviceReader(),
            BBVADebitAdviceReader(),
            UtilityInvoiceImportReader(providers: providers),
            PayrollFormImportReader(),
            BBVAStatementReader(),
            UKStatementReader(),
            EvidenceDocumentReader()
        ]
    }
}
