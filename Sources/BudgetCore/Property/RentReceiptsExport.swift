import Foundation

/// The Portal das Finanças rent-receipts export ("ListaRecibos" .xlsx, spec 2026-10-16 §6.1):
/// one row per receipt, all tenancies of the landlord. Columns are found by their header
/// (accents, case and punctuation ignored), so a reordered export still reads.
public enum RentReceiptsExport {
    public enum ExportError: Error, Equatable {
        /// No header row with the required columns (contract, receipt, period, amount, status).
        case missingColumns([String])
        /// A value that can't be read, with its 1-based spreadsheet row and the column's header.
        case badValue(row: Int, column: String, value: String)
        case missingValue(row: Int, column: String)
        /// The same (contract, receipt number) twice in the file.
        case duplicateReceipt(row: Int, contractNumber: String, receiptNumber: String)
    }

    /// One receipt as exported. Amounts in cents (EUR).
    public struct Row: Equatable, Sendable {
        /// 1-based spreadsheet row, for messages.
        public var rowNumber: Int
        /// "Referência": the tenancy's label on the portal.
        public var reference: String?
        public var contractNumber: String
        public var receiptNumber: String
        public var landlord: String?
        public var tenant: String?
        public var periodStart: Date
        public var periodEnd: Date
        public var receiptDate: Date?
        public var amountMinorUnits: Int
        public var withholdingMinorUnits: Int
        public var amountReceivedMinorUnits: Int
        /// "Imóvel": the portal's description of the property.
        public var property: String?
        public var status: RentReceiptStatus

        public init(rowNumber: Int, reference: String?, contractNumber: String, receiptNumber: String, landlord: String? = nil,
                    tenant: String?, periodStart: Date, periodEnd: Date, receiptDate: Date?, amountMinorUnits: Int,
                    withholdingMinorUnits: Int = 0, amountReceivedMinorUnits: Int? = nil, property: String? = nil,
                    status: RentReceiptStatus = .issued) {
            self.rowNumber = rowNumber
            self.reference = reference
            self.contractNumber = contractNumber
            self.receiptNumber = receiptNumber
            self.landlord = landlord
            self.tenant = tenant
            self.periodStart = periodStart
            self.periodEnd = periodEnd
            self.receiptDate = receiptDate
            self.amountMinorUnits = amountMinorUnits
            self.withholdingMinorUnits = withholdingMinorUnits
            self.amountReceivedMinorUnits = amountReceivedMinorUnits ?? amountMinorUnits - withholdingMinorUnits
            self.property = property
            self.status = status
        }
    }

    enum Field: CaseIterable {
        case reference, contract, receipt, landlord, tenant, start, end, receiptDate, amount, withholding, received, property, status

        /// Normalised header spellings.
        var headers: [String] {
            switch self {
            case .reference: return ["referencia"]
            case .contract: return ["nodecontrato", "ndecontrato", "contrato", "numerodecontrato"]
            case .receipt: return ["noderecibo", "nderecibo", "recibo", "numeroderecibo"]
            case .landlord: return ["locador"]
            case .tenant: return ["locatario"]
            case .start: return ["datadeinicio", "inicio"]
            case .end: return ["datadefim", "fim"]
            case .receiptDate: return ["dataderec", "datadorec", "dataderecebimento", "datarecebimento"]
            case .amount: return ["valor"]
            case .withholding: return ["retencaoirs", "retencao"]
            case .received: return ["importanciarecebida"]
            case .property: return ["imovel"]
            case .status: return ["estado"]
            }
        }

        static let required: [Field] = [.contract, .receipt, .start, .end, .amount, .status]
    }

    /// Reads the export's first sheet.
    public static func parse(xlsx data: Data) throws -> [Row] {
        try parse(sheet: XLSXReader.read(data: data))
    }

