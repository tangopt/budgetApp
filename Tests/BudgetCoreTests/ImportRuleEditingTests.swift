import XCTest
import GRDB
@testable import BudgetCore

/// The Rules page's "Import rules" tab: every learnt import rule as a row (kind, when, then,
/// use, on), edited (its action only), disabled or deleted outside an import run; a rule whose
/// account or record is gone is flagged and skipped by every applier. Synthetic data only.
final class ImportRuleEditingTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var accountId: Int64!
    private var otherAccountId: Int64!
    private var propertyId: Int64!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var account = Account(name: "Everyday Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            var other = Account(name: "Bank Two", currency: .gbp, kind: .cash, trackingMode: .imported)
            try other.insert(db)
            otherAccountId = other.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
        }
    }

    @discardableResult
    private func learn(_ kind: ImportRuleKind, key: String, label: String, action: some Encodable, actionLabel: String) throws -> ImportRule {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: kind, key: key, matchLabel: label, action: action, actionLabel: actionLabel, now: now)
        }
    }

    private func rows() throws -> [ImportRuleRow] { try db.read { db in try ImportRuleEditing.rows(db: db) } }

    private func csv(_ text: String) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/a.csv"), fileName: "a.csv", sha256: "x", byteCount: Int64(text.utf8.count),
                   fileExtension: "csv", text: text, textStatus: .text, usedOCR: false)
    }

    // MARK: Rows

    func testRowsDescribeEachKind() throws {
        try learn(.statementAccount, key: "csv:date|description|amount", label: "CSV with columns Date, Description, Amount",
                  action: StatementAccountAction(accountId: accountId), actionLabel: "Account: Old name")
        try learn(.documentKind, key: "nif:503504564", label: "Example Seguros, S.A.",
                  action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind: \(DocumentKind.insuranceReceipt.displayName)")
        try learn(.issuer, key: "nif:503504565", label: "EXAMPLE POWER LDA", action: IssuerAction(name: "Example Power"), actionLabel: "Name: Example Power")
        try learn(.link, key: "nif:503504564", label: "Example Seguros, S.A.",
                  action: LinkAction(entity: EvidenceEntity(type: .property, id: propertyId)), actionLabel: "Link to Old title")
        try learn(.figurePosition, key: "nif:503504566#amount", label: "Example Water",
                  action: FigurePositionAction(field: .amount, label: "Total a pagar", occurrence: 1), actionLabel: "Amount: after “Total a pagar”")
        try db.write { db in try ImportRuleStore.markUsed(db: db, ids: [1], now: now); try ImportRuleStore.markUsed(db: db, ids: [1], now: now) }

        let rows = try rows()
        XCTAssertEqual(rows.map(\.kindLabel), ["Statement account", "Document type", "Issuer name", "Link", "Figure position"])
        XCTAssertEqual(rows.map(\.when), ["CSV with columns Date, Description, Amount", "Example Seguros, S.A.", "EXAMPLE POWER LDA",
                                          "Example Seguros, S.A.", "Example Water"])
        // A record's current name, not the one stored when it was learnt.
        XCTAssertEqual(rows.map(\.then), ["Account: Everyday Current", "Kind: \(DocumentKind.insuranceReceipt.displayName)",
                                          "Name: Example Power", "Link to Property A", "Amount: after “Total a pagar”"])
        XCTAssertEqual(rows[0].useCount, 2)
        XCTAssertEqual(rows[0].lastUsedAt, now)
        XCTAssertNil(rows[1].lastUsedAt)
        XCTAssertTrue(rows.allSatisfy { $0.isEnabled && !$0.targetMissing })
    }

    // MARK: Missing targets

    func testRuleWithMissingTargetIsSkippedAndFlagged() throws {
        let header = "Date,Description,Amount"
        let signature = try XCTUnwrap(StatementSignature.key(for: csv(header + "\n01/10/2026,SHOP,-1.00"), kind: .bankStatementCSV))
        try learn(.statementAccount, key: signature.key, label: signature.label,
                  action: StatementAccountAction(accountId: otherAccountId), actionLabel: "Account: Bank Two")
        try learn(.link, key: "nif:503504564", label: "Example Seguros, S.A.",
                  action: LinkAction(entity: EvidenceEntity(type: .property, id: propertyId)), actionLabel: "Link to Property A")
        try learn(.link, key: "nif:503504567", label: "Example Gas", action: LinkAction(descriptionKey: "EXAMPLE GAS"), actionLabel: "Paid by “EXAMPLE GAS”")

        try db.write { db in
            _ = try Account.deleteOne(db, key: otherAccountId)
            try Properties.delete(db: db, id: propertyId)
        }

        let rows = try rows()
        XCTAssertEqual(rows.map(\.targetMissing), [true, true, false], "a merchant link has no record to lose")
        XCTAssertEqual(rows[0].then, "Account: Bank Two", "the name it was learnt with")
        XCTAssertEqual(rows[1].then, "Link to Property A")

        // The statement-account applier skips it: the file is no longer remembered.
        try db.read { db in
            let accounts = try Account.fetchAll(db)
            XCTAssertNil(try UKStatementReader.remembered(file: csv(header + "\n01/10/2026,SHOP,-1.00"), kind: .bankStatementCSV,
                                                          accounts: accounts, db: db))
        }
    }

    // MARK: Disable, delete, edit

    func testDeleteAndDisable() throws {
        let header = "Date,Description,Amount"
        let file = csv(header + "\n01/10/2026,SHOP,-1.00")
        let signature = try XCTUnwrap(StatementSignature.key(for: file, kind: .bankStatementCSV))
        let rule = try learn(.statementAccount, key: signature.key, label: signature.label,
                             action: StatementAccountAction(accountId: accountId), actionLabel: "Account: Everyday Current")
        let kindRule = try learn(.documentKind, key: "nif:503504564", label: "Example Seguros, S.A.",
                                 action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind: Insurance")

        func remembered() throws -> Int64? {
            try db.read { db in try UKStatementReader.remembered(file: file, kind: .bankStatementCSV, accounts: try Account.fetchAll(db), db: db)?.accountId }
        }
        XCTAssertEqual(try remembered(), accountId)

        try db.write { db in try ImportRuleEditing.setEnabled(db: db, id: rule.id!, false) }
        XCTAssertEqual(try rows().map(\.isEnabled), [false, true], "still listed, off")
        XCTAssertNil(try remembered(), "a disabled rule isn't applied")

        try db.write { db in try ImportRuleEditing.setEnabled(db: db, id: rule.id!, true) }
        XCTAssertEqual(try remembered(), accountId, "re-enabled, it applies again")

        try db.write { db in try ImportRuleEditing.delete(db: db, id: kindRule.id!) }
        XCTAssertEqual(try rows().map(\.id), [rule.id!])
        XCTAssertNil(try db.read { db in try ImportRule.fetchOne(db, key: kindRule.id!) })
    }

    func testUpdateChangesTheActionOnly() throws {
        let rule = try learn(.statementAccount, key: "csv:date|description|amount", label: "CSV with columns Date, Description, Amount",
                             action: StatementAccountAction(accountId: accountId), actionLabel: "Account: Everyday Current")
        try db.write { db in
            try ImportRuleEditing.setEnabled(db: db, id: rule.id!, false)
            try ImportRuleEditing.update(db: db, id: rule.id!, edit: .account(otherAccountId))
        }
        let saved = try XCTUnwrap(try db.read { db in try ImportRule.fetchOne(db, key: rule.id!) })
        XCTAssertEqual(ImportLearning.decode(StatementAccountAction.self, saved.actionJSON), StatementAccountAction(accountId: otherAccountId))
        XCTAssertEqual(saved.actionLabel, "Account: Bank Two")
        XCTAssertEqual(saved.matchKey, rule.matchKey)
        XCTAssertEqual(saved.matchLabel, rule.matchLabel)
        XCTAssertFalse(saved.isEnabled, "an edit doesn't switch it back on")
        XCTAssertEqual(saved.createdAt, rule.createdAt)

        // Each kind's edit, keeping what the user doesn't edit (a figure's field and occurrence; a link's role for the same kind of record).
        let link = try learn(.link, key: "nif:503504564", label: "Example Seguros, S.A.",
                             action: LinkAction(entity: EvidenceEntity(type: .account, id: accountId), role: "payment proof"), actionLabel: "Link to Everyday Current")
        let figure = try learn(.figurePosition, key: "nif:503504566#amount", label: "Example Water",
                               action: FigurePositionAction(field: .amount, label: "Total", occurrence: 2), actionLabel: "Amount: after “Total”")
        try db.write { db in
            try ImportRuleEditing.update(db: db, id: link.id!, edit: .link(EvidenceEntity(type: .property, id: propertyId)))
            try ImportRuleEditing.update(db: db, id: figure.id!, edit: .figureLabel("  Total a pagar "))
        }
        let rows = try rows()
        XCTAssertEqual(rows.first { $0.id == link.id }?.then, "Link to Property A")
        XCTAssertEqual(rows.first { $0.id == figure.id }?.then, "Amount: after “Total a pagar”")
        let savedLink = try XCTUnwrap(try db.read { db in try ImportRule.fetchOne(db, key: link.id!) })
        XCTAssertEqual(ImportLearning.decode(LinkAction.self, savedLink.actionJSON),
                       LinkAction(entity: EvidenceEntity(type: .property, id: propertyId)), "another kind of record: its role doesn't carry over")
        // The same kind of record keeps the role.
        let sameType = try learn(.link, key: "nif:503504566#record", label: "Example Water",
                                 action: LinkAction(entity: EvidenceEntity(type: .property, id: propertyId), role: "payment proof"), actionLabel: "Link to Property A")
        let otherProperty = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        try db.write { db in try ImportRuleEditing.update(db: db, id: sameType.id!, edit: .link(EvidenceEntity(type: .property, id: otherProperty))) }
        XCTAssertEqual(ImportLearning.decode(LinkAction.self, try XCTUnwrap(try db.read { db in try ImportRule.fetchOne(db, key: sameType.id!) }).actionJSON),
                       LinkAction(entity: EvidenceEntity(type: .property, id: otherProperty), role: "payment proof"))
        let savedFigure = try XCTUnwrap(try db.read { db in try ImportRule.fetchOne(db, key: figure.id!) })
        XCTAssertEqual(ImportLearning.decode(FigurePositionAction.self, savedFigure.actionJSON),
                       FigurePositionAction(field: .amount, label: "Total a pagar", occurrence: 2))

        // An edit that doesn't suit the kind, or a blank name, is refused.
        try db.write { db in
            XCTAssertThrowsError(try ImportRuleEditing.update(db: db, id: figure.id!, edit: .account(accountId)))
            XCTAssertThrowsError(try ImportRuleEditing.update(db: db, id: figure.id!, edit: .figureLabel("  ")))
            XCTAssertThrowsError(try ImportRuleEditing.update(db: db, id: rule.id!, edit: .account(999)), "an account that doesn't exist")
        }
    }

    func testCurrentEditOpensTheSheetWithTheRuleAction() throws {
        let rule = try learn(.issuer, key: "nif:503504565", label: "EXAMPLE POWER LDA", action: IssuerAction(name: "Example Power"), actionLabel: "Name: Example Power")
        let merchant = try learn(.link, key: "nif:503504567", label: "Example Gas", action: LinkAction(descriptionKey: "EXAMPLE GAS"), actionLabel: "Paid by “EXAMPLE GAS”")
        XCTAssertEqual(ImportRuleEditing.currentEdit(rule), .issuerName("Example Power"))
        XCTAssertEqual(ImportRuleEditing.currentEdit(merchant), .merchant("EXAMPLE GAS"))
        try db.write { db in try ImportRuleEditing.update(db: db, id: merchant.id!, edit: .merchant("example gas co")) }
        XCTAssertEqual(try rows().first { $0.id == merchant.id }?.then, "Paid by “EXAMPLE GAS CO”")
    }

    // MARK: Fix round 1

    func testTextEditsNeedALetter() throws {
        let issuer = try learn(.issuer, key: "nif:503504565", label: "EXAMPLE POWER LDA", action: IssuerAction(name: "Example Power"), actionLabel: "Name: Example Power")
        let merchant = try learn(.link, key: "nif:503504567", label: "Example Gas", action: LinkAction(descriptionKey: "EXAMPLE GAS"), actionLabel: "Paid by “EXAMPLE GAS”")
        let figure = try learn(.figurePosition, key: "nif:503504566#amount", label: "Example Water",
                               action: FigurePositionAction(field: .amount, label: "Total", occurrence: 1), actionLabel: "Amount: after “Total”")
        for text in ["123", "—", "---", " 42 € "] {
            XCTAssertFalse(ImportRuleEditing.isValidText(text), text)
            XCTAssertThrowsError(try ImportRuleEditing.checkedText(text)) { XCTAssertEqual($0 as? ImportRuleEditError, .noLetters, text) }
            try db.write { db in
                for (id, edit) in [(issuer.id!, ImportRuleEdit.issuerName(text)), (merchant.id!, .merchant(text)), (figure.id!, .figureLabel(text))] {
                    XCTAssertThrowsError(try ImportRuleEditing.update(db: db, id: id, edit: edit)) {
                        XCTAssertEqual($0 as? ImportRuleEditError, .noLetters, "\(edit)")
                    }
                }
            }
        }
        XCTAssertThrowsError(try ImportRuleEditing.checkedText("   ")) { XCTAssertEqual($0 as? ImportRuleEditError, .blank) }
        XCTAssertEqual(try ImportRuleEditing.checkedText("  Total 2 "), "Total 2")
        XCTAssertTrue(ImportRuleEditing.isValidText("Água"))
        XCTAssertEqual(try rows().map(\.then), ["Name: Example Power", "Paid by “EXAMPLE GAS”", "Amount: after “Total”"], "nothing saved")
    }

    func testLinkToADeletedPropertyIsNotApplied() throws {
        try learn(.link, key: "nif:503504564", label: "Example Seguros, S.A.",
                  action: LinkAction(entity: EvidenceEntity(type: .property, id: propertyId)), actionLabel: "Link to Property A")
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/seguro.pdf"), fileName: "seguro.pdf", sha256: "sha-seguro", byteCount: 1,
                              fileExtension: "pdf", text: "Example Seguros, S.A. NIF 503504564\nSEGURO MULTI-RISCO HABITACAO\nTOTAL 120,00 €",
                              textStatus: .text, usedOCR: false)
        let item = ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                              title: "Insurance receipt", groupKey: "Insurance receipt documents")
        func applied() throws -> ImportItem {
            try db.read { db in try ImportLearning.applyLinkRules(item, rules: try ImportRuleStore.all(db: db), db: db, ownNIFs: []) }
        }
        XCTAssertEqual(try applied().links.map(\.entity), [EvidenceEntity(type: .property, id: propertyId)], "applied while the property exists")

        try db.write { db in try Properties.delete(db: db, id: propertyId) }
        let skipped = try applied()
        XCTAssertEqual(skipped.links, [])
        XCTAssertEqual(skipped.appliedRules, [])
        XCTAssertEqual(try rows().map(\.targetMissing), [true])
    }
}
