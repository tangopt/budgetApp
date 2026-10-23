import GRDB
import Foundation

/// An addendum to a tenancy's contract (`DocumentKind.tenancyAddendum`: "Aditamento" or
/// "Adenda" ao contrato de arrendamento) — a new rent, a longer term. Reads its date (signed,
/// else in effect), finds the tenancy it amends (the contract's) and names it after that
/// tenancy. Filed on the tenancy beside its contract: never the contract the tenancy asks for,
/// never a transaction's evidence.
public enum TenancyAddendum {
    /// The role of its link to the tenancy (the contract's is "Contract").
    public static let linkRole = "Addendum"

    // MARK: Date

    /// Just before a signature's date: "Lisboa, ", "assinado em ", "Data: ".
    private static let signatureLead = try! NSRegularExpression(
        pattern: #"(?:\p{L}{3,}\s*,\s*(?:(?:em|aos|a)\s+)?|(?:assinad[oa]s?|feito|outorgad[oa])\s+(?:em|aos|a)\s+|\bdata(?:\s+de\s+assinatura)?\s*:?\s*)$"#,
        options: [.caseInsensitive])
    /// A place and date that are the contract's, quoted: "celebrado em Lisboa, 1 de janeiro de 2024".
    private static let quotedContract = try! NSRegularExpression(pattern: #"celebrad[oa]"#, options: [.caseInsensitive])
    /// Just before the date it takes effect from: "com efeitos a partir de ", "entra em vigor em ".
    private static let effectLead = try! NSRegularExpression(
        pattern: #"(?:efeitos?|a\s+partir\s+d[eo]|com\s+inicio\s+(?:em|a)|vigor\s+(?:em|a))[^.\n]{0,20}$"#,
        options: [.caseInsensitive])
    /// How far from the end of the text a signature is looked for (characters).
    static let signatureReach = 400

    /// The addendum's date: its signature's near the end of the text ("Lisboa, 15 de fevereiro
    /// de 2025", "Data: 10/02/2025"; the last such), else the date it takes effect from (the
    /// first); nil without either — never the contract's own date quoted in it.
    public static func date(in text: String) -> Date? {
        let folded = EvidenceText.fold(text)
        let source = folded as NSString
        let dates = EvidenceDateParser.dates(in: folded)
        func lead(_ found: EvidenceDateParser.Found) -> String {
            let start = max(0, found.range.location - 50)
            return source.substring(with: NSRange(location: start, length: found.range.location - start))
        }
        func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
            regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
        }
        let endRegion = source.length - signatureReach
        if let signed = dates.last(where: { found in
            let before = lead(found)
            return found.range.location >= endRegion && matches(signatureLead, before) && !matches(quotedContract, before)
        }) { return signed.date }
        return dates.first { matches(effectLead, lead($0)) }?.date
    }

    /// Labels whose next amount is the new rent, most specific first (a rent the addendum
    /// only repeats is no new rent).
    static let rentLabels = ["NOVA RENDA", "PASSA A SER DE", "PASSARA A SER DE", "PASSA A SER", "PASSARA A SER", "ATUALIZADA PARA",
                             "ACTUALIZADA PARA", "ALTERADA PARA", "AUMENTADA PARA", "REDUZIDA PARA", "FIXADA EM"]

    /// The new rent: the first amount after a rent label that is money (written with €, EUR or
    /// euros) and no part of a date; nil when the addendum sets none.
    public static func newRent(in text: String) -> EvidenceAmountParser.Found? {
        let body = EvidenceText.fold(text) as NSString
        for label in rentLabels {
            for found in EvidenceAnalyzer.occurrences(of: label, in: body) {
                let window = EvidenceAnalyzer.window(after: found, in: body)
                let dates = EvidenceDateParser.dates(in: window).map(\.range)
                if let amount = EvidenceAmountParser.amounts(in: window).first(where: { amount in
                    amount.currency != nil && amount.minorUnits > 0 && !dates.contains { NSIntersectionRange($0, amount.range).length > 0 }
                }) { return amount }
            }
        }
        return nil
    }

    // MARK: Naming

    /// `<date> - Property - Tenancy addendum - <tenancy>` (`EvidenceNaming`): the tenancy's
    /// reference label when known.
    public static func canonicalName(date: Date, tenancyLabel: String?) -> String {
        EvidenceNaming.canonicalName(date: date, area: ImportNaming.area(of: .tenancyAddendum), type: DocumentKind.tenancyAddendum.displayName,
                                     detail: tenancyLabel)
    }

