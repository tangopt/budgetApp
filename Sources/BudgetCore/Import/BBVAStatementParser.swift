import Foundation

/// Reads a BBVA Portugal monthly "extrato global" (consolidated statement) from its text, as
/// `PDFGlyphTextExtractor` reads it: the period, the current account's opening and closing
/// balances and movements, the savings product (fund) with its units, price and value, the
/// consolidated summary (DEPÓSITOS À ORDEM, PRODUTOS DE POUPANÇA, CARTÕES DE CRÉDITO,
/// EMPRÉSTIMOS) and the mortgage instalments the statement settled (COBRANÇAS EFECTUADAS: the
/// receipt, its value date, capital, interest, fees, taxes and the capital owed after it).
/// Pure; amounts in minor units (cents).
public enum BBVAStatementParser {
    public struct Movement: Equatable, Sendable {
        /// The booking date (UTC midnight).
        public let date: Date
        public let valueDate: Date
        /// Whitespace collapsed, as the 2023+ history import stored it.
        public let description: String
        public let amountMinorUnits: Int
        /// The balance the statement prints after the movement.
        public let balanceAfterMinorUnits: Int?
    }

    /// The savings product (the retirement fund): its units and value at the start and end of
    /// the period, and its movements (subscriptions).
    public struct Fund: Equatable, Sendable {
        public let account: String
        public let openingUnits: Decimal
        public let openingPrice: Decimal
        public let openingMinorUnits: Int
        public let closingUnits: Decimal
        public let closingPrice: Decimal
        public let closingMinorUnits: Int
        public let movements: [FundMovement]
    }

    public struct FundMovement: Equatable, Sendable {
        public let date: Date
        public let valueDate: Date
        public let description: String
        public let units: Decimal
        public let price: Decimal
        public let amountMinorUnits: Int
    }

    /// A mortgage instalment the statement settled (COBRANÇAS EFECTUADAS).
    public struct LoanReceipt: Equatable, Sendable {
        public let number: Int
        public let of: Int?
        public let totalMinorUnits: Int
        /// "Data Valor": the instalment's due day.
        public let valueDate: Date
        /// "Data Oper.": the day it was charged (the current account's booking date).
        public let operationDate: Date
        public let capitalMinorUnits: Int
        public let interestMinorUnits: Int
        public let feesMinorUnits: Int
        public let lateInterestMinorUnits: Int
        public let taxesMinorUnits: Int
        /// The capital owed after it.
        public let outstandingAfterMinorUnits: Int
        /// The TAN (annual %) in force.
        public let tan: Double?
    }

    public struct Statement: Equatable, Sendable {
        public let periodStart: Date
        public let periodEnd: Date
        public let currentAccount: String?
        public let openingMinorUnits: Int
        public let closingMinorUnits: Int
        public let movements: [Movement]
        public let fund: Fund?
        /// DEPÓSITOS À ORDEM, PRODUTOS DE POUPANÇA, CARTÕES DE CRÉDITO, EMPRÉSTIMOS … (the summary).
        public let summary: [String: Int]
        public let loanReceipts: [LoanReceipt]
        /// Lines inside the current account's movements that read as none (page furniture excluded).
        public let unreadLines: [String]

