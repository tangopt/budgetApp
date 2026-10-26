import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// Ruling R1: every column that holds ids, and every id inside the known JSON shapes, is classified in
/// `SyncSchema`, so it travels as a UUID. These fail, naming the column or the path, when something new
/// holds an id nobody classified.
final class SyncReferenceClassificationTests: XCTestCase {
    private func migrated() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
    }

    // MARK: Columns

    /// Columns named like ids (`id`, `…Id`, `…Ids`) of synced tables that no classification covers.
    private func unclassifiedIdColumns(_ db: Database) throws -> [String] {
        var problems: [String] = []
        for table in SyncSchema.tables {
            let classified = Set([table.localIdColumn]).union(table.foreignKeys.keys).union(table.localOnlyColumns)
                .union(SyncSchema.logicalReferences(of: table.name).keys)
                .union(SyncSchema.polymorphicReferences(of: table.name).map(\.idColumn))
                .union(SyncSchema.jsonReferences(of: table.name).map(\.column))
            for column in try db.columns(in: table.name).map(\.name)
            where (column == "id" || column.hasSuffix("Id") || column.hasSuffix("Ids")) && !classified.contains(column) {
                problems.append("column \(table.name).\(column) holds ids but isn't classified")
            }
        }
        return problems
    }

    func testEveryIdColumnIsClassified() throws {
        let problems = try migrated().dbQueue.read { try unclassifiedIdColumns($0) }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testAnUnclassifiedIdColumnFailsByName() throws {
        let manager = try migrated()
        try manager.dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN reviewerPersonId INTEGER")
            try db.execute(sql: "ALTER TABLE property ADD COLUMN accountIds TEXT")
        }
        XCTAssertEqual(try manager.dbQueue.read { try unclassifiedIdColumns($0) }, [
            "column account.reviewerPersonId holds ids but isn't classified",
            "column property.accountIds holds ids but isn't classified",
        ])
    }

    func testReferenceDeclarationsNameRealColumnsAndSyncedTables() throws {
        try migrated().dbQueue.read { db in
            for (key, target) in SyncSchema.logicalReferences {
                let parts = key.split(separator: ".").map(String.init)
                let table = try XCTUnwrap(SyncSchema.table(parts[0]), key)
                XCTAssertTrue(table.syncedColumns.contains(parts[1]), key)
                XCTAssertNil(table.foreignKeys[parts[1]], "\(key) is a declared foreign key already")
                XCTAssertNotNil(SyncSchema.table(target), "\(key) targets \(target), which doesn't sync")
            }
            for reference in SyncSchema.polymorphicReferences {
                let table = try XCTUnwrap(SyncSchema.table(reference.table))
                XCTAssertTrue(table.syncedColumns.contains(reference.typeColumn))
                XCTAssertTrue(table.syncedColumns.contains(reference.idColumn))
                for target in reference.targets.values { XCTAssertNotNil(SyncSchema.table(target), target) }
            }
            for reference in SyncSchema.jsonReferences {
                XCTAssertTrue(try XCTUnwrap(SyncSchema.table(reference.table)).syncedColumns.contains(reference.column), reference.column)
            }
            for key in SyncSchema.jsonColumnsWithoutReferences {
                let parts = key.split(separator: ".").map(String.init)
                XCTAssertTrue(try XCTUnwrap(SyncSchema.table(parts[0])).syncedColumns.contains(parts[1]), key)
            }
            // importChange names rows of every synced table.
            let changes = try XCTUnwrap(SyncSchema.polymorphicReferences.first { $0.table == "importChange" })
            XCTAssertEqual(Set(changes.targets.keys), Set(SyncSchema.tables.map(\.name)))
        }
    }

    func testEveryEvidenceEntityTypeIsClassified() {
        for type in EvidenceEntityType.allCases {
            XCTAssertTrue(SyncSchema.evidenceEntityTables[type.rawValue] != nil || SyncSchema.evidenceEntityPassThrough.contains(type.rawValue),
                          "\(type.rawValue) is neither a table nor passed through")
        }
        XCTAssertEqual(SyncSchema.evidenceEntityTables,
                       Dictionary(uniqueKeysWithValues: ImportUndo.entityTables.map { ($0.key.rawValue, $0.value) }))
    }

    // MARK: JSON shapes

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func json(_ value: some Encodable) -> String {
        String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    /// Every case of the scope: the exhaustive switch stops compiling when a case is added.
    private static func scopes() -> [EvidenceRequirementScope] {
        let all: [EvidenceRequirementScope] = [
            .transactionsInCategory(categoryId: 11), .transactionsInCategoryGroup(groupId: 12),
            .transactionsMatching(categoryIds: [13, 14], accountIds: [15], descriptionContains: "x"),
            .periodic(entity: EvidenceEntity(type: .property, id: 16), every: .quarter),
            .single(entity: EvidenceEntity(type: .taxYear, id: 17)),
            .recordsOfProperty(propertyId: 18, recordType: .tenancy),
            .personalIncomeRecords(record: .p60),
        ]
        for scope in all {
            switch scope {
            case .transactionsInCategory, .transactionsInCategoryGroup, .transactionsMatching, .periodic, .single,
                 .recordsOfProperty, .personalIncomeRecords: break
            }
        }
        return all
    }

    /// One action per rule kind, every optional filled.
    private static func actions() -> [String] {
        ImportRuleKind.allCases.flatMap { kind -> [String] in
            switch kind {
            case .statementAccount: return [json(StatementAccountAction(accountId: 21))]
            case .documentKind: return [json(DocumentKindAction(kind: .utilityInvoice)), json(DocumentKindAction(kind: .other, customKindId: 7))]
            case .issuer: return [json(IssuerAction(name: "Synthetic issuer"))]
            case .link: return [json(LinkAction(entity: EvidenceEntity(type: .rentReceipt, id: 22), role: "r", descriptionKey: "k")),
                                json(LinkAction(descriptionKey: "merchant")),
                                json(LinkAction(descriptionKey: "merchant", sourceAccountId: 7))]
            case .figurePosition: return [json(FigurePositionAction(field: ImportFigureField.allCases[0], label: "TOTAL", occurrence: 2))]
            }
        }
    }

    private static func journal() -> String {
        json(ScenarioApplyJournal(
            operations: [.init(differenceId: 31, kind: .changed, categoryName: "c",
                               created: [.init(entryId: 32, after: "1|2|3")],
                               modified: [.init(entryId: 33, before: .init(endDate: Date(timeIntervalSince1970: 1_700_000_000), isEnabled: false), after: "1|2|3")],
                               categoryIds: [34])],
            enabledGroupIds: [35], createdGroupIds: [36], skipped: ["s"], boundary: Date(timeIntervalSince1970: 1_700_000_000), lastEntryId: 37))
    }

    /// The known shapes of each JSON column, made by the code that writes them.
    private static func samples() throws -> [String: [String]] {
        [
            "evidenceRequirement.scope": scopes().map(json),
            "evidenceRequirement.excludedAccountIds": [json([41, 42] as [Int64])],
            "evidenceRequirement.customKindIds": [json([43, 44] as [Int64])],
            "importRule.actionJSON": actions(),
            "scenarioApplication.journal": [journal()],
            "document.persons": [json(["Person A"])],
            "evidenceRequirement.kinds": [json(DocumentKind.allCases)],
            "utilityProvider.invoiceRules": [json(UtilityInvoiceRules(textMarkers: ["a"], fileNameMarkers: ["b"], invoiceNumberPatterns: ["c"],
                                                                        issueDateLabels: ["d"], periodLabels: ["e"], amountLabels: ["f"],
                                                                        refundLabels: ["g"], dueDateLabels: ["h"]))],
            "importProfile.pdfLayoutConfig": [json(PDFLayoutConfig(regexPattern: "x", dateFormat: "y"))],
            "importRun.reasonsJSON": [try XCTUnwrap(try ImportApplier.reasonsJSON([UUID(): "reason"]))],
        ]
    }

    /// Numbers in `texts` (a JSON column's shapes) that are neither a classified id nor a known plain number.
    private func unclassifiedNumbers(column: String, texts: [String]) -> [String] {
        let parts = column.split(separator: ".").map(String.init)
        let reference = SyncSchema.jsonReferences.first { $0.table == parts[0] && $0.column == parts[1] }
        var allowed = reference?.plainNumbers ?? []
        if case .rules(let rules) = reference?.content {
            for rule in rules {
                switch rule.target {
                case .row: allowed.insert(rule.path)
                case .evidenceEntity: allowed.insert(rule.path + ".id")
                case .forecastFingerprint: break
                }
            }
        }
        var problems: [String] = []
        for text in texts {
            guard let root = SyncJSONNode.parse(text) else {
                problems.append("\(column): not JSON")
                continue
            }
            for path in root.numberPaths() where !allowed.contains(path) && !problems.contains("\(column): \(path)") {
                problems.append("\(column): \(path)")
            }
        }
        return problems
    }

    func testEveryJSONIdPathIsClassified() throws {
        let samples = try Self.samples()
        let columns = Set(SyncSchema.jsonReferences.filter { if case .rules = $0.content { return true }; return false }.map { "\($0.table).\($0.column)" })
            .union(SyncSchema.jsonColumnsWithoutReferences)
        XCTAssertEqual(Set(samples.keys), columns, "every JSON column has its shapes sampled")
        var problems: [String] = []
        for (column, texts) in samples.sorted(by: { $0.key < $1.key }) {
            problems += unclassifiedNumbers(column: column, texts: texts)
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        // Every rule is exercised by a shape (a stale rule would hide a renamed field).
        for reference in SyncSchema.jsonReferences {
            guard case .rules(let rules) = reference.content else { continue }
            let texts = samples["\(reference.table).\(reference.column)"] ?? []
            let roots = texts.compactMap(SyncJSONNode.parse)
            for rule in rules {
                let present = roots.contains { root in
                    root.numberPaths().contains { $0 == rule.path || $0.hasPrefix(rule.path + ".") } || root.stringPaths().contains { $0.0 == rule.path }
                }
                XCTAssertTrue(present, "\(reference.column) rule \(rule.path) matches nothing in the known shapes")
            }
        }
    }

    /// Strings that look like they carry ids (a number, or numbers joined by `|` like a fingerprint) at a
    /// place no rule classifies.
    private func idBearingStrings(column: String, texts: [String]) -> [String] {
        let parts = column.split(separator: ".").map(String.init)
        let reference = SyncSchema.jsonReferences.first { $0.table == parts[0] && $0.column == parts[1] }
        var classified: Set<String> = []
        if case .rules(let rules) = reference?.content {
            for rule in rules where rule.target == .forecastFingerprint { classified.insert(rule.path) }
        }
        let pattern = try! NSRegularExpression(pattern: #"^-?\d+$|\d+\|"#)
        var problems: [String] = []
        for text in texts {
            for (path, value) in SyncJSONNode.parse(text)?.stringPaths() ?? [] where !classified.contains(path) {
                // Map keys that are UUIDs (`importRun.reasonsJSON`) are data, not places.
                if UUID(uuidString: path) != nil { continue }
                if pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil, !problems.contains("\(column): \(path)") {
                    problems.append("\(column): \(path)")
                }
            }
        }
        return problems
    }

    func testNoIdBearingStringIsUnclassified() throws {
        var problems: [String] = []
        for (column, texts) in try Self.samples().sorted(by: { $0.key < $1.key }) {
            problems += idBearingStrings(column: column, texts: texts)
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        XCTAssertEqual(idBearingStrings(column: "importRule.actionJSON", texts: [#"{"ref":"12|34","other":"42","label":"Total 3"}"#]),
                       ["importRule.actionJSON: ref", "importRule.actionJSON: other"])
        // The journal's fingerprints are covered by their rule.
        XCTAssertEqual(idBearingStrings(column: "scenarioApplication.journal", texts: [Self.journal()]), [])
    }

    // MARK: Unique keys

    private func undeclaredUniqueKeys(_ db: Database) throws -> [String] {
        var problems: [String] = []
        for table in SyncSchema.tables {
            for index in try SyncUniqueIndex.all(table: table.name, db: db) where index.key == nil {
                problems.append("unique key \(table.name)(\(index.columns.joined(separator: ", "))) has no resolution")
            }
        }
        for key in SyncSchema.uniqueKeys {
            let present = try SyncUniqueIndex.all(table: key.table, db: db).contains { $0.columns == key.columns }
            if !present { problems.append("declared unique key \(key.table)(\(key.columns.joined(separator: ", "))) doesn't exist") }
        }
        return problems
    }

    /// Custom document kinds (import set-aside and kinds, task 4): one kind per name on every device, and an
    /// evidence rule's custom kinds travel as UUIDs.
    func testCustomDocumentKindsAreClassified() {
        XCTAssertEqual(SyncSchema.uniqueKey(table: "customDocumentKind", columns: ["name"])?.resolution, .identity)
        XCTAssertEqual(SyncSchema.jsonReferences.first { $0.table == "evidenceRequirement" && $0.column == "customKindIds" },
                       SyncJSONReference(table: "evidenceRequirement", column: "customKindIds",
                                         content: .rules([SyncJSONRule("[]", .row("customDocumentKind"))]), plainNumbers: []))
        XCTAssertEqual(SyncSchema.table("document")?.foreignKeys["customKindId"], "customDocumentKind")
    }

    func testEveryUniqueKeyHasAResolution() throws {
        let problems = try migrated().dbQueue.read { try undeclaredUniqueKeys($0) }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testAnUndeclaredUniqueKeyFailsByName() throws {
        let manager = try migrated()
        try manager.dbQueue.write { db in try db.execute(sql: "CREATE UNIQUE INDEX account_alias ON account(alias)") }
        XCTAssertEqual(try manager.dbQueue.read { try undeclaredUniqueKeys($0) }, ["unique key account(alias) has no resolution"])
    }

    func testANewIdPathInAKnownShapeFailsByName() {
        XCTAssertEqual(unclassifiedNumbers(column: "evidenceRequirement.scope",
                                           texts: ["{\"transactionsInCategory\":{\"accountId\":2,\"categoryId\":1}}"]),
                       ["evidenceRequirement.scope: transactionsInCategory.accountId"])
        XCTAssertEqual(unclassifiedNumbers(column: "document.persons", texts: ["[{\"personId\":3}]"]),
                       ["document.persons: [].personId"])
    }

    /// Every TEXT column of the demo database holding JSON is a classified JSON column.
    func testEveryJSONColumnIsClassified() throws {
        let manager = try migrated()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("SyncJSON-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(manager.dbQueue, evidenceRoot: evidence)
        let classified = Set(SyncSchema.jsonReferences.map { "\($0.table).\($0.column)" }).union(SyncSchema.jsonColumnsWithoutReferences)
        try manager.dbQueue.read { db in
            for table in SyncSchema.tables {
                for column in table.syncedColumns {
                    let holdsJSON = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS (SELECT 1 FROM "\(table.name)" WHERE typeof("\(column)") = 'text' AND substr("\(column)", 1, 1) IN ('{', '[') AND json_valid("\(column)"))
                        """) ?? false
                    if holdsJSON { XCTAssertTrue(classified.contains("\(table.name).\(column)"), "\(table.name).\(column) holds JSON but isn't classified") }
                }
            }
        }
    }
}