    public static func parse(sheet: XLSXReader.Sheet) throws -> [Row] {
        // The header is the first row naming every required column (exports may have a title above).
        var columns: [Field: Int] = [:]
        var headerIndex: Int?
        var headerNames: [Int: String] = [:]
        for (index, row) in sheet.rows.enumerated() {
            var found: [Field: Int] = [:]
            for (column, cell) in row.enumerated() {
                guard let cell else { continue }
                let key = normalisedHeader(cell)
                if let field = Field.allCases.first(where: { $0.headers.contains(key) }), found[field] == nil {
                    found[field] = column
                    headerNames[column] = cell
                }
            }
            if Field.required.allSatisfy({ found[$0] != nil }) {
                columns = found
                headerIndex = index
                break
            }
            headerNames = [:]
        }
        guard let headerIndex else {
            throw ExportError.missingColumns(Field.required.map { $0.headers[0] })
        }

        var rows: [Row] = []
        var seen: Set<[String]> = []
        for index in (headerIndex + 1)..<sheet.rows.count {
            let cells = sheet.rows[index]
            let rowNumber = index + 1
            func text(_ field: Field) -> String? {
                guard let column = columns[field], column < cells.count, let value = cells[column] else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            func name(_ field: Field) -> String { columns[field].flatMap { headerNames[$0] } ?? field.headers[0] }
            func required(_ field: Field) throws -> String {
                guard let value = text(field) else { throw ExportError.missingValue(row: rowNumber, column: name(field)) }
                return value
            }
            func date(_ field: Field) throws -> Date? {
                guard let value = text(field) else { return nil }
                guard let parsed = parseDate(value, date1904: sheet.uses1904Dates) else { throw ExportError.badValue(row: rowNumber, column: name(field), value: value) }
                return parsed
            }
            func amount(_ field: Field) throws -> Int? {
                guard let value = text(field) else { return nil }
                guard let parsed = parseAmount(value) else { throw ExportError.badValue(row: rowNumber, column: name(field), value: value) }
                return parsed
            }
            // Blank lines (and totals rows without a receipt) are skipped.
            if Field.required.allSatisfy({ text($0) == nil }) { continue }

            let contract = numberText(try required(.contract))
            let receipt = numberText(try required(.receipt))
            let statusText = try required(.status)
            guard let status = parseStatus(statusText) else {
                throw ExportError.badValue(row: rowNumber, column: name(.status), value: statusText)
            }
            guard let start = try date(.start) else { throw ExportError.missingValue(row: rowNumber, column: name(.start)) }
            guard let end = try date(.end) else { throw ExportError.missingValue(row: rowNumber, column: name(.end)) }
            guard let value = try amount(.amount) else { throw ExportError.missingValue(row: rowNumber, column: name(.amount)) }
            let withholding = try amount(.withholding) ?? 0
            guard seen.insert([contract, receipt]).inserted else {
                throw ExportError.duplicateReceipt(row: rowNumber, contractNumber: contract, receiptNumber: receipt)
            }
            rows.append(Row(rowNumber: rowNumber, reference: text(.reference), contractNumber: contract, receiptNumber: receipt,
                            landlord: text(.landlord), tenant: text(.tenant), periodStart: start, periodEnd: end,
                            receiptDate: try date(.receiptDate), amountMinorUnits: value, withholdingMinorUnits: withholding,
                            amountReceivedMinorUnits: try amount(.received), property: text(.property), status: status))
        }
        return rows
    }

    /// Lower case, accents folded, letters and digits only ("Nº de Contrato" → "nodecontrato").
    static func normalisedHeader(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "º", with: "o").replacingOccurrences(of: "ª", with: "a")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_PT"))
            .lowercased()
        return String(folded.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    /// Numbers read as text: "1234567" stays, "50.0" (a float cell) becomes "50".
    static func numberText(_ text: String) -> String {
        if text.hasSuffix(".0"), Int(text.dropLast(2)) != nil { return String(text.dropLast(2)) }
        return text
    }

    /// "Emitido" → issued, "Anulado" → cancelled (and their feminine/English forms).
    static func parseStatus(_ text: String) -> RentReceiptStatus? {
        switch normalisedHeader(text) {
        case "emitido", "emitida", "issued": return .issued
        case "anulado", "anulada", "cancelado", "cancelada", "cancelled", "canceled": return .cancelled
        default: return nil
        }
    }

    /// ISO "2025-01-31", Portuguese "31/01/2025" or "31-01-2025", or an Excel serial number.
    static func parseDate(_ text: String, date1904: Bool = false) -> Date? {
        let calendar = MonthRange.calendar
        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (1900...2200).contains(y), (1...12).contains(m), (1...31).contains(d),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
                  calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        let datePart = text.split(separator: " ").first.map(String.init) ?? text
        let parts = datePart.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
        if parts.count == 3 {
            if datePart.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).first?.count == 4 {
                return make(parts[0], parts[1], parts[2])
            }
            return make(parts[2], parts[1], parts[0])
        }
        if let serial = Double(text), (1...200_000).contains(serial) { return XLSXReader.excelSerialDate(serial, date1904: date1904) }
        return nil
    }

    /// "1000", "123.45", "12.5" (number cells) or "1.000,00 €" (Portuguese text) → cents.
    static func parseAmount(_ text: String) -> Int? {
        var cleaned = text.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }),
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var cents = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