        public var year: Int { MonthRange.calendar.component(.year, from: periodStart) }
        public var month: Int { MonthRange.calendar.component(.month, from: periodStart) }
        public var label: String { String(format: "%04d-%02d", year, month) }
        public var loanOutstandingMinorUnits: Int? { summary["EMPRÉSTIMOS"] }
        public var savingsMinorUnits: Int? { summary["PRODUTOS DE POUPANÇA"] }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case noPeriod
        case noCurrentAccount
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noPeriod: return "No “PERÍODO DE … A …” line."
            case .noCurrentAccount: return "No current account (CONTA BBVA) with an opening and closing balance."
            case .unreadable(let line): return "Unreadable line: \(line)"
            }
        }
    }

    // MARK: Numbers and dates

    /// "-1.234,56" → -123456 (exactly two decimals).
    public static func minorUnits(_ text: String) -> Int? {
        guard let value = decimal(text) else { return nil }
        let cents = value * 100
        var rounded = Decimal()
        var copy = cents
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard rounded == cents else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// Portuguese number: "." thousands, "," decimals ("1.284,135" → 1284.135).
    public static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.range(of: #"^-?\d{1,3}(\.\d{3})*(,\d+)?$|^-?\d+(,\d+)?$"#, options: .regularExpression) != nil else { return nil }
        let plain = trimmed.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        let calendar = MonthRange.calendar
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = calendar
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// "2022-10-31" or "2022/10/31".
    static func isoDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return date(parts[0], parts[1], parts[2])
    }

    /// A "MM/DD" day near `anchor`: the year (anchor's, the one before or after) that puts it closest.
    static func monthDay(_ month: Int, _ day: Int, near anchor: Date) -> Date? {
        let year = MonthRange.calendar.component(.year, from: anchor)
        return [year - 1, year, year + 1].compactMap { date($0, month, day) }
            .min { abs($0.timeIntervalSince(anchor)) < abs($1.timeIntervalSince(anchor)) }
    }

    // MARK: Parsing

    private static let amountPattern = #"-?\d{1,3}(?:\.\d{3})*,\d{2}"#
    private static let numberPattern = #"-?\d{1,3}(?:\.\d{3})*,\d+"#

    private static func match(_ line: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let result = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Page furniture that can fall inside a list of movements.
    static func isFurniture(_ line: String) -> Bool {
        let patterns = [#"^Pág\. \d+/\d+"#, #"^Cont\.$"#, #"^Banco Bilbao"#, #"^IBAN:"#, #"^Conta Nº"#, #"^Extrato"#, #"^=+"#]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    public static func parse(_ text: String) throws -> Statement {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let periodLine = lines.lazy.compactMap({ match($0, #"PERÍODO DE (\d{4}/\d{2}/\d{2}) A (\d{4}/\d{2}/\d{2})"#) }).first,
              let start = isoDate(periodLine[1]), let end = isoDate(periodLine[2]) else { throw ParseError.noPeriod }

        var summary: [String: Int] = [:]
        let summaryKeys = ["DEPÓSITOS À ORDEM", "APLICAÇÕES A PRAZO", "FUNDOS DE INVESTIMENTO", "PRODUTOS DE POUPANÇA", "CARTEIRA DE TÍTULOS",
                           "TOTAL ACTIVO", "FACILIDADE DE DESCOBERTO", "CARTÕES DE CRÉDITO", "LEASING", "EMPRÉSTIMOS", "OUTRAS RESPONSABILIDADES", "TOTAL PASSIVO"]
        for line in lines {
            for key in summaryKeys where summary[key] == nil {
                if let m = match(line, "^" + NSRegularExpression.escapedPattern(for: key) + #" ("# + amountPattern + #")$"#), let value = minorUnits(m[1]) {
                    summary[key] = value
                }
            }
        }

        // The current account: its opening, movements and closing.
        enum State { case before, header, movements, done }
        var state = State.before
        var account: String?
        var opening: Int?, closing: Int?
        var movements: [Movement] = []
        var unread: [String] = []
        var fund: Fund?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            switch state {
            case .before:
                if let m = match(line, #"^Conta Nº:\s*(\S+)\s+EUR\s+CONTA BBVA$"#) {
                    account = m[1]
                    state = .header
                }
            case .header:
                if let m = match(line, #"^Saldo inicial ("# + amountPattern + #")$"#) {
                    opening = minorUnits(m[1])
                    state = .movements
                }
            case .movements:
                if let m = match(line, #"^Saldo (?:contabil[ií]stico )?final ("# + amountPattern + #")$"#) {
                    closing = minorUnits(m[1])
                    state = .done
                    continue
                }
                if let m = match(line, #"^(\d{2})/(\d{2}) (\d{2})/(\d{2}) (.+?) ("# + amountPattern + #")(?: ("# + amountPattern + #"))?$"#),
                   let bm = Int(m[1]), let bd = Int(m[2]), let vm = Int(m[3]), let vd = Int(m[4]),
                   let booked = monthDay(bm, bd, near: end), let valued = monthDay(vm, vd, near: booked),
                   let value = minorUnits(m[6]) {
                    movements.append(Movement(date: booked, valueDate: valued, description: collapse(m[5]), amountMinorUnits: value,
                                              balanceAfterMinorUnits: m[7].isEmpty ? nil : minorUnits(m[7])))
                } else if !isFurniture(line) {
                    unread.append(line)
                }
            case .done:
                // The savings product follows: "Conta Nº: … EUR <name>" with units, price and value.
                if fund == nil, let m = match(line, #"^Conta Nº:\s*(\S+)\s+EUR\s+(.+)$"#), !m[2].contains("CONTA BBVA"),
                   index < lines.count, let o = match(lines[index], #"^Saldo inicial ("# + numberPattern + #") ("# + numberPattern + #") ("# + amountPattern + #")$"#) {
                    var fundMovements: [FundMovement] = []
                    var cursor = index + 1
                    var closingLine: [String]?
                    while cursor < lines.count {
                        let next = lines[cursor]
                        cursor += 1
                        if let c = match(next, #"^Saldo final ("# + numberPattern + #") ("# + numberPattern + #") ("# + amountPattern + #")$"#) {
                            closingLine = c
                            break
                        }
                        if let f = match(next, #"^(\d{2})/(\d{2}) (\d{2})/(\d{2}) (.+?) ("# + numberPattern + #") ("# + numberPattern + #") ("# + amountPattern + #")$"#),
                           let bm = Int(f[1]), let bd = Int(f[2]), let vm = Int(f[3]), let vd = Int(f[4]),
                           let booked = monthDay(bm, bd, near: end), let valued = monthDay(vm, vd, near: booked),
                           let units = decimal(f[6]), let price = decimal(f[7]), let value = minorUnits(f[8]) {
                            fundMovements.append(FundMovement(date: booked, valueDate: valued, description: collapse(f[5]), units: units, price: price, amountMinorUnits: value))
                        } else if !isFurniture(next) {
                            break
                        }
                    }
                    guard let c = closingLine, let ou = decimal(o[1]), let op = decimal(o[2]), let ov = minorUnits(o[3]),
                          let cu = decimal(c[1]), let cp = decimal(c[2]), let cv = minorUnits(c[3]) else {
                        throw ParseError.unreadable("the savings account " + m[1] + " opens but has no readable closing (Saldo final)")
                    }
                    fund = Fund(account: m[1], openingUnits: ou, openingPrice: op, openingMinorUnits: ov,
                                closingUnits: cu, closingPrice: cp, closingMinorUnits: cv, movements: fundMovements)
                    index = cursor
                }
            }
        }
        guard let opening, let closing else { throw ParseError.noCurrentAccount }

        // Mortgage instalments settled (COBRANÇAS EFECTUADAS).
        var receipts: [LoanReceipt] = []
        for (offset, line) in lines.enumerated() {
            guard let r = match(collapse(line), #"^Nº\. Recibo: (\d+)(?:/(\d+))?.*Total recibo: ("# + amountPattern + #")$"#),
                  let number = Int(r[1]), let total = minorUnits(r[3]) else { continue }
            var valueDate: Date?
            var tan: Double?
            var found = false
            for next in lines[(offset + 1)..<min(lines.count, offset + 12)] {
                if valueDate == nil, let v = match(next, #"^Data Valor: (\d{4}-\d{2}-\d{2})"#) { valueDate = isoDate(v[1]) }
                if tan == nil, let t = match(next, #"^T\.A\.N\. : ("# + numberPattern + #")%"#), let rate = decimal(t[1]) {
                    tan = NSDecimalNumber(decimal: rate).doubleValue
                }
                let fields = #"^(\d{4}-\d{2}-\d{2}) ("# + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ") (" + amountPattern + ")$"
                if let d = match(collapse(next), fields), let operation = isoDate(d[1]), let valueDate,
                   let capital = minorUnits(d[2]), let interest = minorUnits(d[3]), let fees = minorUnits(d[4]),
                   let late = minorUnits(d[5]), let taxes = minorUnits(d[6]), let lineTotal = minorUnits(d[7]), let owed = minorUnits(d[9]) {
                    guard lineTotal == total else { throw ParseError.unreadable("receipt " + String(number) + ": total " + String(lineTotal) + " ≠ " + String(total)) }
                    receipts.append(LoanReceipt(number: number, of: Int(r[2]), totalMinorUnits: total, valueDate: valueDate, operationDate: operation,
                                                capitalMinorUnits: capital, interestMinorUnits: interest, feesMinorUnits: fees, lateInterestMinorUnits: late,
                                                taxesMinorUnits: taxes, outstandingAfterMinorUnits: owed, tan: tan))
                    found = true
                    break
                }
            }
            guard found else { throw ParseError.unreadable("receipt " + String(number) + ": no value date or no detail line (capital, interest … capital owed)") }
        }
        // A loan section needs the summary's amount owed.
        let hasLoan = !receipts.isEmpty || lines.contains { $0.hasPrefix("Conta Nº") && $0.uppercased().contains("HABITA") }
        if hasLoan && summary["EMPRÉSTIMOS"] == nil { throw ParseError.unreadable("a loan account but no EMPRÉSTIMOS in the summary") }
        return Statement(periodStart: start, periodEnd: end, currentAccount: account, openingMinorUnits: opening, closingMinorUnits: closing,
                         movements: movements, fund: fund, summary: summary, loanReceipts: receipts, unreadLines: unread)
    }
}
