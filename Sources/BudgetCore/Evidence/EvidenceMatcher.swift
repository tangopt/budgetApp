import Foundation

/// Proposes the transactions a document is evidence for (spec §2–§3), ranked: the exact
/// amount (sign-free, in the transaction's account currency) is the strongest signal, then a
/// payment reference the description repeats, the date within the kind's window (a mortgage
/// notice's value date ±3 days, a mortgage receipt its own date ±1, an IMI payment the same day, an insurance receipt ±10 days, a
/// rent receipt's rent-period month for the credit …), and the category, account and
/// description the kind usually has (the Lisbon categories, the BBVA account). Equal scores are
/// left equal — `confidentMatch` only picks a single clear winner.
public enum EvidenceMatcher {
    public struct Suggestion: Equatable, Sendable {
        public var transactionId: Int64
        public var score: Int
        /// Why, for the review screen ("Amount €1,234.56", "2 days after").
        public var reasons: [String]
        /// The exact amount matched (in the transaction's currency).
        public var amountMatched: Bool
        /// The date is inside the kind's window (not only within the exact amount's grace).
        public var dateInWindow: Bool
        /// A payment reference in the document appears in this transaction's description and in
        /// no other transaction's.
        public var referenceMatched: Bool

        public init(transactionId: Int64, score: Int, reasons: [String], amountMatched: Bool = false, dateInWindow: Bool = false,
                    referenceMatched: Bool = false) {
            self.transactionId = transactionId
            self.score = score
            self.reasons = reasons
            self.amountMatched = amountMatched
            self.dateInWindow = dateInWindow
            self.referenceMatched = referenceMatched
        }
    }

    enum Direction {
        case debit, credit, either
    }

    /// What a kind's transaction usually looks like.
    struct Expectation {
        var direction: Direction = .either
        /// Days from the anchor date (negative: before) the transaction is expected in.
        var window: ClosedRange<Int> = -7...7
        /// The anchor: the document's date, or its period's start or end.
        var anchor: Anchor = .docDate
        /// Lowercased fragments of the category's name.
        var categoryHints: [String] = []
        /// Uppercased, diacritic-free fragments of the description.
        var descriptionHints: [String] = []
        /// The account's name or alias mentions this (uppercased), e.g. BBVA for Lisbon costs.
        var accountHint: String?

        enum Anchor {
            case docDate, periodStart, periodEnd
        }
    }

    static let bbva = "BBVA"

