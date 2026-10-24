import GRDB
import Foundation

private func isoDay(_ date: Date) -> String { PropertyDates.isoDay(date) }

/// "DEMO PWR DD 123 −€100.00" for a transaction offered or linked.
private func transactionLabel(_ transaction: Transaction, currency: Currency) -> String {
    "\(transaction.rawDescription) \(Money.format(transaction.amountMinorUnits, currency: currency))"
}

/// What a record is called in the review: a transaction's description and amount, an account's
/// or category's name, a property or tax record's title.
func entityLabel(db: Database, _ entity: EvidenceEntity) throws -> String {
    try entityTitle(db: db, entity) ?? "\(entity.type.displayName) #\(entity.id)"
}

/// The record's title; `nil` when it no longer exists (`.other` records are named by id).
func entityTitle(db: Database, _ entity: EvidenceEntity) throws -> String? {
    switch entity.type {
    case .transaction:
        if let transaction = try Transaction.fetchOne(db, key: entity.id) {
            let currency = try Account.fetchOne(db, key: transaction.accountId)?.currency ?? .eur
            return transactionLabel(transaction, currency: currency)
        }
    case .account:
        if let account = try Account.fetchOne(db, key: entity.id) { return account.displayName }
    case .category:
        if let category = try Category.fetchOne(db, key: entity.id) { return category.name }
    case .property, .person, .tenancy, .rentReceipt:
        if let title = try PropertyEvidence.title(db: db, entity: entity) { return title }
    case .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution, .taxPolicyReceipt:
        if let title = try TaxEvidence.title(db: db, entity: entity) { return title }
    case .other:
        return "\(entity.type.displayName) #\(entity.id)"
    }
    return nil
}

/// "5 Mar 2023", the app's day style.
private func dayText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = MonthRange.calendar
    formatter.timeZone = MonthRange.calendar.timeZone
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "d MMM yyyy"
    return formatter.string(from: date)
}

/// The reason of a `chooseTarget` issue: the question, or — with nothing to choose from — that
/// the record has to be added first or the file left out.
private func targetReason(_ question: String, options: [Int64], none: String) -> String {
    options.isEmpty ? "\(none) on record: add one first, or leave this file out of the import" : question
}

/// A reader problem with a running id.
private func problem(_ item: inout ImportItem, _ text: String, offers: [ImportResolution] = []) {
    item.issues.append(ImportIssue(id: "readerProblem\(item.issues.count)", kind: .readerProblem(text), reason: text, offers: offers))
}

// MARK: Utility invoices

/// A utility provider's invoice (or credit note): read with the provider's rules
/// (`UtilityInvoiceIntake.propose`), matched to the debit that paid it.
public struct UtilityInvoiceImportReader: ImportReader {
    /// Id of the issue of an invoice no record can be made of (only "file the document only",
    /// `.fileWithoutLink`, or a provider choice settles it).
    public static let documentOnlyIssueId = "noInvoiceRecord"
    /// The note of an invoice filed as a document only.
    public static let documentOnlyNote = "No invoice record: only the document is filed"
    /// The note (and outcome line) of an invoice recorded without a document, whose document this is.
    public static let attachedNote = "Invoice already recorded: the document is attached to it"
    /// Id of the question "which recorded invoice is this a document of?" (several fit).
    public static let chooseInvoiceIssueId = "chooseInvoice"

    static let documentOnlyIssue: ImportIssue = {
        let text = "No invoice record can be made from this file: choose its provider, or file the document only"
        return ImportIssue(id: documentOnlyIssueId, kind: .readerProblem(text), reason: text, offers: [.fileWithoutLink])
    }()

    /// "Possibly a corrected version of Invoice of <provider> for <period>: Amount X → Y" for
    /// an invoice whose period is recorded for another amount (`Recharges.recordedForPeriod`):
    /// filed only, linked where the recorded invoice is (its document's links, its debit).
    static func correctedVersionIssue(of recorded: UtilityInvoice, providerName: String, item: ImportItem, db: Database) throws -> ImportIssue {
        var identity = DocumentIdentity.Identity()
        identity.figures[.amount] = DocumentIdentity.Figure(amount: abs(recorded.amountMinorUnits), currency: nil)
        let entry = DocumentIdentityIndex.Entry(documentId: recorded.documentId,
                                                label: Recharges.invoiceLabel(recorded, providerName: providerName), identity: identity)
        var issue = try ImportDuplicates.correctedVersion(of: entry, item: item, db: db)
        issue.id = ImportDuplicates.recordedCorrectedVersionIssueId
        // Without a document, filed only it is attached to the recorded invoice.
        if recorded.documentId == nil, let id = recorded.id { issue.documentOnlyEffect = .attachToInvoice(invoiceId: id) }
        // Without a document, the recorded invoice is where its debit is.
        if recorded.documentId == nil, let transactionId = recorded.transactionId,
           try EvidenceLinks.entityExists(db: db, .transaction(transactionId)) {
            issue.documentOnlyLinks.append(ProposedLink(entity: .transaction(transactionId), label: try entityLabel(db: db, .transaction(transactionId)),
                                                        confidence: .certain, reasons: ["\(entry.label) is paid by it"]))
        }
        return issue
    }

