import XCTest
import GRDB
@testable import BudgetCore

/// A tenancy's addendum ("Aditamento" / "Adenda" ao contrato de arrendamento): its own kind,
/// told from the contract by its text, dated by its signature (else its effective date), with
/// the new rent when it sets one, and linked to the same tenancy as the contract. Synthetic
/// wording, names and numbers only.
final class TenancyAddendumTests: XCTestCase {
    static func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    /// An addendum to contract 1001 (tenant TENANT B): the rent goes from €600.00 to €650.00
    /// from 2025-03-01; signed 2025-02-15.
    static let addendumLines = [
        "ADITAMENTO AO CONTRATO DE ARRENDAMENTO",
        "Entre SENHORIO EXEMPLO, NIF 999999990, Primeiro Outorgante,",
        "e TENANT B, NIF 999999991, Segundo Outorgante,",
        "relativo ao contrato de arrendamento n.º 1001, celebrado em 1 de janeiro de 2024.",
        "Cláusula Primeira: a renda mensal de 600,00 € passa a ser de 650,00 €,",
        "com efeitos a partir de 1 de março de 2025.",
        "Cláusula Segunda: mantêm-se as demais cláusulas do contrato.",
        "Lisboa, 15 de fevereiro de 2025",
        "O Primeiro Outorgante  O Segundo Outorgante"
    ]

    /// A contract (not an addendum), whose clauses mention addenda.
    static let contractLines = [
        "CONTRATO DE ARRENDAMENTO PARA FIM HABITACIONAL",
        "Entre SENHORIO EXEMPLO, NIF 999999990, e TENANT B, NIF 999999991.",
        "Cláusula Primeira: a renda mensal é de 600,00 €.",
        "Cláusula Décima: qualquer aditamento ao presente contrato deve ser feito por escrito.",
        "Lisboa, 20 de dezembro de 2023"
    ]

    static var addendumText: String { addendumLines.joined(separator: "\n") }
    static var contractText: String { contractLines.joined(separator: "\n") }

    // MARK: Kind

    func testKindIsSupported() {
        XCTAssertEqual(DocumentKind.tenancyAddendum.displayName, "Tenancy addendum")
        XCTAssertEqual(DocumentKind(rawValue: "tenancyAddendum"), .tenancyAddendum)
        XCTAssertEqual(ImportNaming.area(of: .tenancyAddendum), "Property")
        XCTAssertTrue(DocumentKind.allCases.contains(.tenancyAddendum))
        XCTAssertTrue(ImportModelProposals.kinds.contains(.tenancyAddendum))
    }

    // MARK: Detection

    func testAddendumIsToldFromTheContractByItsText() {
        XCTAssertEqual(DocumentClassifier.classify(text: Self.addendumText, fileName: "scan.pdf"), .tenancyAddendum)
        XCTAssertEqual(DocumentClassifier.classify(text: Self.contractText, fileName: "scan.pdf"), .rentContract)
        // Lower case, accents, "Adenda", "arrendamento" alone.
        XCTAssertEqual(DocumentClassifier.classify(text: "Adenda ao Contrato de Arrendamento\nAs partes acordam o seguinte.", fileName: "x.pdf"),
                       .tenancyAddendum)
        XCTAssertEqual(DocumentClassifier.classify(text: "1.º aditamento\nArrendamento do 2.º Esq.\nAs partes acordam.", fileName: "x.pdf"),
                       .tenancyAddendum)
        // The text wins over a misleading file name, either way round.
        XCTAssertEqual(DocumentClassifier.classify(text: Self.addendumText, fileName: "Contrato de arrendamento.pdf"), .tenancyAddendum)
        XCTAssertEqual(DocumentClassifier.classify(text: Self.contractText, fileName: "Aditamento contrato.pdf"), .rentContract)
        // Addendum words without a tenancy: not an addendum.
        XCTAssertNotEqual(DocumentClassifier.classify(text: "ADITAMENTO A APOLICE\nSEGURO MULTI-RISCO", fileName: "x.pdf"), .tenancyAddendum)
    }

