import GRDB
import Foundation

private func isoDay(_ date: Date?) -> String { RentReceiptPDFs.dayText(date) }

private func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }

// MARK: Rent receipts export

/// The portal's receipts export (`.xlsx`): which property it is for and what importing it would do.
public struct RentReceiptsExportReader: ImportReader {
    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .rentReceiptsExport }

    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        try files.map { try item(file: $0.file, recognition: $0.recognition, context: context, db: db) }
    }

    private func item(file: ImportFile, recognition: ImportRecognition, context: ImportContext, db: Database) throws -> ImportItem {
        func failed(_ error: Error) -> ImportItem {
            let text = "The export could not be read: \(error.localizedDescription)"
            return ImportItem(file: file, recognition: recognition, title: "Receipts export",
                              issues: [ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: text)],
                              groupKey: "Rent receipts export")
        }
        let rows: [RentReceiptsExport.Row]
        do {
            rows = try RentReceiptsExport.parse(xlsx: Data(contentsOf: file.url))
        } catch {
            return failed(error)
        }
        var issues: [ImportIssue] = []
        var reasons: [String] = []
        var property: Property?
        var fromIntent = false
        let contracts = Set(rows.map(\.contractNumber))
        let owners = Set(try Tenancy.filter(contracts.contains(Column("contractNumber"))).fetchAll(db).map(\.propertyId))
        let known = context.properties.filter { owners.contains($0.id ?? -1) }
        if let id = context.intent.propertyId, let found = context.properties.first(where: { $0.id == id }) {
            property = found
            fromIntent = true
            reasons = ["Chosen as the import target"]
            if !known.isEmpty, !known.contains(where: { $0.id == id }) {
                let options = [id] + known.compactMap(\.id)
                let names = known.map(\.name).joined(separator: ", ")
                issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.property, options: options),
                                          reason: "Contract \(contracts.sorted().joined(separator: ", ")) already belongs to \(names), not \(found.name): which property is this export for?"))
            }
        } else if known.count == 1 {
            property = known[0]
            reasons = ["Contract \(contracts.sorted().joined(separator: ", ")) already belongs to this property"]
        } else if known.isEmpty, context.properties.count == 1 {
            property = context.properties[0]
            reasons = ["The only property"]
        } else {
            let options = (known.isEmpty ? context.properties : known).compactMap(\.id)
            issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.property, options: options),
                                      reason: "Which property is this export for?"))
        }

        let starts = rows.map(\.periodStart), ends = rows.map(\.periodEnd)
        let span = "\(plural(rows.count, "row", "rows")), \(isoDay(starts.min())) to \(isoDay(ends.max()))"
        var facts: [ImportFact] = []
        if let start = starts.min() {
            facts.append(ImportFact(field: .periodStart, value: .date(start), source: .textLayer, confidence: .certain, reason: span))
        }
        if let end = ends.max() {
            facts.append(ImportFact(field: .periodEnd, value: .date(end), source: .textLayer, confidence: .certain, reason: span))
        }
        if let property {
            facts.append(ImportFact(field: .reference, value: .text(property.name), source: fromIntent ? .intent : .textLayer,
                                    confidence: .certain, reason: reasons.first ?? ""))
        }
        var title = "Receipts export: \(plural(rows.count, "receipt", "receipts"))"
        var effect = ImportEffect.none
        var links: [ProposedLink] = []
        if let property, let propertyId = property.id {
            do {
                let report = try RentReceiptImport.preview(db: db, propertyId: propertyId, rows: rows)
                title = "Receipts export: \(plural(contracts.count, "tenancy", "tenancies")), \(plural(rows.count, "receipt", "receipts")) "
                    + "(\(report.createdReceipts) new, \(report.cancelledReceipts) cancelled)"
            } catch {
                let text = "The export could not be checked against the property: \(error.localizedDescription)"
                issues.append(ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: text))
            }
            effect = .rentReceiptsExport(propertyId: propertyId, rows: rows)
            links = [ProposedLink(entity: .property(propertyId), label: "Export for \(property.name)", confidence: .certain,
                                  reasons: reasons)]
        }
        let placement = ImportNaming.placement(kind: .rentReceiptsExport, facts: facts, file: file, persons: [])
        return ImportItem(file: file, recognition: recognition, title: title, facts: facts, placement: placement, links: links,
                          effect: effect, issues: issues, groupKey: "Rent receipts export")
    }
}