    /// Providers to recognise invoices by when the context has none.
    public var providers: [UtilityProvider]

    public init(providers: [UtilityProvider] = []) {
        self.providers = providers
    }

    public func handles(_ kind: ImportKind) -> Bool { kind == .utilityInvoice }

    /// Each invoice read with its issuer's learnt figure positions (`LearntFigures`): the invoice
    /// recorded, its debit and copies looked for with the figures read there.
    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        try files.map { entry in
            var readings: [LearntFigures.Reading] = []
            var item = try item(file: entry.file, recognition: entry.recognition, context: context, db: db, readings: &readings)
            LearntFigures.apply(to: &item, readings: readings)
            return item
        }
    }

    /// `readings`: the issuer's learnt positions, as read (once the property's currency is known).
    private func item(file: ImportFile, recognition: ImportRecognition, context: ImportContext, db: Database,
                      readings: inout [LearntFigures.Reading]) throws -> ImportItem {
        let groupKey = "Utility invoices"
        var item = ImportItem(file: file, recognition: recognition, title: "Utility invoice", groupKey: groupKey)
        let known = context.providers.isEmpty ? providers : context.providers
        // The provider the user chose, else the one the invoice names.
        let chosen = context.intent.providerId.flatMap { id in known.first { $0.id == id } }
        let detected = chosen ?? UtilityInvoiceReader.provider(text: file.text, fileName: file.fileName, providers: known)

        // The property: the import's target, else the provider's.
        var property: Property?
        if let id = context.intent.propertyId, let found = context.properties.first(where: { $0.id == id }) {
            property = found
            if let detected, detected.propertyId != id {
                let owner = context.properties.first { $0.id == detected.propertyId }
                item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.property, options: [id, detected.propertyId]),
                                               reason: "\(detected.name) is a provider of \(owner?.name ?? "another property"), not \(found.name): "
                                                   + "which property is this invoice for?"))
            }
        } else if let detected {
            property = context.properties.first { $0.id == detected.propertyId }
        }
        guard let property, let propertyId = property.id else {
            let providerIds = known.compactMap(\.id)
            if providerIds.isEmpty {
                let options = context.properties.compactMap(\.id)
                item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.property, options: options),
                                               reason: targetReason("No provider of a property recognised: which property is this invoice for?",
                                                                    options: options, none: "No properties")))
            } else {
                item.issues.append(ImportIssue(id: "chooseProvider", kind: .chooseTarget(.provider, options: providerIds),
                                               reason: "No provider recognised: whose invoice is this?"))
            }
            item.issues.append(Self.documentOnlyIssue)
            return item
        }

        let proposal: UtilityInvoiceIntake.Proposal
        readings = LearntFigures.readings(file, context: context) { _ in property.currency }
        let learnt = LearntFigures.values(readings)
        do {
            proposal = try UtilityInvoiceIntake.propose(db: db, propertyId: propertyId, documentId: nil, text: file.text,
                                                        fileName: file.fileName, textStatus: file.textStatus, usedOCR: file.usedOCR,
                                                        providerId: chosen?.id, adjust: learnt.isEmpty ? nil : { reading in
                for (field, value) in learnt {
                    switch (field, value) {
                    case (.amount, .money(let minor, _)):
                        // A credit note's figure keeps its sign.
                        reading.amountMinorUnits = (reading.amountMinorUnits ?? 0) < 0 ? -abs(minor) : abs(minor)
                    case (.docDate, .date(let date)): reading.issueDate = date
                    case (.periodStart, .date(let date)): reading.periodStart = date
                    case (.periodEnd, .date(let date)): reading.periodEnd = date
                    default: break
                    }
                }
            })
        } catch {
            problem(&item, "The invoice could not be read: \(error.localizedDescription)")
            return item
        }
        let reading = proposal.reading
        let provider = try reading.providerId.flatMap { try UtilityProvider.fetchOne(db, key: $0) }
        let currency = property.currency
        let source: ImportFactSource = file.usedOCR ? .ocr : .textLayer
        // The same reading without the file name: what it lacks came from the file name.
        let textOnly = UtilityInvoiceReader.read(text: file.text, fileName: "", rules: provider?.effectiveRules ?? .generic)

        // Facts, with where each was read.
        var facts: [ImportFact] = []
        if let provider {
            let fromText = UtilityInvoiceReader.provider(text: file.text, fileName: "", providers: [provider]) != nil
            if let chosen, chosen.id == provider.id {
                facts.append(ImportFact(field: .issuer, value: .text(provider.name), source: .user, confidence: .certain,
                                        reason: "Chosen by you"))
            } else {
                facts.append(ImportFact(field: .issuer, value: .text(provider.name), source: fromText ? source : .fileName,
                                        confidence: .certain, reason: fromText ? "\(provider.name)'s wording on the invoice" : "File name names \(provider.name)"))
            }
        }
        if let number = reading.invoiceNumber {
            facts.append(ImportFact(field: .invoiceNumber, value: .text(number), source: source, confidence: .certain,
                                    reason: "Invoice number on the invoice"))
        }
        if let issued = reading.issueDate {
            let fromText = textOnly.issueDate != nil
            facts.append(ImportFact(field: .docDate, value: .date(issued), source: fromText ? source : .fileName, confidence: .certain,
                                    reason: "Issue date on the invoice"))
        }
        if let start = reading.periodStart {
            facts.append(ImportFact(field: .periodStart, value: .date(start), source: source, confidence: .certain, reason: "Period on the invoice"))
        }
        if let end = reading.periodEnd {
            facts.append(ImportFact(field: .periodEnd, value: .date(end), source: source, confidence: .certain, reason: "Period on the invoice"))
        }
        if let amount = reading.amountMinorUnits {
            facts.append(ImportFact(field: .amount, value: .money(amount, currency), source: source,
                                    confidence: reading.amountReviewNote == nil ? .certain : .needsReview,
                                    reason: reading.amountReviewNote ?? (amount < 0 ? "Refund on the invoice" : "Amount due on the invoice")))
            if let note = reading.amountReviewNote { item.notes.append(note) }
        }
        // The account balance printed beside the invoice's total when it differs (earlier invoices
        // or credits on the account).
        let accountTotal = reading.accountTotalMinorUnits.flatMap { $0 != reading.amountMinorUnits ? $0 : nil }
        if let accountTotal {
            facts.append(ImportFact(field: .accountTotal, value: .money(accountTotal, currency), source: source, confidence: .certain,
                                    reason: "Account total on the invoice: what is debited"))
            item.notes.append("The account total \(Money.format(accountTotal, currency: currency)) includes earlier invoices or credits")
        }
        item.facts = facts
        item.placement = ImportNaming.placement(kind: .utilityInvoice, facts: facts, file: file, persons: [])
        let providerName = provider?.name ?? "a utility provider"
        item.title = [reading.amountMinorUnits.map { $0 < 0 ? "Credit note" : "Invoice" } ?? "Invoice",
                      reading.invoiceNumber, "of \(providerName)"].compactMap { $0 }.joined(separator: " ")
            + (reading.issueDate.map { ", \(dayText($0))" } ?? "")

        // What is missing, and what to check.
        let missingFields: [String: (ImportFigureField, String)] = [
            "provider": (.issuer, "No provider recognised: which provider's invoice is it?"),
            "issue date": (.docDate, "No issue date could be read"),
            "amount": (.amount, "No amount could be read")
        ]
        let propertyProviders = try Recharges.providers(db: db, propertyId: propertyId).compactMap(\.id)
        for missing in proposal.missing {
            if missing == "provider", !propertyProviders.isEmpty {
                item.issues.append(ImportIssue(id: "chooseProvider", kind: .chooseTarget(.provider, options: propertyProviders),
                                               reason: "No provider recognised: which provider's invoice is it?"))
                continue
            }
            guard let (field, reason) = missingFields[missing] else {
                problem(&item, "No \(missing) could be read")
                continue
            }
            item.issues.append(ImportIssue(id: "missingFigure.\(field.rawValue)", kind: .missingFigure(field), reason: reason))
        }
        // The recorded invoice it is a document of: the one it copies, else the one for its
        // period (another amount). One recorded without a document (by hand, from the tracker,
        // or its document deleted) — several fitting: the user's choice, never a guess.
        var copy = try proposal.duplicateOf.flatMap { try UtilityInvoice.fetchOne(db, key: $0) }
        var recorded = copy == nil ? try proposal.correctedVersionOf.flatMap { try UtilityInvoice.fetchOne(db, key: $0) } : nil
        if let read = proposal.invoice, copy?.documentId == nil {
            var candidates = try Recharges.recordedCandidates(db: db, of: read)
            if let copy, !candidates.contains(where: { $0.id == copy.id }) { candidates.insert(copy, at: 0) }
            if let id = context.intent.invoiceId, let chosen = candidates.first(where: { $0.id == id }) {
                copy = chosen.amountMinorUnits == read.amountMinorUnits ? chosen : nil
                recorded = copy == nil ? chosen : nil
            } else if candidates.count >= 2 {
                // A document of one of them, whichever: filed, never recorded a second time.
                let options = candidates.compactMap(\.id)
                let reason = "\(options.count) invoices of \(providerName) fit this one (\(Recharges.invoiceLabel(read, providerName: providerName))): "
                    + "which one is it a document of?"
                item.issues.append(ImportIssue(id: Self.chooseInvoiceIssueId, kind: .chooseTarget(.invoice, options: options), reason: reason,
                                               offers: [.fileWithoutLink, .leaveOut]))
                item.identityProviderId = read.providerId
                item.effect = .file
                return item
            }
        }
        if let copy, let copyId = copy.id, copy.documentId == nil {
            // Recorded without a document: this is it — attached, linked where the invoice is
            // (its debit); no figure of the invoice changes.
            item.effect = .attachToInvoice(invoiceId: copyId)
            item.identityProviderId = copy.providerId
            let label = Recharges.invoiceLabel(copy, providerName: providerName)
            if let transactionId = copy.transactionId, try EvidenceLinks.entityExists(db: db, .transaction(transactionId)) {
                item.links = [ProposedLink(entity: .transaction(transactionId), label: try entityLabel(db: db, .transaction(transactionId)),
                                           confidence: .certain, reasons: ["\(label) is paid by it"])]
            }
            item.notes.append(Self.attachedNote)
            return item
        }
        if let copy {
            // Named by its number when both have one; else (an old bill recorded without one)
            // by its period, else its issue date.
            let of = copy.invoiceNumber.flatMap { number in reading.invoiceNumber == nil ? nil : "Invoice \(number) of \(providerName)" }
                ?? Recharges.invoiceLabel(copy, providerName: providerName)
            item.duplicate = ImportDuplicate(level: .document, of: of + " already recorded", existingDocumentId: copy.documentId)
        }
        var correctedVersion = false
        if copy == nil, let recorded {
            // Another amount for a period already recorded (one of them without a number):
            // possibly a corrected version — filed only, linked where the recorded one is.
            item.issues.append(try Self.correctedVersionIssue(of: recorded, providerName: providerName, item: item, db: db))
            correctedVersion = true
        }
        // What the copy or corrected-version answer says already.
        for warning in proposal.warnings where !((copy != nil || correctedVersion)
            && (warning.hasPrefix("A copy of the invoice") || warning.hasPrefix("An invoice for this period"))) {
            problem(&item, warning)
        }

        // The payment: certain only when exactly one movement of the exact amount in the issue
        // window is the provider's (bank description) or in a utility category — the one the
        // intake proposed; else the user picks, the likely ones first.
        guard var invoice = proposal.invoice else {
            // No invoice record without provider, date and amount: the user chooses the
            // provider (read again), or files the document only.
            item.issues.append(Self.documentOnlyIssue)
            return item
        }
        let accountCurrency: (Transaction) throws -> Currency = { try Account.fetchOne(db, key: $0.accountId)?.currency ?? currency }
        let utilityCategories = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
        let amountText = Money.format(abs(invoice.amountMinorUnits), currency: currency)
        func why(_ transaction: Transaction) -> String? {
            if provider?.matchesBankDescription(transaction.rawDescription) == true { return "its description is \(providerName)'s" }
            if utilityCategories.contains(transaction.categoryId ?? -1) { return "it is in a utility category" }
            return nil
        }
        let candidates = try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider,
                                                                    amountMinorUnits: invoice.amountMinorUnits, issueDate: invoice.issueDate)
        let qualifying = candidates.filter { why($0) != nil }
        // The account total's debit (the provider's, or in a utility category) may have paid it
        // with earlier invoices or less a credit: offered, never certain.
        let accountTotalDebits = try accountTotal.map { total in
            try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: total,
                                                       issueDate: invoice.issueDate).filter { why($0) != nil }
        } ?? []
        if qualifying.count == 1, let payment = qualifying.first, let paymentId = payment.id, proposal.transactionId == paymentId,
           let reason = why(payment) {
            item.links = [ProposedLink(entity: .transaction(paymentId), label: transactionLabel(payment, currency: try accountCurrency(payment)),
                                       confidence: .certain,
                                       reasons: ["Booked on \(isoDay(payment.date)) for exactly \(amountText); \(reason)"],
                                       madeByEffect: true)]
        } else {
            invoice.transactionId = nil
            if candidates.isEmpty && accountTotalDebits.isEmpty {
                item.notes.append("Not linked: no matching debit yet")
            } else {
                var offered = try candidates.prefix(5).compactMap { transaction -> LinkCandidate? in
                    guard let id = transaction.id else { return nil }
                    let reason = why(transaction).map { "Booked on \(isoDay(transaction.date)) for exactly \(amountText); \($0)" }
                        ?? "Booked on \(isoDay(transaction.date)) for exactly \(amountText), but neither \(providerName)'s description nor a utility category"
                    return LinkCandidate(entity: .transaction(id), label: transactionLabel(transaction, currency: try accountCurrency(transaction)),
                                         reasons: [reason])
                }
                let totalText = accountTotal.map { Money.format($0, currency: currency) } ?? ""
                offered += try accountTotalDebits.prefix(5).compactMap { transaction -> LinkCandidate? in
                    guard let id = transaction.id, let why = why(transaction) else { return nil }
                    return LinkCandidate(entity: .transaction(id), label: transactionLabel(transaction, currency: try accountCurrency(transaction)),
                                         reasons: ["Debit of the account total \(totalText) (includes earlier invoices or credits)",
                                                   "Booked on \(isoDay(transaction.date)); \(why)"])
                }
                let reason = candidates.isEmpty
                    ? "No debit of \(amountText): \(providerName) debited the account total \(totalText), which includes earlier invoices or credits. Did it pay this invoice?"
                    : (qualifying.count >= 2
                    ? "\(qualifying.count) movements of \(amountText) look like \(providerName)'s: which one paid this invoice?"
                    : "A movement of the amount fits, but nothing shows it is \(providerName)'s: which one paid it?")
                    + (accountTotalDebits.isEmpty ? "" : " The debit of the account total \(totalText) (includes earlier invoices or credits) is offered too.")
                item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink(offered), reason: reason, offers: [.fileWithoutLink]))
            }
        }
        item.effect = .utilityInvoice(invoice)
        return item
    }
}