    func testFileNameHintWithoutText() {
        for name in ["20250215 - Aditamento contrato.pdf", "adenda_arrendamento.pdf", "Tenancy addendum 2025.pdf", "ADDENDUM.pdf"] {
            XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: name), .tenancyAddendum, name)
        }
    }

    func testAnalyzerReadsTheSignatureDateAndTheNewRent() {
        let metadata = EvidenceAnalyzer.analyze(text: Self.addendumText, textStatus: .text, fileName: "scan.pdf").metadata
        XCTAssertEqual(metadata.kind, .tenancyAddendum)
        XCTAssertEqual(metadata.docDate, Self.day("2025-02-15"))
        XCTAssertEqual(metadata.amountMinorUnits, 65_000)
        XCTAssertEqual(metadata.currency, .eur)
    }

    func testWithoutASignatureDateTheEffectiveDate() {
        let unsigned = Self.addendumLines.filter { !$0.hasPrefix("Lisboa") }.joined(separator: "\n")
        XCTAssertEqual(TenancyAddendum.date(in: unsigned), Self.day("2025-03-01"))
        let metadata = EvidenceAnalyzer.analyze(text: unsigned, textStatus: .text, fileName: "scan.pdf").metadata
        XCTAssertEqual(metadata.docDate, Self.day("2025-03-01"))
    }

    func testNoRentWhenTheAddendumSetsNone() {
        let text = "ADITAMENTO AO CONTRATO DE ARRENDAMENTO\nO prazo é prorrogado por um ano.\nPorto, 3 de junho de 2025"
        let metadata = EvidenceAnalyzer.analyze(text: text, textStatus: .text, fileName: "x.pdf").metadata
        XCTAssertEqual(metadata.docDate, Self.day("2025-06-03"))
        XCTAssertNil(metadata.amountMinorUnits)
    }

    // MARK: Naming

    func testCanonicalName() {
        XCTAssertEqual(TenancyAddendum.canonicalName(date: Self.day("2025-02-15"), tenancyLabel: "Room Contract AB"),
                       "20250215 - Property - Tenancy addendum - Room Contract AB")
        XCTAssertEqual(TenancyAddendum.canonicalName(date: Self.day("2025-02-15"), tenancyLabel: nil),
                       "20250215 - Property - Tenancy addendum")
        let facts = [ImportFact(field: .docDate, value: .date(Self.day("2025-02-15")), source: .textLayer, confidence: .certain, reason: "Read"),
                     ImportFact(field: .amount, value: .money(65_000, .eur), source: .textLayer, confidence: .certain, reason: "Read"),
                     ImportFact(field: .reference, value: .text("Room Contract AB"), source: .matchedRecord, confidence: .certain, reason: "Tenancy")]
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/a.pdf"), fileName: "a.pdf", sha256: "s", byteCount: 1, fileExtension: "pdf",
                              text: nil, textStatus: .noText, usedOCR: false)
        let placement = ImportNaming.placement(kind: .evidence(.tenancyAddendum), facts: facts, file: file, persons: [])
        XCTAssertEqual(placement.canonicalName, "20250215 - Property - Tenancy addendum - Room Contract AB")
        XCTAssertEqual(placement.metadata.kind, .tenancyAddendum)
        XCTAssertEqual(placement.metadata.amountMinorUnits, 65_000)
    }

    // MARK: Never a transaction's evidence

    func testNeverSuggestedForATransaction() {
        let account = Account(id: 1, name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
        let credit = Transaction(id: 1, importBatchId: 1, accountId: 1, date: Self.day("2025-02-15"), rawDescription: "TRF RENDA TENANT B",
                                 amountMinorUnits: 65_000, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "1")
        let addendum = EvidenceDocument(sha256: "x", storedRelativePath: "x/x.pdf", originalFileName: "x.pdf", byteCount: 1, kind: .tenancyAddendum,
                                        docDate: Self.day("2025-02-15"), amountMinorUnits: 65_000, currency: .eur, addedAt: Date())
        XCTAssertEqual(EvidenceMatcher.suggestions(document: addendum, transactions: [credit], accounts: [account], categories: []), [])
    }

    func testTenancyContractsRuleAsksForTheContractOnly() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let rules = try PropertyEvidence.defaultRules(db: db, propertyId: property.id!)
            let contracts = try XCTUnwrap(rules.first { $0.scope == .recordsOfProperty(propertyId: property.id!, recordType: .tenancy) })
            XCTAssertEqual(contracts.kinds, [.rentContract])
            XCTAssertFalse(contracts.accepts(.tenancyAddendum))
        }
    }
}