// MARK: Rent receipt PDFs

/// The portal's "Recibo de renda eletrónico" PDFs, matched to the receipts already imported.
public struct RentReceiptPDFReader: ImportReader {
    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .rentReceiptPDF }

    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        // A tenancy the user chose (a contract number on several tenancies).
        let tenancyId = context.intent.target.flatMap { $0.entity.type == .tenancy ? $0.entity.id : nil }
        let inputs = files.map { RentReceiptPDFs.Input(fileURL: $0.file.url, sha256: $0.file.sha256, text: $0.file.text,
                                                        textStatus: $0.file.textStatus, usedOCR: $0.file.usedOCR, tenancyId: tenancyId) }
        let plan = try RentReceiptPDFs.plan(db: db, inputs: inputs)
        return try zip(files, plan.items).map { pair, planned in
            try item(file: pair.file, recognition: pair.recognition, planned: planned, db: db)
        }
    }

    private func item(file: ImportFile, recognition: ImportRecognition, planned: RentReceiptPDFs.Item, db: Database) throws -> ImportItem {
        let source: ImportFactSource = planned.usedOCR ? .ocr : .textLayer
        var facts: [ImportFact] = []
        var title = file.fileName
        var label = "Receipt"
        if let parsed = planned.parsed {
            label = "Receipt nº \(parsed.receiptNumber) of contract \(parsed.contractNumber)"
            title = "Rent receipt nº \(parsed.receiptNumber), contract \(parsed.contractNumber)"
            func add(_ field: ImportFigureField, _ value: ImportFactValue, _ reason: String) {
                facts.append(ImportFact(field: field, value: value, source: source, confidence: .certain, reason: reason))
            }
            add(.reference, .text(parsed.contractNumber), "Contract number on the receipt")
            add(.receiptNumber, .text(parsed.receiptNumber), "Receipt number on the receipt")
            if let date = parsed.issueDate { add(.docDate, .date(date), "Issue date on the receipt") }
            if let start = parsed.periodStart { add(.periodStart, .date(start), "Period on the receipt") }
            if let end = parsed.periodEnd { add(.periodEnd, .date(end), "Period on the receipt") }
            if let amount = parsed.amountMinorUnits { add(.amount, .money(amount, .eur), "Rent on the receipt") }
        }
        var item = ImportItem(file: file, recognition: recognition, title: title, facts: facts, groupKey: "Rent receipt PDFs")
        if planned.parsed != nil {
            item.placement = ImportNaming.placement(kind: .rentReceiptPDF, facts: facts, file: file, persons: [])
        }
        func problem(_ text: String) {
            item.issues.append(ImportIssue(id: "readerProblem\(item.issues.count)", kind: .readerProblem(text), reason: text))
        }
        switch planned.outcome {
        case .link:
            for text in planned.nifProblems {
                item.issues.append(ImportIssue(id: "readerProblem\(item.issues.count)", kind: .readerProblem(text), reason: text,
                                               offers: [.acknowledge]))
            }
            item.effect = .rentReceiptPDF(planned)
            if let receipt = planned.receipt, let id = receipt.id, let parsed = planned.parsed {
                item.links = [ProposedLink(entity: .rentReceipt(id), role: "Receipt", label: label, confidence: .certain,
                                           reasons: ["Contract \(parsed.contractNumber), receipt nº \(parsed.receiptNumber), amounts agree"],
                                           madeByEffect: true)]
            }
        case .alreadyLinked:
            item.duplicate = ImportDuplicate(level: .document, of: "\(label) already has this PDF",
                                             existingDocumentId: planned.existingDocumentId)
        case .duplicate(let first):
            item.duplicate = ImportDuplicate(level: .file, of: "Same receipt as \(first)")
        case .mismatch:
            for mismatch in planned.mismatches {
                let field = mismatch.field.prefix(1).uppercased() + mismatch.field.dropFirst()
                problem("\(field): PDF \(mismatch.pdf), stored \(mismatch.stored)")
            }
        case .noReceipt:
            let number = planned.parsed?.receiptNumber ?? "?", contract = planned.parsed?.contractNumber ?? "?"
            problem("No receipt nº \(number) for contract \(contract): import the portal export first")
        case .ambiguousContract:
            let options: [Int64] = try planned.parsed.map { parsed in
                try Tenancy.filter(Column("contractNumber") == parsed.contractNumber).fetchAll(db).compactMap(\.id)
            } ?? []
            item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.tenancy, options: options),
                                           reason: "More than one tenancy has this contract number: which one is it?"))
        case .unreadable:
            item.issues.append(ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: nil),
                                           reason: "Not readable as a rent receipt"))
        }
        return item
    }
}