    // MARK: Tenancy

    /// A tenancy the addendum may amend, with why.
    public struct Candidate: Equatable, Sendable {
        public var tenancy: Tenancy
        public var score: Int
        public var reasons: [String]
        /// Named by the addendum: its contract number or its tenant.
        public var identified: Bool
        /// Named by its contract number.
        public var contractMatched = false
    }

    static let contractPoints = 100
    static let tenantPoints = 60
    static let datePoints = 20
    /// An addendum may be signed a little before its tenancy starts.
    static let daysBeforeStart = 60

    /// The tenancies (of `propertyId`, else all), scored by what the addendum names — the
    /// contract number, the tenant — and whether its date falls in the tenancy; best first.
    public static func candidates(db: Database, text: String?, date: Date?, propertyId: Int64? = nil) throws -> [Candidate] {
        var request = Tenancy.order(Column("startDate"), Column("id"))
        if let propertyId { request = request.filter(Column("propertyId") == propertyId) }
        let body = EvidenceText.normalized(text ?? "")
        let words = Set(body.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return try request.fetchAll(db).map { tenancy in
            var score = 0
            var reasons: [String] = []
            var identified = false
            var contractMatched = false
            if let number = tenancy.contractNumber.map(EvidenceText.normalized), isDistinctive(number), contains(number, in: body) {
                score += contractPoints
                identified = true
                contractMatched = true
                reasons.append("Contract nº \(tenancy.contractNumber ?? number)")
            }
            if let name = tenancy.tenantName.map(EvidenceText.normalized), name.count >= 3 {
                // The whole name, or each of its words (two at least, of three letters or more) in any order.
                let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
                if contains(name, in: body) || (parts.count >= 2 && parts.allSatisfy(words.contains)) {
                    score += tenantPoints
                    identified = true
                    reasons.append("Tenant \(tenancy.tenantName ?? name)")
                }
            }
            if let date, fits(date, tenancy) {
                score += datePoints
                reasons.append("Dated within the tenancy")
            }
            return Candidate(tenancy: tenancy, score: score, reasons: reasons, identified: identified, contractMatched: contractMatched)
        }
        .sorted { $0.score > $1.score }
    }

    /// The tenancy the addendum surely amends: the only one it names — by contract number,
    /// else by tenant — when its date falls in that tenancy; nil otherwise (several named, the
    /// same tenant on two tenancies, no date, a date outside it, only a date that fits).
    public static func clearMatch(_ candidates: [Candidate], date: Date?) -> Candidate? {
        let named = namedOnes(candidates)
        guard named.count == 1, let only = named.first, let date, fits(date, only.tenancy) else { return nil }
        return only
    }

    /// The tenancies to choose from when there's no clear match: those named (and any other
    /// the date fits), else those the date fits, else all.
    public static func options(_ candidates: [Candidate], date: Date?) -> [Candidate] {
        let fitting = date.map { date in candidates.filter { fits(date, $0.tenancy) } } ?? []
        let named = namedOnes(candidates)
        if !named.isEmpty {
            return named + (named.count == 1 ? fitting.filter { $0.tenancy.id != named[0].tenancy.id } : [])
        }
        return fitting.isEmpty ? candidates : fitting
    }

    /// Those its contract number names, else those its tenant names.
    static func namedOnes(_ candidates: [Candidate]) -> [Candidate] {
        let byContract = candidates.filter(\.contractMatched)
        return byContract.isEmpty ? candidates.filter(\.identified) : byContract
    }

    /// A contract number long enough to mean something in a text: four characters, or a
    /// separator in it ("A-7"); never "1" or "12".
    static func isDistinctive(_ number: String) -> Bool {
        number.count >= 4 || (number.count >= 3 && number.contains(where: { "-/.".contains($0) }))
    }

    private static func fits(_ date: Date, _ tenancy: Tenancy) -> Bool {
        let earliest = tenancy.startDate.addingTimeInterval(-Double(daysBeforeStart) * 86_400)
        return date >= earliest && (tenancy.endDate.map { date < PropertyDates.nextDay($0) } ?? true)
    }

    /// `needle` in `text` as whole words (a contract number never inside a longer one).
    private static func contains(_ needle: String, in text: String) -> Bool {
        let pattern = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![\p{L}\d])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