// MARK: Payroll forms

/// P60, P45 and P11D forms (`PayrollFormReader`), for the person whose National Insurance
/// number they show.
public struct PayrollFormImportReader: ImportReader {
    /// Vision's accurate recogniser for scans (false: the fast one).
    public var accurateOCR: Bool

    public init(accurateOCR: Bool = true) {
        self.accurateOCR = accurateOCR
    }

    public func handles(_ kind: ImportKind) -> Bool {
        if case .payrollForm = kind { return true }
        return false
    }

    /// Each form, a figure the form reader didn't find filled from its issuer's learnt positions
    /// (`LearntFigures`; what the form reader read stays).
    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        try files.map { entry in
            var filled: [LearntFigures.Reading] = []
            var item = try item(file: entry.file, recognition: entry.recognition, context: context, db: db, filled: &filled)
            LearntFigures.apply(to: &item, readings: filled)
            return item
        }
    }

    /// Reads the form's positioned words (OCR for a scan) into `file.payrollExtraction`. Called
    /// by the pipeline in the file-reading stage, never inside the write transaction. A scan
    /// is recognised again here: `ImportFile.load`'s OCR keeps text only, not word positions.
    public func prepare(_ file: ImportFile, recognition: ImportRecognition) -> ImportFile {
        guard case .payrollForm(let kind) = recognition.kind, file.payrollExtraction == nil else { return file }
        var prepared = file
        prepared.payrollExtraction = PayrollFormReader.read(file.url, kind: kind, accurateOCR: accurateOCR)
        return prepared
    }

    /// Reader warnings that a missing-figure issue already says (or the OCR facts do).
    private static let coveredWarnings: Set<String> = [
        "Read by text recognition: check every figure against the document.",
        "No text could be read: enter the figures by hand.",
        "No employer PAYE reference found.", "No tax year found.", "No employer name found.",
        "No pay and tax figures found.", "No leaving date found."
    ]

    /// `filled`: the learnt positions that filled a figure the form reader didn't find.
    private func item(file: ImportFile, recognition: ImportRecognition, context: ImportContext, db: Database,
                      filled: inout [LearntFigures.Reading]) throws -> ImportItem {
        guard case .payrollForm(let kind) = recognition.kind else {
            return ImportItem(file: file, recognition: recognition, title: file.fileName, groupKey: "Payroll forms")
        }
        var item = ImportItem(file: file, recognition: recognition, title: kind.displayName, groupKey: "Payroll forms")
        // Only what `prepare` read: no file reading (let alone OCR) inside the write transaction.
        var extraction = file.payrollExtraction ?? PayrollFormExtraction(kind: kind, entryMethod: .manual)
        if file.payrollExtraction == nil { problem(&item, "The form was not read before the review: add it again") }
        // Figures the form reader didn't find, from the issuer's learnt positions (its own readings stay).
        for reading in LearntFigures.readings(file, context: context, defaultCurrency: { _ in .gbp }) {
            switch (reading.action.field, reading.value) {
            case (.pay, .money(let pay, _)?) where extraction.payMinorUnits == nil: extraction.payMinorUnits = pay
            case (.taxDeducted, .money(let tax, _)?) where extraction.taxDeductedMinorUnits == nil: extraction.taxDeductedMinorUnits = tax
            case (.docDate, .date(let date)?) where kind == .p45 && extraction.leavingDate == nil: extraction.leavingDate = date
            default: continue
            }
            filled.append(reading)
        }
        // The reader's warnings about a figure now filled no longer hold.
        if extraction.payMinorUnits != nil, extraction.taxDeductedMinorUnits != nil {
            extraction.warnings.removeAll { $0 == "No pay and tax figures found." }
        }
        if extraction.leavingDate != nil { extraction.warnings.removeAll { $0 == "No leaving date found." } }
        let source: ImportFactSource = extraction.entryMethod == .ocr ? .ocr : .textLayer

        // The person: the import's target, else the one the NI number names, else the user picks.
        let suggested = try PayrollFormImport.suggestedPersonId(db: db, nationalInsuranceNumber: extraction.nationalInsuranceNumber)
        let ninoText = extraction.nationalInsuranceNumber.map(PayrollFormImport.normalizedNINO) ?? ""
        var person: Person?
        var personSource = source
        var personReason = ""
        if let id = context.intent.personId, let found = context.people.first(where: { $0.id == id }) {
            person = found
            personSource = .intent
            personReason = "Chosen as the import target"
            if let suggested, suggested != id {
                let owner = context.people.first { $0.id == suggested }?.name ?? "someone else"
                item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.person, options: [id, suggested]),
                                               reason: "National Insurance number \(ninoText) is \(owner)'s, not \(found.name)'s: whose form is this?"))
            } else if suggested == nil, !ninoText.isEmpty, let stored = found.ukNino.map(PayrollFormImport.normalizedNINO),
                      !stored.isEmpty, stored != ninoText {
                // Nobody else's, but not the number stored for this person: theirs to confirm, or another person's form.
                item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.person, options: context.people.compactMap(\.id)),
                                               reason: "The form's National Insurance number isn't the one stored for \(found.name)",
                                               offers: [.acknowledge]))
            }
        } else if let suggested, let found = context.people.first(where: { $0.id == suggested }) {
            person = found
            personReason = "National Insurance number \(ninoText) is \(found.name)'s"
        } else {
            let why = ninoText.isEmpty ? "No National Insurance number read" : "National Insurance number \(ninoText) is no one's on record"
            let options = context.people.compactMap(\.id)
            item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.person, options: options),
                                           reason: targetReason("\(why): whose \(kind.displayName) is this?", options: options, none: "No people")))
        }

        // Facts, all from the form (OCR: every one needs checking).
        var facts: [ImportFact] = []
        func add(_ field: ImportFigureField, _ value: ImportFactValue, _ reason: String) {
            facts.append(ImportFact(field: field, value: value, source: source, confidence: .certain, reason: reason))
        }
        if let employer = extraction.employerName { add(.issuer, .text(employer), "Employer on the \(kind.displayName)") }
        if let year = extraction.startYear { add(.taxYear, .year(year), "Tax year on the \(kind.displayName)") }
        if let reference = extraction.payeReference { add(.reference, .text(reference), "Employer PAYE reference on the \(kind.displayName)") }
        if let pay = extraction.payMinorUnits { add(.pay, .money(pay, .gbp), "Pay in this employment") }
        if let tax = extraction.taxDeductedMinorUnits { add(.taxDeducted, .money(tax, .gbp), "Tax deducted in this employment") }
        if kind == .p11d {
            let total = extraction.benefits.reduce(0) { $0 + $1.cashEquivalentMinorUnits }
            if !extraction.benefits.isEmpty { add(.amount, .money(total, .gbp), "Cash equivalents of the benefits") }
        }
        if let code = extraction.taxCode { add(.taxCode, .text(code), "Tax code on the \(kind.displayName)") }
        if kind == .p45, let leaving = extraction.leavingDate { add(.docDate, .date(leaving), "Leaving date on the P45") }
        if let person {
            facts.append(ImportFact(field: .person, value: .text(person.name), source: personSource, confidence: .certain, reason: personReason))
        }
        item.facts = facts
        item.placement = ImportNaming.placement(kind: recognition.kind, facts: facts, file: file,
                                                persons: person.map { [$0.displayShortName] } ?? [])
        item.title = [kind.displayName, extraction.employerName,
                      extraction.startYear.map { UKTaxYear(startYear: $0).label }].compactMap { $0 }.joined(separator: " ")

        // What stops it being saved, and what the reader wasn't sure of.
        let confirmed = PayrollFormImport.Confirmed(extraction, kind: kind, personId: person?.id ?? 0)
        for found in PayrollFormImport.problems(confirmed) {
            switch found {
            case .missingTaxYear:
                item.issues.append(ImportIssue(id: "missingFigure.taxYear", kind: .missingFigure(.taxYear), reason: "No tax year could be read"))
            case .missingEmployer:
                item.issues.append(ImportIssue(id: "missingFigure.issuer", kind: .missingFigure(.issuer), reason: "No employer could be read"))
            case .missingPayOrTax:
                let field: ImportFigureField = extraction.payMinorUnits == nil ? .pay : .taxDeducted
                item.issues.append(ImportIssue(id: "missingFigure.\(field.rawValue)", kind: .missingFigure(field),
                                               reason: "No pay and tax figures could be read"))
            case .missingLeavingDate:
                item.issues.append(ImportIssue(id: "missingFigure.docDate", kind: .missingFigure(.docDate), reason: "No leaving date could be read"))
            case .leavingDateOutsideYear:
                problem(&item, "The leaving date isn't in the form's tax year")
            case .invalidPAYEReference:
                problem(&item, "The employer PAYE reference \(extraction.payeReference ?? "") isn't like 123/AB456")
            }
        }
        for warning in extraction.warnings where !Self.coveredWarnings.contains(warning) {
            problem(&item, warning, offers: [.acknowledge])
        }

        guard let person, let personId = person.id else { return item }
        item.effect = .payrollForm(PayrollFormImport.Confirmed(extraction, kind: kind, personId: personId))
        if let year = extraction.startYear,
           let employment = try Employments.find(db: db, startYear: year, personId: personId, payeReference: extraction.payeReference,
                                                 employerName: extraction.employerName),
           let employmentId = employment.id {
            let label = UKTaxYear(startYear: year).label
            let why: String
            if let reference = try? Employments.normalizedPAYEReference(extraction.payeReference), employment.payeReference == reference {
                why = "PAYE reference \(reference) matches \(person.name)'s employment in \(label)"
            } else {
                why = "\(employment.employerName) is \(person.name)'s employer in \(label)"
            }
            item.links = [ProposedLink(entity: .employment(employmentId), role: kind.displayName,
                                       label: try entityLabel(db: db, .employment(employmentId)), confidence: .certain,
                                       reasons: [why], madeByEffect: true)]
        } else if let year = extraction.startYear, let employer = extraction.employerName {
            item.notes.append("Creates \(person.name)'s employment at \(employer) in \(UKTaxYear(startYear: year).label)")
        }
        return item
    }
}

