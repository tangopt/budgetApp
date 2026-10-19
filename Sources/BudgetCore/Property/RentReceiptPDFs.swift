import GRDB
import Foundation

/// The Portal das Finanças rent-receipt PDFs ("Recibo de renda eletrónico"): reads each one,
/// matches it to its imported `RentReceipt` (contract + receipt number), checks the PDF and the
/// stored receipt agree, then adds the PDF to the evidence library as a rent receipt and links
/// it to the receipt — as the app's "Add PDF…" on a receipt does. Idempotent: a PDF already in
/// the library is reused, an existing link is left as it is.
public enum RentReceiptPDFs {
    // MARK: Reading

    /// What a receipt PDF states. Amounts in cents (EUR); days at 00:00 UTC.
    public struct Parsed: Equatable, Sendable {
        public var contractNumber: String
        public var receiptNumber: String
        /// "Data de emissão".
        public var issueDate: Date?
        /// "Período a que respeita a renda", both days inclusive.
        public var periodStart: Date?
        public var periodEnd: Date?
        /// "Data de recebimento" (the stored `receiptDate`).
        public var receiptDate: Date?
        /// "Valor": the rent.
        public var amountMinorUnits: Int?
        /// "Retenção de IRS".
        public var withholdingMinorUnits: Int?
        /// "Importância recebida".
        public var amountReceivedMinorUnits: Int?
        public var landlordName: String?
        public var landlordNIF: String?
        public var tenantName: String?
        public var tenantNIF: String?