    static func expectation(for kind: DocumentKind) -> Expectation {
        switch kind {
        case .mortgageNotice:
            return Expectation(direction: .debit, window: -3...3, anchor: .periodEnd, categoryHints: ["mortgage", "hipoteca"],
                               descriptionHints: ["COBR. REC", "COBR REC", "PRESTACAO", "EMPRESTIMO"], accountHint: bbva)
        case .mortgageReceipt:
            // Dated on the debit's own day (its value date).
            return Expectation(direction: .debit, window: -1...1, anchor: .docDate, categoryHints: ["mortgage", "hipoteca"],
                               descriptionHints: ["COBR. REC", "COBR REC", "PRESTACAO", "EMPRESTIMO"], accountHint: bbva)
        case .insuranceReceipt:
            return Expectation(direction: .debit, window: -10...10, categoryHints: ["insurance", "seguro"],
                               descriptionHints: ["BBVASEG", "SEGUR", "MAPFRE", "TRANQUILIDADE", "GENERALI"], accountHint: bbva)
        case .imiPayment:
            return Expectation(direction: .debit, window: -1...1, categoryHints: ["imi"], descriptionHints: ["PAGEST", "ESTADO", "IMI"], accountHint: bbva)
        case .imiNotice:
            return Expectation(direction: .debit, window: 0...150, categoryHints: ["imi"], descriptionHints: ["PAGEST", "ESTADO", "IMI"], accountHint: bbva)
        case .ptIRSPaymentProof:
            return Expectation(direction: .debit, window: -1...1, categoryHints: ["pt tax", "irs"], descriptionHints: ["PAGEST", "ESTADO", "IRS"], accountHint: bbva)
        case .ptIRSPaymentNote:
            return Expectation(direction: .debit, window: 0...60, categoryHints: ["pt tax", "irs"], descriptionHints: ["PAGEST", "ESTADO", "IRS"], accountHint: bbva)
        case .ptIRSAssessment:
            // An assessment can be a bill or a refund.
            return Expectation(direction: .either, window: 0...60, categoryHints: ["pt tax", "irs"],
                               descriptionHints: ["PAGEST", "ESTADO", "IRS", "AUTORIDADE TRIBUTARIA", "REEMBOLSO"], accountHint: bbva)
        case .courtFee:
            return Expectation(direction: .debit, window: -1...3, categoryHints: ["legal"], descriptionHints: ["PAGEST", "ESTADO", "IGFEJ"], accountHint: bbva)
        case .lettingAgentFee:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["letting", "agent"], descriptionHints: ["MEDIAC", "IMOBILIARIA"])
        case .condominioReceipt:
            return Expectation(direction: .debit, window: -10...10, categoryHints: ["condom"], descriptionHints: ["CONDOM"], accountHint: bbva)
        case .rentReceipt:
            // The rent for a month arrives in that month, or in the last days of the one before.
            return Expectation(direction: .credit, window: -10...30, anchor: .periodStart, categoryHints: ["rent"], descriptionHints: ["RENDA", "RENT"], accountHint: bbva)
        case .accountantInvoice:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["accountant", "contabil"],
                               descriptionHints: ["CONTABIL", "ACCOUNTAN", "TAX ADVISER"])
        case .legalInvoice:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["legal"], descriptionHints: ["ADVOGAD", "SOLICITADOR", "LEGAL"])
        case .utilityInvoice:
            return Expectation(direction: .debit, window: -5...45, categoryHints: ["utilit"],
                               descriptionHints: ["EDP", "GDL", "LISBOAGAS", "SIMAR", "SMAS", "GALP", "AGUAS", "EPAL"], accountHint: bbva)
        case .bankTransferProof:
            return Expectation(direction: .either, window: -1...3)
        case .bankDebitAdvice:
            return Expectation(direction: .debit, window: -2...2, accountHint: bbva)
        case .hmrcPaymentProof:
            return Expectation(direction: .debit, window: -1...5, categoryHints: ["uk tax", "hmrc"], descriptionHints: ["HMRC"])
        default:
            return Expectation()
        }
    }

    // Points.
    static let amountPoints = 100
    static let referencePoints = 60
    static let datePoints = 40
    static let categoryPoints = 20
    static let descriptionPoints = 15
    static let accountPoints = 10
    /// Below this a candidate isn't suggested (a date in the window alone is not enough).
    static let minimumScore = 60
    /// An exact amount still counts this far outside the date window.
    static let amountGraceDays = 30

    /// Transactions prepared for matching many documents: sorted by date, grouped by amount,
    /// descriptions normalized once.
    public struct Index: Sendable {
        struct Entry: Sendable {
            let transaction: Transaction
            let id: Int64
            let description: String
            let digits: String
        }

        let byDate: [Entry]
        let byAmount: [Int: [Entry]]
        let accounts: [Int64: Account]
        let categories: [Int64: Category]

        public init(transactions: [Transaction], accounts: [Account], categories: [Category]) {
            let entries = transactions.compactMap { transaction -> Entry? in
                guard let id = transaction.id else { return nil }
                let description = EvidenceText.normalized(transaction.rawDescription)
                return Entry(transaction: transaction, id: id, description: description, digits: description.filter(\.isNumber))
            }
            byDate = entries.sorted { ($0.transaction.date, $0.id) < ($1.transaction.date, $1.id) }
            byAmount = Dictionary(grouping: entries) { abs($0.transaction.amountMinorUnits) }
            self.accounts = Dictionary(accounts.compactMap { account in account.id.map { ($0, account) } }, uniquingKeysWith: { first, _ in first })
            self.categories = Dictionary(categories.compactMap { category in category.id.map { ($0, category) } }, uniquingKeysWith: { first, _ in first })
        }

        /// Entries dated within `start...end` (binary search).
        func entries(from start: Date, to end: Date) -> ArraySlice<Entry> {
            func firstIndex(notBefore date: Date) -> Int {
                var low = 0, high = byDate.count
                while low < high {
                    let mid = (low + high) / 2
                    if byDate[mid].transaction.date < date { low = mid + 1 } else { high = mid }
                }
                return low
            }
            let lower = firstIndex(notBefore: start)
            let upper = max(lower, firstIndex(notBefore: end.addingTimeInterval(1)))
            return byDate[lower..<upper]
        }
    }

    /// Candidate transactions for `document`, best first; at most `limit`.
    public static func suggestions(document: EvidenceDocument, transactions: [Transaction], accounts: [Account],
                                   categories: [Category], limit: Int = 10) -> [Suggestion] {
        suggestions(document: document, index: Index(transactions: transactions, accounts: accounts, categories: categories), limit: limit)
    }

    /// Candidate transactions for `document` from a prepared `index` (many documents, one index).
    public static func suggestions(document: EvidenceDocument, index: Index, limit: Int = 10) -> [Suggestion] {
        let expectation = expectation(for: document.kind)
        let anchor: Date? = switch expectation.anchor {
        case .docDate: document.docDate
        case .periodStart: document.periodStart ?? document.docDate
        case .periodEnd: document.periodEnd ?? document.docDate
        }
        let documentAmount = document.amountMinorUnits.map(abs)

        // Only transactions that could score: in the window (plus the exact amount's grace)
        // around the anchor, or — undated — of the document's amount.
        let pool: [Index.Entry]
        if let anchor {
            let day: TimeInterval = 86_400
            pool = Array(index.entries(from: anchor.addingTimeInterval(Double(expectation.window.lowerBound - amountGraceDays) * day),
                                       to: anchor.addingTimeInterval(Double(expectation.window.upperBound + amountGraceDays) * day)))
        } else if let documentAmount {
            pool = index.byAmount[documentAmount] ?? []
        } else {
            return []
        }
        let candidates = pool.filter { entry in
            switch expectation.direction {
            case .debit: return entry.transaction.amountMinorUnits <= 0
            case .credit: return entry.transaction.amountMinorUnits >= 0
            case .either: return true
            }
        }

        // A reference counts only when exactly one transaction of all repeats it (a loan number
        // on every instalment says nothing about which one).
        var referenceOwner: [Int64: String] = [:]
        for reference in paymentReferences(in: document.extractedText ?? "") {
            let owners = index.byDate.lazy.filter { $0.digits.contains(reference) }.prefix(2)
            if owners.count == 1, let owner = owners.first, referenceOwner[owner.id] == nil { referenceOwner[owner.id] = reference }
        }

        var ranked: [(suggestion: Suggestion, distance: Int)] = []
        for entry in candidates {
            let transaction = entry.transaction
            let account = index.accounts[transaction.accountId]
            var score = 0
            var reasons: [String] = []

            var amountMatches = false
            if let documentAmount, let currency = document.currency, let account,
               account.currency == currency, abs(transaction.amountMinorUnits) == documentAmount {
                amountMatches = true
                score += amountPoints
                reasons.append("Amount \(Money.format(documentAmount, currency: currency))")
            }

            var distance = Int.max
            var inWindow = false
            if let anchor {
                let offset = days(from: anchor, to: transaction.date)
                distance = abs(offset)
                if expectation.window.contains(offset) {
                    inWindow = true
                    // Full points on the anchor day (or the window's nearest day), half at its far edge.
                    let nearest = min(max(0, expectation.window.lowerBound), expectation.window.upperBound)
                    let span = max(1, max(abs(expectation.window.lowerBound - nearest), abs(expectation.window.upperBound - nearest)))
                    score += datePoints - (datePoints / 2) * abs(offset - nearest) / span
                    reasons.append(offset == 0 ? "Same day" : "\(abs(offset)) day\(abs(offset) == 1 ? "" : "s") \(offset < 0 ? "before" : "after")")
                } else {
                    let outside = offset < expectation.window.lowerBound ? expectation.window.lowerBound - offset : offset - expectation.window.upperBound
                    guard amountMatches, outside <= amountGraceDays else { continue }
                }
            } else if !amountMatches {
                continue
            }

            let reference = referenceOwner[entry.id]
            if let reference {
                score += referencePoints
                reasons.append("Reference \(reference)")
            }
            if let hint = expectation.descriptionHints.first(where: { entry.description.contains($0) }) {
                score += descriptionPoints
                reasons.append("Description mentions \(hint)")
            }
            if let categoryId = transaction.categoryId, let category = index.categories[categoryId] {
                let name = EvidenceText.fold(category.name).lowercased()
                if expectation.categoryHints.contains(where: { name.contains($0) }) {
                    score += categoryPoints
                    reasons.append("Category \(category.name)")
                }
            }
            if let hint = expectation.accountHint, let account,
               [account.name, account.alias ?? ""].contains(where: { $0.uppercased().contains(hint) }) {
                score += accountPoints
                reasons.append("\(account.alias ?? account.name) account")
            }

            guard score >= minimumScore else { continue }
            ranked.append((Suggestion(transactionId: entry.id, score: score, reasons: reasons, amountMatched: amountMatches,
                                      dateInWindow: inWindow, referenceMatched: reference != nil), distance))
        }
        ranked.sort { lhs, rhs in
            if lhs.suggestion.score != rhs.suggestion.score { return lhs.suggestion.score > rhs.suggestion.score }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.suggestion.transactionId < rhs.suggestion.transactionId
        }
        return ranked.prefix(limit).map(\.suggestion)
    }

    /// The single clear winner of `suggestions` (best first), safe to link without asking: the
    /// exact amount, and the date in the kind's window or a reference only it repeats; at least
    /// `minimumScore` and strictly ahead of the next. Nil when two tie (the user picks), or when
    /// only a neighbouring period's equal amount is there (the expected debit is missing).
    public static func confidentMatch(_ suggestions: [Suggestion], minimumScore: Int = 140) -> Suggestion? {
        guard let best = suggestions.first, best.score >= minimumScore, best.amountMatched,
              best.dateInWindow || best.referenceMatched else { return nil }
        if suggestions.count > 1, suggestions[1].score >= best.score { return nil }
        return best
    }

    /// Payment references in a document (9+ digits, spaces between groups removed:
    /// `104 700 000 000 001` → `104700000000001`), which bank descriptions repeat.
    static func paymentReferences(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let regex = referencePattern
        let source = text as NSString
        var seen = Set<String>()
        var references: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let digits = source.substring(with: match.range).filter(\.isNumber)
            guard (9...25).contains(digits.count), seen.insert(digits).inserted else { continue }
            references.append(digits)
        }
        return references
    }

    private static let referencePattern = try! NSRegularExpression(pattern: #"(?<![\d.,])\d{3,}(?: \d{3})+(?![\d.,])|(?<![\d.,])\d{9,}(?![\d.,])"#)

    static func days(from start: Date, to end: Date) -> Int {
        let calendar = EvidenceText.utcCalendar
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}