// MARK: Other evidence documents

/// Any other recognised document (insurance, IMI, condomínio, tax letters …) and unrecognised
/// files: read with `EvidenceAnalyzer`, linked to the transaction `EvidenceMatcher` is sure of.
public struct EvidenceDocumentReader: ImportReader {
    public init() {}

    public func handles(_ kind: ImportKind) -> Bool {
        // Bank debit advices have their own reader (`BBVADebitAdviceReader`), which hands back
        // the ones it can't read.
        if case .evidence(let documentKind) = kind { return documentKind != .bankDebitAdvice }
        if case .customEvidence = kind { return true }
        return kind == .unknown
    }

    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        guard !files.isEmpty else { return [] }
        let index = EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                          categories: try Category.fetchAll(db))
        let targetLabel = try context.intent.target.flatMap { try entityTitle(db: db, $0.entity) }
        return try files.map { entry in
            var readings: [LearntFigures.Reading] = []
            var item = try item(file: entry.file, recognition: entry.recognition, context: context, index: index,
                                targetLabel: targetLabel, db: db, readings: &readings)
            LearntFigures.apply(to: &item, readings: readings)
            return item
        }
    }

    /// Suggestions this close to the best are as good: the user picks.
    static let tieMargin = 20

    /// `readings`: the issuer's learnt positions, as read.
    private func item(file: ImportFile, recognition: ImportRecognition, context: ImportContext, index: EvidenceMatcher.Index,
                      targetLabel: String?, db: Database, readings: inout [LearntFigures.Reading]) throws -> ImportItem {
        // A custom kind is read as Other, then named and filed as itself (a kind that's gone: Other).
        var custom: ImportCustomKind?
        let kind: DocumentKind
        switch recognition.kind {
        case .evidence(let evidenceKind):
            kind = evidenceKind
        case .customEvidence(let key):
            kind = .other
            custom = context.customKinds[key]
        default:
            var item = ImportItem(file: file, recognition: recognition, title: file.fileName, groupKey: "Other documents")
            item.issues.append(ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: nil), reason: "What kind of document is this?"))
            item.placement = ImportNaming.placement(kind: .unknown, facts: [], file: file, persons: [])
            return item
        }
        let kindName = custom?.name ?? kind.displayName
        let analysis = EvidenceAnalyzer.analyze(text: file.text, textStatus: file.textStatus, fileName: file.fileName)
        var metadata = analysis.metadata
        // The issuer's learnt positions, before the transaction is matched on them (`LearntFigures.apply` names them).
        let currency = metadata.currency ?? .eur
        readings = LearntFigures.readings(file, context: context) { _ in currency }
        for (field, value) in LearntFigures.values(readings) {
            switch (field, value) {
            case (.amount, .money(let minor, let currency)): (metadata.amountMinorUnits, metadata.currency) = (minor, currency)
            case (.docDate, .date(let date)): metadata.docDate = date
            case (.periodStart, .date(let date)): metadata.periodStart = date
            case (.periodEnd, .date(let date)): metadata.periodEnd = date
            default: break
            }
        }
        let source: ImportFactSource = file.usedOCR ? .ocr : .textLayer
        let body = file.text.map(EvidenceText.fold) ?? ""

        var facts: [ImportFact] = []
        if let date = metadata.docDate {
            // The same analysis without the file name: no date there means the file name's.
            let fromText = !body.isEmpty
                && EvidenceAnalyzer.analyze(text: file.text, textStatus: file.textStatus, fileName: "").metadata.docDate != nil
            facts.append(ImportFact(field: .docDate, value: .date(date), source: fromText ? source : .fileName, confidence: .certain,
                                    reason: "Date on the document"))
        }
        if let start = metadata.periodStart {
            facts.append(ImportFact(field: .periodStart, value: .date(start), source: source, confidence: .certain, reason: "Period on the document"))
        }
        if let end = metadata.periodEnd {
            facts.append(ImportFact(field: .periodEnd, value: .date(end), source: source, confidence: .certain, reason: "Period on the document"))
        }
        if let amount = metadata.amountMinorUnits, let currency = metadata.currency {
            facts.append(ImportFact(field: .amount, value: .money(amount, currency), source: source, confidence: .certain,
                                    reason: "Amount on the document"))
        }
        // A mortgage receipt's instalment ("193/480"), named in its canonical name.
        if kind == .mortgageReceipt, let instalment = MortgageReceipt.instalment(text: file.text, fileName: file.fileName) {
            let fromText = MortgageReceipt.instalment(text: file.text, fileName: "") != nil
            facts.append(ImportFact(field: .receiptNumber, value: .text(instalment.label), source: fromText ? source : .fileName,
                                    confidence: .certain, reason: "Instalment on the receipt"))
        }
        // An addendum is linked to the tenancy it amends, never to a transaction.
        if kind == .tenancyAddendum {
            return try addendumItem(file: file, recognition: recognition, facts: facts, date: metadata.docDate, context: context,
                                    targetLabel: targetLabel, db: db)
        }
        var item = ImportItem(file: file, recognition: recognition, title: kindName, facts: facts,
                              groupKey: "\(kindName) documents")
        item.placement = ImportNaming.placement(kind: recognition.kind, facts: facts, file: file, persons: [], customKind: custom)
        if let date = metadata.docDate { item.title = "\(kindName) of \(isoDay(date))" }

        // The link, by fixed rules: the user's target, a single clear match, else the user picks.
        if let target = context.intent.target {
            if let label = targetLabel {
                item.links = [ProposedLink(entity: target.entity, role: target.role, label: label, confidence: .certain,
                                           reasons: [context.intent.targetReason(label: label)])]
            } else {
                problem(&item, "The \(target.entity.type.displayName.lowercased()) you added it to no longer exists",
                        offers: [.fileWithoutLink])
            }
            return item
        }
        let document = EvidenceDocument(sha256: file.sha256, storedRelativePath: "", originalFileName: file.fileName,
                                        byteCount: file.byteCount, kind: kind, docDate: metadata.docDate,
                                        periodStart: metadata.periodStart, periodEnd: metadata.periodEnd,
                                        amountMinorUnits: metadata.amountMinorUnits, currency: metadata.currency,
                                        textStatus: file.textStatus, extractedText: file.text, addedAt: context.now,
                                        customKindId: custom?.key.savedId)
        let suggestions = EvidenceMatcher.suggestions(document: document, index: index)
        func candidate(_ suggestion: EvidenceMatcher.Suggestion) throws -> LinkCandidate {
            LinkCandidate(entity: .transaction(suggestion.transactionId), label: try entityLabel(db: db, .transaction(suggestion.transactionId)),
                          reasons: suggestion.reasons)
        }
        // A clear winner only: no other exact amount within `tieMargin` points of it.
        let confident = EvidenceMatcher.confidentMatch(suggestions).flatMap { match in
            suggestions.contains { $0.transactionId != match.transactionId && $0.amountMatched && match.score - $0.score <= Self.tieMargin }
                ? nil : match
        }
        if let match = confident {
            item.links = [ProposedLink(entity: .transaction(match.transactionId), label: try entityLabel(db: db, .transaction(match.transactionId)),
                                       confidence: .certain, reasons: match.reasons)]
        } else if suggestions.count == 1, let only = suggestions.first, only.amountMatched, !only.dateInWindow, !only.referenceMatched {
            item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink([try candidate(only)]), reason: "Matched on amount only",
                                           offers: [.fileWithoutLink]))
        } else if let best = suggestions.first {
            let close = suggestions.filter { best.score - $0.score <= Self.tieMargin }
            let reason = close.count >= 2 ? "\(close.count) transactions fit equally well: which one is it?"
                : "A transaction may fit, but not surely: is it this one?"
            item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink(try suggestions.prefix(5).map(candidate)), reason: reason,
                                           offers: [.fileWithoutLink]))
        } else {
            item.notes.append("Not linked: no matching transaction yet")
        }
        return item
    }

    /// A tenancy addendum (`TenancyAddendum`): linked as "Addendum" to the tenancy the user added
    /// it to, else to the one it names (contract number, tenant) when a single one does; else the
    /// user picks the tenancy, or files it without one. Named after the tenancy (a `.reference`
    /// fact, so a renaming keeps it).
    private func addendumItem(file: ImportFile, recognition: ImportRecognition, facts: [ImportFact], date: Date?, context: ImportContext,
                              targetLabel: String?, db: Database) throws -> ImportItem {
        let kind = DocumentKind.tenancyAddendum
        var item = ImportItem(file: file, recognition: recognition, title: kind.displayName, facts: facts, groupKey: "\(kind.displayName) documents")
        var tenancy: Tenancy?
        if let target = context.intent.target {
            if let label = targetLabel {
                let isTenancy = target.entity.type == .tenancy
                if isTenancy { tenancy = try Tenancy.fetchOne(db, key: target.entity.id) }
                item.links = [ProposedLink(entity: target.entity, role: isTenancy ? TenancyAddendum.linkRole : target.role, label: label,
                                           confidence: .certain, reasons: [context.intent.targetReason(label: label)])]
            } else {
                problem(&item, "The \(target.entity.type.displayName.lowercased()) you added it to no longer exists", offers: [.fileWithoutLink])
            }
        } else {
            let candidates = try TenancyAddendum.candidates(db: db, text: file.text, date: date, propertyId: context.intent.propertyId)
            if let match = TenancyAddendum.clearMatch(candidates, date: date), let id = match.tenancy.id {
                tenancy = match.tenancy
                item.links = [ProposedLink(entity: .tenancy(id), role: TenancyAddendum.linkRole, label: try entityLabel(db: db, .tenancy(id)),
                                           confidence: .certain, reasons: match.reasons)]
            } else {
                let options = TenancyAddendum.options(candidates, date: date).compactMap(\.tenancy.id)
                if options.isEmpty {
                    item.notes.append("Not linked: no tenancy on record yet")
                } else {
                    let reason = options.count >= 2 && candidates.contains(where: \.identified)
                        ? "\(options.count) tenancies fit equally well: which one does this addendum amend?"
                        : "Which tenancy does this addendum amend?"
                    item.issues.append(ImportIssue(id: "chooseTarget", kind: .chooseTarget(.tenancy, options: options), reason: reason,
                                                   offers: [.fileWithoutLink]))
                }
            }
        }
        if let tenancy {
            item.facts.append(ImportFact(field: .reference, value: .text(tenancy.referenceLabel), source: .matchedRecord, confidence: .certain,
                                         reason: "The tenancy it amends"))
        }
        item.placement = ImportNaming.placement(kind: recognition.kind, facts: item.facts, file: file, persons: [])
        if let date { item.title = "\(kind.displayName) of \(isoDay(date))" }
        return item
    }
}