/// Addenda through the planning pipeline: detected, linked to their tenancy, never claiming it.
final class TenancyAddendumImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var ids: [String: Int64] = [:]

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var first = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                tenantName: "TENANT B", startDate: TenancyAddendumTests.day("2024-01-01"))
            try Tenancies.save(db: db, &first)
            ids["ab"] = first.id!
            var second = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract CD", contractNumber: "2002",
                                 tenantName: "TENANT C", startDate: TenancyAddendumTests.day("2024-06-01"))
            try Tenancies.save(db: db, &second)
            ids["cd"] = second.id!
            // The new rent's credit: an addendum is never its evidence.
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bbva.csv", importedAt: Date())
            try batch.insert(db)
            var credit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: TenancyAddendumTests.day("2025-02-15"),
                                     rawDescription: "TRF RENDA TENANT B", amountMinorUnits: 65_000, categoryId: nil, status: .confirmed,
                                     categorizedBy: .manual, fingerprint: "fp-credit")
            try credit.insert(db)
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TenancyAddendumImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline?.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    private func place(_ lines: [String], as name: String) throws -> URL {
        let url = EvidenceTestPDFs.textPDF(lines, name: "source.pdf")
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return target
    }

    private func links(_ entity: EvidenceEntity) throws -> [DocumentLink] {
        try db.read { db in try DocumentLink.filter(Column("entityType") == entity.type.rawValue && Column("entityId") == entity.id).fetchAll(db) }
    }

    /// A contract already in the library, linked to tenancy AB.
    private func libraryContract() throws -> Int64 {
        let url = try place(TenancyAddendumTests.contractLines, as: "contrato.pdf")
        let document = try library.add(url, metadata: EvidenceMetadata(kind: .rentContract)).document.id!
        _ = try library.link(document, to: .tenancy(id("ab")), role: "Contract")
        return document
    }

    func testAddendumIsLinkedToItsTenancyAndNamedAfterIt() async throws {
        let url = try place(TenancyAddendumTests.addendumLines, as: "scan 12.pdf")
        let plan = try await pipeline.plan([url])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.tenancyAddendum))
        XCTAssertEqual(item.recognition.confidence, .certain)
        XCTAssertEqual(item.links.map(\.entity), [.tenancy(id("ab"))], "\(item.links)")
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(item.links.first?.role, "Addendum")
        XCTAssertEqual(item.issues.map(\.reason), [])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.placement?.canonicalName, "20250215 - Property - Tenancy addendum - Room Contract AB")
        XCTAssertEqual(item.placement?.metadata.amountMinorUnits, 65_000)
        _ = try applier.apply(plan, entryPoint: "Documents ▸ Add documents…")
        XCTAssertEqual(try links(.tenancy(id("ab"))).map(\.role), ["Addendum"])
    }

    func testAddendumAddedFromAddContractIsLinkedAsAnAddendum() async throws {
        let url = try place(TenancyAddendumTests.addendumLines, as: "scan 12.pdf")
        let shortcut = ImportShortcut.tenancyContract(tenancyId: id("ab"))
        let plan = try await pipeline.plan([url], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.tenancyAddendum))
        XCTAssertFalse(item.issues.contains { $0.id == "kindMismatch" }, "\(item.issues)")
        XCTAssertEqual(item.links.map(\.entity), [.tenancy(id("ab"))])
        XCTAssertEqual(item.links.first?.role, "Addendum")
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.placement?.canonicalName, "20250215 - Property - Tenancy addendum - Room Contract AB")
    }

    func testAnUnreadAddendumByNameIsNeverDeclaredAContract() async throws {
        let url = try place([], as: "Aditamento contrato.pdf")
        let plan = try await pipeline.plan([url], intent: ImportShortcut.tenancyContract(tenancyId: id("ab")).intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.tenancyAddendum))
        XCTAssertEqual(item.links.first?.role, "Addendum")
    }

    func testAnAddendumNamingNoTenancyAsksWhichOne() async throws {
        let lines = ["ADENDA AO CONTRATO DE ARRENDAMENTO", "As partes acordam prorrogar o prazo por um ano.", "Lisboa, 10 de julho de 2025"]
        let plan = try await pipeline.plan([try place(lines, as: "adenda.pdf")])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { if case .chooseTarget(.tenancy, _) = $0.kind { return true } else { return false } },
                                  "\(item.issues)")
        guard case .chooseTarget(_, let options) = issue.kind else { return XCTFail() }
        XCTAssertEqual(Set(options), [id("ab"), id("cd")])
        XCTAssertEqual(item.placement?.canonicalName, "20250710 - Property - Tenancy addendum")
        XCTAssertEqual(ImportResolutions.correctableTarget(of: item), .tenancy)

        let resolved = try await pipeline.resolve(plan, itemId: item.id, .chooseTarget(.tenancy, id("cd")))
        let chosen = try XCTUnwrap(resolved.items.first)
        XCTAssertEqual(chosen.links.map(\.entity), [.tenancy(id("cd"))])
        XCTAssertEqual(chosen.links.first?.role, "Addendum")
        XCTAssertEqual(chosen.section, .ready, "\(chosen.needsYouReasons)")
        XCTAssertEqual(chosen.placement?.canonicalName, "20250710 - Property - Tenancy addendum - Room Contract CD")
    }

    func testAContractAndSeveralAddendaOnOneTenancyAreNormal() async throws {
        _ = try libraryContract()
        var later = TenancyAddendumTests.addendumLines
        later[later.count - 2] = "Lisboa, 20 de fevereiro de 2026"
        later[4] = "Cláusula Primeira: a renda mensal de 650,00 € passa a ser de 700,00 €,"
        let plan = try await pipeline.plan([try place(TenancyAddendumTests.addendumLines, as: "a1.pdf"), try place(later, as: "a2.pdf")])
        XCTAssertEqual(plan.items.count, 2)
        for item in plan.items {
            XCTAssertEqual(item.links.map(\.entity), [.tenancy(id("ab"))], item.file.fileName)
            XCTAssertEqual(item.issues.map(\.reason), [], item.file.fileName)
            XCTAssertEqual(item.section, .ready, item.file.fileName)
        }
        // A contract and an addendum added together from Add contract…: neither asks.
        let fresh = try await pipeline.plan([try place(TenancyAddendumTests.addendumLines, as: "a3.pdf")],
                                            intent: ImportShortcut.tenancyContract(tenancyId: id("cd")).intent)
        let both = try await pipeline.plan(adding: [try place(TenancyAddendumTests.contractLines.map { $0.replacingOccurrences(of: "TENANT B", with: "TENANT C") },
                                                              as: "contrato cd.pdf")],
                                           to: fresh, intent: ImportShortcut.tenancyContract(tenancyId: id("cd")).intent)
        XCTAssertEqual(both.items.count, 2)
        for item in both.items {
            XCTAssertEqual(item.links.map(\.entity), [.tenancy(id("cd"))], item.file.fileName)
            XCTAssertFalse(item.issues.contains { $0.id.hasPrefix("tenancyHasContract.") }, "\(item.issues)")
        }
        XCTAssertEqual(Set(both.items.compactMap { $0.links.first?.role }), ["Contract", "Addendum"])
    }

    func testTwoContractsOnOneTenancyAreStillFlagged() async throws {
        _ = try libraryContract()
        var other = TenancyAddendumTests.contractLines
        other[2] = "Cláusula Primeira: a renda mensal é de 610,00 €."
        let plan = try await pipeline.plan([try place(other, as: "contrato 2.pdf")],
                                           intent: ImportShortcut.tenancyContract(tenancyId: id("ab")).intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.rentContract))
        let issue = try XCTUnwrap(item.issues.first { $0.id == "tenancyHasContract.\(self.id("ab"))" }, "\(item.issues)")
        XCTAssertEqual(issue.reason, "That tenancy already has a rent contract (contrato.pdf)")
        XCTAssertEqual(item.section, .needsYou)
        // Filed without the link: the tenancy link goes.
        let resolved = try await pipeline.resolve(plan, itemId: item.id, .fileWithoutLink)
        let filed = try XCTUnwrap(resolved.items.first)
        XCTAssertFalse(filed.links.contains { $0.entity == .tenancy(self.id("ab")) })
        XCTAssertTrue(resolved.canConfirm, "\(resolved.items.map(\.needsYouReasons))")
    }

    func testAnAddendumNeitherSatisfiesNorAddsAContractItem() async throws {
        try await db.write { db in _ = try PropertyEvidence.seedRules(db: db, propertyId: self.id("property")) }
        let plan = try await pipeline.plan([try place(TenancyAddendumTests.addendumLines, as: "a1.pdf")])
        _ = try applier.apply(plan, entryPoint: "Documents ▸ Add documents…")
        let period = DateInterval(start: TenancyAddendumTests.day("2025-01-01"), end: TenancyAddendumTests.day("2026-01-01"))
        func contractItems() throws -> [MissingEvidence.Item] {
            try db.read { db in try MissingEvidence.items(db: db, period: period) }
                .filter { $0.target.entity.type == .tenancy }
        }
        var items = try contractItems()
        XCTAssertEqual(Set(items.map(\.target.entity)), [.tenancy(id("ab")), .tenancy(id("cd"))])
        XCTAssertTrue(items.allSatisfy { $0.status == .missing && $0.expectedKinds == [.rentContract] }, "\(items.map(\.status))")

        let contract = try libraryContract()
        items = try contractItems()
        XCTAssertEqual(items.count, 2)
        let ab = try XCTUnwrap(items.first { $0.target.entity == .tenancy(id("ab")) })
        XCTAssertEqual(ab.status, .satisfied)
        XCTAssertEqual(ab.satisfyingDocuments.map(\.id), [contract])
    }
}