        public init(contractNumber: String, receiptNumber: String, issueDate: Date? = nil, periodStart: Date? = nil,
                    periodEnd: Date? = nil, receiptDate: Date? = nil, amountMinorUnits: Int? = nil, withholdingMinorUnits: Int? = nil,
                    amountReceivedMinorUnits: Int? = nil, landlordName: String? = nil, landlordNIF: String? = nil,
                    tenantName: String? = nil, tenantNIF: String? = nil) {
            self.contractNumber = contractNumber
            self.receiptNumber = receiptNumber
            self.issueDate = issueDate
            self.periodStart = periodStart
            self.periodEnd = periodEnd
            self.receiptDate = receiptDate
            self.amountMinorUnits = amountMinorUnits
            self.withholdingMinorUnits = withholdingMinorUnits
            self.amountReceivedMinorUnits = amountReceivedMinorUnits
            self.landlordName = landlordName
            self.landlordNIF = landlordNIF
            self.tenantName = tenantName
            self.tenantNIF = tenantNIF
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let date = #"(\d{4}-\d{2}-\d{2})"#
    private static let money = #"(\d{1,3}(?:\.\d{3})*,\d{2}|\d+,\d{2})"#
    private static let numberPattern = regex(#"RECIBO DE RENDA N\S{0,3}\s*(\d+)\s*/\s*(\d+)"#)
    private static let issuePattern = regex(#"DATA DE EMISSAO\s+"# + date)
    private static let periodPattern = regex(#"Periodo a que respeita a renda\s+"# + date + #"\s+a\s+"# + date)
    private static let amountPattern = regex(#"Valor\s+"# + money)
    private static let withholdingPattern = regex(#"Retencao de IRS[^\n]*\s+"# + money)
    private static let receivedPattern = regex(#"Importancia Recebida\s+"# + money)
    private static let receiptDatePattern = regex(#"Data de recebimento:?\s*"# + date)
    private static let landlordPattern = regex(#"LOCADOR[^\n]*\n\s*NOME\s+NIF\s*\n\s*([^\n]*?)\s+(\d{9})(?!\d)"#)
    private static let tenantPattern = regex(#"LOCATARIO[^\n]*\n(?:[^\n]*\n){0,4}?\s*PAIS\s*\n\s*([^\n]*?)(?:\s+(\d{9}))?\s*\n"#)

    /// Reads a receipt's text (its first copy, "Original"); `nil` when it isn't a rent receipt
    /// (no "Recibo de renda n.º <contract>/<receipt>").
    public static func parse(_ text: String) -> Parsed? {
        let folded = EvidenceText.fold(text).replacingOccurrences(of: "\r\n", with: "\n")
        let source = folded as NSString
        let all = NSRange(location: 0, length: source.length)
        func groups(_ pattern: NSRegularExpression) -> [String?]? {
            guard let match = pattern.firstMatch(in: folded, range: all) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let number = groups(numberPattern), let contract = number[0], let receipt = number[1] else { return nil }
        var parsed = Parsed(contractNumber: contract, receiptNumber: receipt)
        parsed.issueDate = groups(issuePattern)?[0].flatMap(day)
        if let period = groups(periodPattern) {
            parsed.periodStart = period[0].flatMap(day)
            parsed.periodEnd = period[1].flatMap(day)
        }
        parsed.amountMinorUnits = groups(amountPattern)?[0].flatMap(cents)
        parsed.withholdingMinorUnits = groups(withholdingPattern)?[0].flatMap(cents)
        parsed.amountReceivedMinorUnits = groups(receivedPattern)?[0].flatMap(cents)
        parsed.receiptDate = groups(receiptDatePattern)?[0].flatMap(day)
        if let landlord = groups(landlordPattern) {
            parsed.landlordName = landlord[0].flatMap(Transaction.normalizedNote)
            parsed.landlordNIF = landlord[1]
        }
        if let tenant = groups(tenantPattern) {
            parsed.tenantName = tenant[0].flatMap(Transaction.normalizedNote)
            parsed.tenantNIF = tenant[1]
        }
        return parsed
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return EvidenceDateParser.makeDate(year: parts[0], month: parts[1], day: parts[2])
    }

    static func cents(_ text: String) -> Int? {
        let pieces = text.replacingOccurrences(of: ".", with: "").split(separator: ",")
        guard pieces.count == 2, let whole = Int(pieces[0]), let fraction = Int(pieces[1]), pieces[1].count == 2 else { return nil }
        return whole * 100 + fraction
    }

    /// Whether `nif` is a valid Portuguese tax number: nine digits, the last a mod-11 check digit.
    public static func isValidNIF(_ nif: String) -> Bool {
        let digits = nif.compactMap(\.wholeNumberValue)
        guard digits.count == 9, nif.count == 9 else { return false }
        let sum = (0..<8).reduce(0) { $0 + digits[$1] * (9 - $1) }
        let remainder = sum % 11
        let check = remainder < 2 ? 0 : 11 - remainder
        return digits[8] == check
    }

    /// A PDF read from disk: its hash, text (text layer, else OCR of an image-only file) and the
    /// analyser's proposal for the library.
    public struct Input: Sendable {
        public var fileURL: URL
        public var sha256: String
        public var text: String?
        public var textStatus: DocumentTextStatus
        public var usedOCR: Bool
        public var analysis: EvidenceAnalysis

        public var fileName: String { fileURL.lastPathComponent }

        public init(fileURL: URL, sha256: String, text: String?, textStatus: DocumentTextStatus, usedOCR: Bool = false) {
            self.fileURL = fileURL
            self.sha256 = sha256
            self.text = text
            self.textStatus = textStatus
            self.usedOCR = usedOCR
            self.analysis = EvidenceAnalyzer.analyze(text: text, textStatus: textStatus, fileName: fileURL.lastPathComponent)
        }
    }

    /// Reads `url` (only read).
    public static func read(_ url: URL, ocr: Bool = true) throws -> Input {
        let sha = try EvidenceLibrary.sha256(of: url)
        let read = UtilityInvoiceIntake.text(of: url, ocr: ocr)
        return Input(fileURL: url, sha256: sha, text: read.text, textStatus: read.status, usedOCR: read.usedOCR)
    }

    /// The PDFs of `folder` (not its subfolders), by name in natural order (`_2` before `_10`).
    public static func pdfs(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Matching

    /// A field on which the PDF and the stored receipt (or tenancy) disagree, or that the PDF
    /// doesn't state readably.
    public struct Mismatch: Equatable, Sendable {
        public var field: String
        public var pdf: String
        public var stored: String
    }

    public enum Outcome: Equatable, Sendable {
        /// Matched and agreeing: to add (or reuse) and link.
        case link
        /// Matched, agreeing, and already linked to this receipt.
        case alreadyLinked
        /// Matched but some field disagrees: not linked.
        case mismatch
        /// No stored receipt with this contract and receipt number.
        case noReceipt
        /// The contract number belongs to more than one tenancy.
        case ambiguousContract
        /// Not readable as a rent receipt.
        case unreadable
        /// The same file (hash) or the same receipt as an earlier PDF of the batch.
        case duplicate(of: String)
    }

    public struct Item: Equatable, Sendable {
        public var fileName: String
        public var sha256: String
        public var textStatus: DocumentTextStatus
        public var usedOCR: Bool
        public var parsed: Parsed?
        public var receipt: RentReceipt?
        public var tenancy: Tenancy?
        public var outcome: Outcome
        public var mismatches: [Mismatch]
        /// The library's document with this content, if already there.
        public var existingDocumentId: Int64?
        /// Other documents already linked to the receipt (another PDF of it).
        public var otherLinkedDocumentIds: [Int64]
    }

    public struct Plan: Equatable, Sendable {
        public var items: [Item]
        /// Receipts of the tenancies the PDFs cover that no PDF of the batch matched, with
        /// whether they already have a linked document.
        public var receiptsWithoutPDF: [(receipt: RentReceipt, hasDocument: Bool)]
        /// Cancelled receipts of those tenancies (matched by a PDF or not).
        public var cancelledReceipts: [RentReceipt]
        /// NIF problems across the batch: not a valid NIF, or differing between PDFs of a contract.
        public var nifIssues: [String]
        /// The distinct (role, name, NIF) stated, for the report.
        public var parties: [String]

        public static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.items == rhs.items && lhs.cancelledReceipts == rhs.cancelledReceipts && lhs.nifIssues == rhs.nifIssues
                && lhs.parties == rhs.parties
                && lhs.receiptsWithoutPDF.map(\.receipt) == rhs.receiptsWithoutPDF.map(\.receipt)
                && lhs.receiptsWithoutPDF.map(\.hasDocument) == rhs.receiptsWithoutPDF.map(\.hasDocument)
        }

        public func count(_ outcome: Outcome) -> Int { items.filter { $0.outcome == outcome }.count }
    }

    static func dayText(_ date: Date?) -> String {
        guard let date else { return "(blank)" }
        let parts = EvidenceText.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func moneyText(_ minor: Int?) -> String {
        guard let minor else { return "(unreadable)" }
        return Money.format(minor, currency: .eur)
    }

    /// The fields on which `parsed` and `receipt` (of `tenancy`) disagree.
    public static func mismatches(_ parsed: Parsed, receipt: RentReceipt, tenancy: Tenancy) -> [Mismatch] {
        var found: [Mismatch] = []
        func compareDay(_ field: String, _ pdf: Date?, _ stored: Date?) {
            let pdfDay = pdf.map(PropertyDates.day), storedDay = stored.map(PropertyDates.day)
            if pdfDay != storedDay { found.append(Mismatch(field: field, pdf: pdf == nil ? "(unreadable)" : dayText(pdf), stored: dayText(stored))) }
        }
        func compareMoney(_ field: String, _ pdf: Int?, _ stored: Int) {
            if pdf != stored { found.append(Mismatch(field: field, pdf: moneyText(pdf), stored: moneyText(stored))) }
        }
        compareDay("period start", parsed.periodStart, receipt.periodStart)
        compareDay("period end", parsed.periodEnd, receipt.periodEnd)
        compareDay("receipt date", parsed.receiptDate, receipt.receiptDate)
        compareMoney("amount", parsed.amountMinorUnits, receipt.amountMinorUnits)
        compareMoney("withholding", parsed.withholdingMinorUnits, receipt.withholdingMinorUnits)
        compareMoney("amount received", parsed.amountReceivedMinorUnits, receipt.amountReceivedMinorUnits)
        if let stored = tenancy.tenantName, !stored.isEmpty {
            let pdf = parsed.tenantName.map(EvidenceText.normalized)
            if pdf != EvidenceText.normalized(stored) {
                found.append(Mismatch(field: "tenant", pdf: parsed.tenantName ?? "(unreadable)", stored: stored))
            }
        }
        if parsed.issueDate == nil { found.append(Mismatch(field: "issue date", pdf: "(unreadable)", stored: "-")) }
        return found
    }

    /// Matches each input to its receipt and checks them; reads only.
    public static func plan(db: Database, inputs: [Input]) throws -> Plan {
        var items: [Item] = []
        var seenHashes: [String: String] = [:]
        var seenReceipts: [Int64: String] = [:]
        var tenancyIds: Set<Int64> = []
        var matchedReceiptIds: Set<Int64> = []
        for input in inputs {
            var item = Item(fileName: input.fileName, sha256: input.sha256, textStatus: input.textStatus, usedOCR: input.usedOCR,
                            parsed: input.text.flatMap(parse), receipt: nil, tenancy: nil, outcome: .unreadable, mismatches: [],
                            existingDocumentId: try EvidenceDocument.filter(Column("sha256") == input.sha256).fetchOne(db)?.id,
                            otherLinkedDocumentIds: [])
            defer { items.append(item) }
            if let first = seenHashes[input.sha256] {
                item.outcome = .duplicate(of: first)
                continue
            }
            seenHashes[input.sha256] = input.fileName
            guard let parsed = item.parsed else { continue }
            let tenancies = try Tenancy.filter(Column("contractNumber") == parsed.contractNumber).fetchAll(db)
            guard !tenancies.isEmpty else {
                item.outcome = .noReceipt
                continue
            }
            guard tenancies.count == 1, let tenancy = tenancies.first else {
                item.outcome = .ambiguousContract
                continue
            }
            item.tenancy = tenancy
            tenancyIds.insert(tenancy.id!)
            guard let receipt = try RentReceipts.receipt(db: db, tenancyId: tenancy.id!, receiptNumber: parsed.receiptNumber) else {
                item.outcome = .noReceipt
                continue
            }
            item.receipt = receipt
            if let first = seenReceipts[receipt.id!] {
                item.outcome = .duplicate(of: first)
                continue
            }
            seenReceipts[receipt.id!] = input.fileName
            matchedReceiptIds.insert(receipt.id!)
            let linked = try EvidenceLinks.documents(db: db, for: .rentReceipt(receipt.id!)).compactMap(\.id)
            item.otherLinkedDocumentIds = linked.filter { $0 != item.existingDocumentId }
            item.mismatches = mismatches(parsed, receipt: receipt, tenancy: tenancy)
            if !item.mismatches.isEmpty {
                item.outcome = .mismatch
            } else if let existing = item.existingDocumentId, linked.contains(existing) {
                item.outcome = .alreadyLinked
            } else {
                item.outcome = .link
            }
        }

        var receiptsWithoutPDF: [(receipt: RentReceipt, hasDocument: Bool)] = []
        var cancelled: [RentReceipt] = []
        let linkCounts = try EvidenceLinks.linkCounts(db: db, .rentReceipt)
        for tenancyId in tenancyIds.sorted() {
            for receipt in try RentReceipts.receipts(db: db, tenancyId: tenancyId, includeCancelled: true) {
                if receipt.status == .cancelled { cancelled.append(receipt) }
                if !matchedReceiptIds.contains(receipt.id!) {
                    receiptsWithoutPDF.append((receipt, (linkCounts[receipt.id!] ?? 0) > 0))
                }
            }
        }

        // NIFs: valid, and one landlord and one tenant per contract.
        var nifIssues: [String] = []
        var parties: [String] = []
        let parsedItems = items.filter { item in if case .duplicate = item.outcome { return false } else { return item.parsed != nil } }
        for (role, name, nif) in [("landlord", \Parsed.landlordName, \Parsed.landlordNIF), ("tenant", \Parsed.tenantName, \Parsed.tenantNIF)] {
            var byContract: [String: Set<String>] = [:]
            var invalid: [String: [String]] = [:]
            for item in parsedItems {
                let parsed = item.parsed!
                let value = parsed[keyPath: nif] ?? "(none)"
                byContract[parsed.contractNumber, default: []].insert(value)
                if value != "(none)" && !isValidNIF(value) { invalid[value, default: []].append(item.fileName) }
                else if value == "(none)" { invalid["(none)", default: []].append(item.fileName) }
                let party = "\(role) \(parsed[keyPath: name] ?? "(unreadable)") NIF \(value) (contract \(parsed.contractNumber))"
                if !parties.contains(party) { parties.append(party) }
            }
            for (contract, values) in byContract.sorted(by: { $0.key < $1.key }) where values.count > 1 {
                nifIssues.append("contract \(contract): \(values.count) different \(role) NIFs (\(values.sorted().joined(separator: ", ")))")
            }
            for (value, files) in invalid.sorted(by: { $0.key < $1.key }) {
                nifIssues.append(value == "(none)" ? "\(role) NIF unreadable in \(files.count) PDF(s): \(files.joined(separator: ", "))"
                                 : "\(role) NIF \(value) fails the check digit (\(files.count) PDF(s))")
            }
        }
        return Plan(items: items, receiptsWithoutPDF: receiptsWithoutPDF, cancelledReceipts: cancelled, nifIssues: nifIssues, parties: parties)
    }

    // MARK: Applying

    public struct Applied: Equatable, Sendable {
        /// Documents added to the library.
        public var added = 0
        /// PDFs already in the library (reused).
        public var reused = 0
        /// Links made.
        public var linked = 0
        /// Reused documents whose kind was set to rent receipt.
        public var kindsSet = 0
        /// Stored copies placed in the library (remove them if the transaction rolls back).
        public var placedFiles: [URL] = []
    }

    /// The canonical library name of a receipt PDF:
    /// `YYYYMMDD - Rent - Receipt - <contract>/<n> - <period> - €<amount>` (issue date).
    public static func canonicalName(_ parsed: Parsed) -> String? {
        guard let date = parsed.issueDate ?? parsed.receiptDate ?? parsed.periodStart else { return nil }
        let period = parsed.periodStart.flatMap { start in parsed.periodEnd.map { (start, $0) } }
        return EvidenceNaming.canonicalName(date: date, area: "Rent", type: "Receipt",
                                            detail: "\(parsed.contractNumber)/\(parsed.receiptNumber)", period: period,
                                            amountMinorUnits: parsed.amountMinorUnits, currency: parsed.amountMinorUnits == nil ? nil : .eur)
    }

    /// Adds (or reuses) and links the plan's `.link` items, inside the caller's transaction:
    /// each PDF as a rent receipt document (kind set on a reused one of another kind), linked
    /// to its receipt with the role "Receipt". The plan must come from the same `inputs`.
    public static func apply(db: Database, plan: Plan, inputs: [Input], library: EvidenceLibrary, now: Date = Date()) throws -> Applied {
        var applied = Applied()
        let byHash = Dictionary(inputs.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            for item in plan.items where item.outcome == .link {
                guard let input = byHash[item.sha256], let parsed = item.parsed, let receipt = item.receipt else { continue }
                let metadata = EvidenceMetadata(kind: .rentReceipt, docDate: parsed.issueDate, periodStart: parsed.periodStart,
                                                periodEnd: parsed.periodEnd, amountMinorUnits: parsed.amountMinorUnits, currency: .eur,
                                                canonicalName: canonicalName(parsed), textStatus: input.textStatus,
                                                extractedText: input.text)
                let staged = try library.add(db: db, input.fileURL, metadata: metadata, analysis: input.analysis, now: now)
                if let placed = staged.placedFile { applied.placedFiles.append(placed) }
                let document = staged.result.document
                guard let documentId = document.id else { continue }
                if staged.result.isNew {
                    applied.added += 1
                } else {
                    applied.reused += 1
                    if document.kind != .rentReceipt {
                        try db.execute(sql: "UPDATE document SET kind = ? WHERE id = ?", arguments: [DocumentKind.rentReceipt.rawValue, documentId])
                        applied.kindsSet += 1
                    }
                }
                let before = try DocumentLink.filter(EvidenceEntity.rentReceipt(receipt.id!)).filter(Column("documentId") == documentId).fetchCount(db)
                try EvidenceLinks.link(db: db, documentId: documentId, to: .rentReceipt(receipt.id!), role: "Receipt")
                if before == 0 { applied.linked += 1 }
            }
        } catch {
            for url in applied.placedFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return applied
    }

    // MARK: Report

    public static func report(_ plan: Plan, applied: Applied?) -> String {
        var out = ""
        let toLink = plan.items.filter { $0.outcome == .link }
        out += "PDFs read: \(plan.items.count)\n"
        out += "  matched and agreeing, to link: \(toLink.count)"
            + (toLink.isEmpty ? "" : " (\(toLink.filter { $0.existingDocumentId != nil }.count) already in the library, reused)") + "\n"
        out += "  already linked: \(plan.count(.alreadyLinked))\n"
        out += "  mismatches (not linked): \(plan.count(.mismatch))\n"
        out += "  no receipt row: \(plan.count(.noReceipt) + plan.count(.ambiguousContract))\n"
        out += "  unreadable: \(plan.count(.unreadable))\n"
        out += "  duplicates: \(plan.items.filter { if case .duplicate = $0.outcome { return true } else { return false } }.count)\n"
        let ocr = plan.items.filter(\.usedOCR)
        if !ocr.isEmpty { out += "  read by OCR: \(ocr.map(\.fileName).joined(separator: ", "))\n" }
        if let applied {
            out += "Applied: \(applied.added) added to the library, \(applied.reused) reused, \(applied.linked) linked"
                + (applied.kindsSet > 0 ? ", \(applied.kindsSet) set to rent receipt" : "") + "\n"
        }

        out += "\n== Mismatches (PDF vs stored) ==\n"
        let mismatched = plan.items.filter { $0.outcome == .mismatch }
        if mismatched.isEmpty { out += "  none\n" }
        for item in mismatched {
            out += "  \(item.fileName) → receipt \(item.parsed!.contractNumber)/\(item.parsed!.receiptNumber)"
                + (item.receipt?.status == .cancelled ? " (cancelled)" : "") + "\n"
            for mismatch in item.mismatches {
                out += "    \(mismatch.field): PDF \(mismatch.pdf) vs stored \(mismatch.stored)\n"
            }
        }

        out += "\n== PDFs with no receipt row ==\n"
        let orphans = plan.items.filter { [.noReceipt, .ambiguousContract, .unreadable].contains($0.outcome) }
        if orphans.isEmpty { out += "  none\n" }
        for item in orphans {
            let what = item.parsed.map { "receipt \($0.contractNumber)/\($0.receiptNumber)" } ?? "not readable as a rent receipt (\(item.textStatus.rawValue))"
            let why = item.outcome == .ambiguousContract ? " — contract on several tenancies" : ""
            out += "  \(item.fileName): \(what)\(why)\n"
        }
        for item in plan.items {
            if case .duplicate(let first) = item.outcome { out += "  \(item.fileName): duplicate of \(first)\n" }
        }

        out += "\n== Receipts with no PDF in the folder ==\n"
        if plan.receiptsWithoutPDF.isEmpty { out += "  none\n" }
        for (receipt, hasDocument) in plan.receiptsWithoutPDF {
            out += "  receipt \(receipt.receiptNumber) \(dayText(receipt.periodStart))…\(dayText(receipt.periodEnd)) \(moneyText(receipt.amountMinorUnits))"
                + " \(receipt.status.rawValue)\(hasDocument ? ", already has a linked document" : "")\n"
        }

        out += "\n== Cancelled receipts ==\n"
        if plan.cancelledReceipts.isEmpty { out += "  none\n" }
        for receipt in plan.cancelledReceipts {
            let item = plan.items.first { $0.receipt?.id == receipt.id }
            out += "  receipt \(receipt.receiptNumber) \(dayText(receipt.periodStart))…\(dayText(receipt.periodEnd)) \(moneyText(receipt.amountMinorUnits))"
                + (item.map { " — PDF \($0.fileName) (\(label($0.outcome)))" } ?? " — no PDF") + "\n"
        }

        out += "\n== Parties and NIFs ==\n"
        for party in plan.parties { out += "  \(party)\n" }
        out += plan.nifIssues.isEmpty ? "  NIFs valid and consistent\n" : plan.nifIssues.map { "  ! \($0)\n" }.joined()

        let withOthers = plan.items.filter { !$0.otherLinkedDocumentIds.isEmpty }
        if !withOthers.isEmpty {
            out += "\n== Receipts that already had another document linked ==\n"
            for item in withOthers {
                out += "  \(item.fileName): receipt \(item.receipt!.receiptNumber) has document(s) \(item.otherLinkedDocumentIds.map(String.init).joined(separator: ", "))\n"
            }
        }

        out += "\n== Every PDF ==\n"
        for item in plan.items {
            let receipt = item.parsed.map { "\($0.contractNumber)/\($0.receiptNumber)" } ?? "-"
            let period = item.parsed.map { "\(dayText($0.periodStart))…\(dayText($0.periodEnd))" } ?? ""
            let amount = item.parsed.map { moneyText($0.amountMinorUnits) } ?? ""
            out += "  \(item.fileName)  \(receipt)  \(period)  \(amount)  issued \(dayText(item.parsed?.issueDate))"
                + "  received \(dayText(item.parsed?.receiptDate))  → \(label(item.outcome))\n"
        }
        return out
    }

    static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .link: return "link"
        case .alreadyLinked: return "already linked"
        case .mismatch: return "MISMATCH"
        case .noReceipt: return "no receipt row"
        case .ambiguousContract: return "ambiguous contract"
        case .unreadable: return "unreadable"
        case .duplicate(let first): return "duplicate of \(first)"
        }
    }
}