// MARK: Transfer advices

/// BBVA "transferência recebida" advices, matched to the tenant credit they announce.
public struct TransferAdviceReader: ImportReader {
    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .transferAdvice }

    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        var inputs: [RentCreditEvidence.AdviceInput?] = []
        for entry in files {
            inputs.append(entry.file.text.flatMap(RentCreditEvidence.parseAdvice).map {
                RentCreditEvidence.AdviceInput(source: .file(entry.file.url), name: entry.file.fileName, sha256: entry.file.sha256,
                                               advice: $0, text: entry.file.text, textStatus: entry.file.textStatus)
            })
        }
        let readable = inputs.compactMap { $0 }
        let properties = context.intent.propertyId.map { id in context.properties.filter { $0.id == id } } ?? context.properties
        var plans: [[RentCreditEvidence.AdvicePlanItem]] = []
        var propertyIds: [Int64?] = []
        for property in properties {
            guard let id = property.id else { continue }
            propertyIds.append(id)
            plans.append(try RentCreditEvidence.planAdvices(db: db, propertyId: id, inputs: readable))
        }
        var readableIndex = 0
        var result: [ImportItem] = []
        for (entry, input) in zip(files, inputs) {
            guard let input else {
                result.append(ImportItem(file: entry.file, recognition: entry.recognition, title: entry.file.fileName,
                                         issues: [ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: nil),
                                                              reason: "Not readable as a received-transfer advice")],
                                         groupKey: "Transfer advices"))
                continue
            }
            let candidates = plans.indices.map { (propertyId: propertyIds[$0], planned: plans[$0][readableIndex]) }
            readableIndex += 1
            let best = candidates.min { Self.rank($0.planned.outcome) < Self.rank($1.planned.outcome) }
                ?? (propertyId: nil, planned: RentCreditEvidence.AdvicePlanItem(input: input, outcome: .noCredit))
            result.append(item(file: entry.file, recognition: entry.recognition, planned: best.planned, readable: readable))
        }
        return result
    }

    private static func rank(_ outcome: RentCreditEvidence.AdviceOutcome) -> Int {
        switch outcome {
        case .link: return 0
        case .alreadyLinked: return 1
        case .copyOfLinked: return 2
        case .duplicate: return 3
        case .ambiguous: return 4
        case .conflict: return 5
        case .notRent: return 6
        case .unconfirmed: return 7
        case .noCredit: return 8
        }
    }

    /// Whether the credit's statement reference or its payer is what the advice names.
    private static func named(_ credit: Transaction, in advice: RentCreditEvidence.Advice) -> String {
        if let first = credit.rawDescription.split(separator: " ").first, first.count >= 6,
           advice.compactText.contains(EvidenceText.fold(String(first)).uppercased()) {
            return "its reference \(first) is named in the advice"
        }
        return "its payer is named in the advice"
    }

    private func item(file: ImportFile, recognition: ImportRecognition, planned: RentCreditEvidence.AdvicePlanItem,
                      readable: [RentCreditEvidence.AdviceInput]) -> ImportItem {
        let advice = planned.input.advice
        let amounts = planned.credits.isEmpty ? advice.amounts.sorted() : [planned.amountMinorUnits]
        var facts = [ImportFact(field: .docDate, value: .date(advice.date), source: file.usedOCR ? .ocr : .textLayer,
                                confidence: .certain, reason: "Date on the advice")]
        if amounts.count == 1 {
            // Read from the advice when it states one amount; otherwise the matched credit's (a matching result).
            facts.append(ImportFact(field: .amount, value: .money(amounts[0], .eur),
                                    source: planned.credits.isEmpty ? (file.usedOCR ? .ocr : .textLayer) : .matchedRecord,
                                    confidence: .certain, reason: planned.credits.isEmpty ? "Amount on the advice" : "Amount of the matched credit"))
        }
        var item = ImportItem(file: file, recognition: recognition, title: "Transfer advice of \(isoDay(advice.date))",
                              facts: facts, groupKey: "Transfer advices")
        item.placement = ImportNaming.placement(kind: .transferAdvice, facts: facts, file: file, persons: [])
        func problem(_ text: String, offers: [ImportResolution] = []) {
            item.issues.append(ImportIssue(id: "readerProblem\(item.issues.count)", kind: .readerProblem(text), reason: text, offers: offers))
        }
        let creditText = planned.credits.first.map { "credit \($0.rawDescription) of \(Money.format($0.amountMinorUnits, currency: .eur)) on \(isoDay($0.date))" } ?? "a credit"
        switch planned.outcome {
        case .link:
            item.effect = .transferAdvice(planned)
            item.links = planned.credits.compactMap { credit in
                credit.id.map { ProposedLink(entity: .transaction($0), role: RentCreditEvidence.adviceRole,
                                             label: "\(credit.rawDescription) \(Money.format(credit.amountMinorUnits, currency: .eur))",
                                             confidence: .certain,
                                             reasons: ["Booked on \(isoDay(credit.date)) for \(Money.format(credit.amountMinorUnits, currency: .eur)); "
                                                       + Self.named(credit, in: advice)],
                                             madeByEffect: true) }
            }
        case .ambiguous:
            let all = ([planned.credits] + planned.alternatives).flatMap { $0 }
            let candidates = all.compactMap { credit -> LinkCandidate? in
                guard let id = credit.id else { return nil }
                var reasons = ["Booked on \(isoDay(credit.date)) for \(Money.format(credit.amountMinorUnits, currency: .eur)), within days of the advice; "
                               + Self.named(credit, in: advice)]
                if !planned.competingAdvices.isEmpty {
                    reasons.append("\(planned.competingAdvices.joined(separator: ", ")) also claims this credit")
                }
                return LinkCandidate(entity: .transaction(id), label: "\(credit.rawDescription) \(Money.format(credit.amountMinorUnits, currency: .eur))",
                                     reasons: reasons)
            }
            let why = planned.competingAdvices.isEmpty ? "More than one credit fits this advice: which one is it?"
                : "Another advice (\(planned.competingAdvices.joined(separator: ", "))) also claims the same credit: which one is it?"
            item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink(candidates), reason: why, offers: [.fileWithoutLink]))
        case .noCredit:
            let amount = advice.amounts.sorted().map { Money.format($0, currency: .eur) }.joined(separator: " or ")
            problem("No credit of \(amount) around \(isoDay(advice.date)) yet", offers: [.fileWithoutLink])
        case .alreadyLinked, .copyOfLinked:
            item.duplicate = ImportDuplicate(level: .document,
                                             of: planned.outcome == .alreadyLinked ? "Its credit already has this advice"
                                                 : "Its credit already has a copy of this advice",
                                             existingDocumentId: planned.documentId)
        case .duplicate:
            let first = readable.first { $0.sha256 == planned.input.sha256 }?.name ?? planned.input.name
            item.duplicate = ImportDuplicate(level: .file, of: "Same file as \(first)")
        case .notRent:
            problem("The matching \(creditText) is not from a tenant: not linked")
        case .unconfirmed:
            problem("A credit fits the date and amount, but neither its reference nor its payer is named in the advice")
        case .conflict:
            problem("This advice's document is already linked to another transaction")
        }
        return item
    }
}
