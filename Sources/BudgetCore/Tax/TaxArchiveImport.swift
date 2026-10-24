import Foundation
import GRDB

/// The archive of earlier tax years brought into the library in one go (the `ImportTaxArchive`
/// tool): every file of a folder of tax paperwork — returns, SA302s, P60s, P45s, P11Ds, HMRC
/// letters and payment proofs, the accountant's templates, the supporting receipts — filed
/// with canonical names, linked to the person's tax year, and the payroll forms turned into
/// employment records where the year has none yet. A filed or paid year's figures must come
/// out equal to the return as filed (the `filed` settings), or stay as they were: anything
/// else is refused. Runs on copies first; the tool only touches the real data once a run on
/// copies passed.
///
/// What it never does: overwrite an employment, pay or benefit recorded from a filed return
/// with a form's figures (the form is linked to that record instead, and a difference is
/// reported), create a second employment in a year already set up from its return, or apply
/// an item the importer isn't sure about (those are listed for the review in the app).
public enum TaxArchiveImport {
    public struct Options: Sendable {
        /// The archive folder (every file inside, folders expanded; zip archives skipped).
        public var folder: URL
        /// The filed figures by person and year (`SelfAssessmentRegression.Settings`): the guard.
        public var filed: SelfAssessmentRegression.Settings?
        /// Records to set up first (`TaxDataPlan`): years set up from a disclosure, manual items.
        public var plan: TaxDataPlan.Plan?
        public var entryPoint = "Tax archive"
        /// Payroll forms and evidence are read by text recognition when they have no text layer.
        public var allowOCR = true
        public var now = Date()

        public init(folder: URL, filed: SelfAssessmentRegression.Settings? = nil, plan: TaxDataPlan.Plan? = nil) {
            self.folder = folder
            self.filed = filed
            self.plan = plan
        }
    }

    /// What became of one file of the archive.
    public struct FileOutcome: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A payroll form recorded: the employment (created or found) and the figures saved.
            case recorded
            /// A payroll form linked to the record the year already has (figures kept as filed).
            case linkedToExisting
            /// Filed in the library by the importer (and linked where it was sure).
            case filed
            /// Already in the library (nothing to do beyond a link).
            case duplicate
            /// The importer wasn't sure: left for the review in the app.
            case needsYou
            /// Not imported on purpose (a zip, a package).
            case skipped
            case failed
        }

        public var relativePath: String
        public var kind: Kind
        /// One line: what it is and what happened.
        public var detail: String
        /// Why it needs the user (Needs you), or the problems found.
        public var reasons: [String] = []
        public var documentId: Int64? = nil
    }

    /// One filed figure after the run, against the return and against before.
    public struct GuardRow: Equatable, Sendable {
        public var person: String
        public var startYear: Int
        public var label: String
        public var filed: Int
        public var before: Int?
        public var after: Int?
        /// Pence within which the figure counts as equal to the return (`Settings.PersonYear.tolerancePence`).
        public var tolerance: Int = 1
        /// Equal to the return as filed, unchanged, or nearer the filed figure than before
        /// (a figure that only moves towards the return: the import never moves one away).
        public var ok: Bool {
            if matchesFiled { return true }
            // Absent both before and after (the year couldn't be computed, or the box isn't there): not a pass.
            guard let before, let after else { return false }
            if after == before { return true }
            return abs(after - filed) < abs(before - filed)
        }
        public var matchesFiled: Bool { after.map { abs($0 - filed) <= tolerance } ?? false }
    }

    public struct Report: Sendable {
        public var files: [FileOutcome]
        public var planNotes: [String]
        /// Filed or paid years whose figures moved (every one, including those that now equal the return).
        public var filedImpacts: [FiledYearImpact]
        public var guardRows: [GuardRow]
        /// Why the run must not be applied (empty: it may).
        public var refusals: [String]
        public var text: String

        public func count(_ kind: FileOutcome.Kind) -> Int { files.filter { $0.kind == kind }.count }
        public var passed: Bool { refusals.isEmpty }
    }

    public enum ArchiveError: Error, Equatable, LocalizedError {
        case folderMissing(String)

        public var errorDescription: String? {
            switch self {
            case .folderMissing(let path): return "No folder at \(path)"
            }
        }
    }

    static let imageExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
    static let workpaperExtensions: Set<String> = ["xlsx", "xls", "numbers", "csv"]

    // MARK: Running

    public static func run(dbQueue: DatabaseQueue, library: EvidenceLibrary, options: Options,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Report {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ArchiveError.folderMissing(options.folder.path)
        }
        let people = try await dbQueue.read { db in try People.all(db: db) }
        let planYears = options.plan.map(TaxDataPlan.years) ?? []
        let filedYears = options.filed?.personYears.map(\.startYear) ?? []
        let before = try await dbQueue.read { db in try TaxFigures.snapshot(db: db, years: planYears + filedYears) }
        let beforeRows = try await guardRows(dbQueue: dbQueue, settings: options.filed, before: nil)

        var outcomes: [FileOutcome] = []
        var planNotes: [String] = []

        // 1. The plan: years set up from a disclosure, manual items, statuses.
        if let plan = options.plan {
            progress("Applying the plan…")
            let outcome = try await dbQueue.write { db in try TaxDataPlan.apply(db: db, plan: plan, now: options.now) }
            planNotes = TaxDataPlan.report(outcome).split(separator: "\n").map(String.init)
        }

        // 2. The files.
        let collected = ImportFileCollector.collect([options.folder])
        let root = options.folder.standardizedFileURL.path
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
        }
        for name in collected.ignored { outcomes.append(FileOutcome(relativePath: name, kind: .skipped, detail: "Ignored (hidden, system or package file)")) }

        var forPipeline: [URL] = []
        var workpapers: [URL] = []
        var payroll: [URL] = []
        for url in collected.files {
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                outcomes.append(FileOutcome(relativePath: relative(url), kind: .skipped, detail: "Zip archive: its contents are imported from the folder beside it"))
            } else if workpaperExtensions.contains(ext) {
                workpapers.append(url)
            } else if imageExtensions.contains(ext) {
                payroll.append(url)
            } else {
                forPipeline.append(url)
            }
        }

        // 3. Payroll forms: read first, so the importer's filed-year guard never has to hold them.
        progress("Reading \(payroll.count) PDFs and images for P60s, P45s and P11Ds…")
        var seenPayroll: Set<String> = []
        for url in payroll {
            let extraction = PayrollFormReader.read(url, allowOCR: options.allowOCR)
            guard let form = extraction.kind, extraction.entryMethod != .manual else {
                forPipeline.append(url)
                continue
            }
            let path = relative(url)
            let sha = try EvidenceLibrary.sha256(of: url)
            if seenPayroll.contains(sha) {
                outcomes.append(FileOutcome(relativePath: path, kind: .duplicate, detail: "\(form.displayName): same file as one already handled in this archive"))
                continue
            }
            seenPayroll.insert(sha)
            // Decided in a read, the file placed in the library outside any transaction, then the records written.
            let decision = try await dbQueue.read { db in
                try decidePayrollForm(db: db, relativePath: path, extraction: extraction, form: form, people: people)
            }
            let document = try addForm(library: library, url: url, form: form, person: decision.person, startYear: decision.startYear,
                                       employer: decision.employer, extraction: extraction, now: options.now)
            let outcome = try await dbQueue.write { db in
                try applyPayrollDecision(db: db, decision, document: document, relativePath: path, extraction: extraction, form: form)
            }
            outcomes.append(outcome)
        }

        // 4. The accountant's workpapers: filed for the year, never read.
        for url in workpapers {
            let path = relative(url)
            let person = personNamed(in: path, people: people)
            let year = startYear(inPath: path)
            let (document, isNew) = try addWorkpaper(library: library, url: url, person: person, startYear: year, now: options.now)
            let outcome = try await dbQueue.write { db in
                try linkToYear(db: db, documentId: document.id!, person: person, startYear: year, role: "Workpaper")
                let who = [person?.name, year.map { UKTaxYear(startYear: $0).label }].compactMap { $0 }.joined(separator: " ")
                return isNew
                    ? FileOutcome(relativePath: path, kind: .filed, detail: "Workpaper filed" + (who.isEmpty ? " (no person or year told from its name)" : " for \(who)"),
                                  documentId: document.id)
                    : FileOutcome(relativePath: path, kind: .duplicate, detail: "Workpaper already in the library as \(document.displayName)", documentId: document.id)
            }
            outcomes.append(outcome)
        }

        // 5. Everything else through the importer, a top-level folder at a time; only Ready items applied.
        let groups = Dictionary(grouping: forPipeline) { url -> String in
            let parts = relative(url).split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : ""
        }
        let pipeline = ImportPipeline(dbQueue: dbQueue, library: library,
                                      categorizationService: CategorizationService(categorizer: ImportDryRun.NoSuggestions()))
        defer { pipeline.discardPlanningCopy() }
        for key in groups.keys.sorted() {
            let urls = groups[key]!
            progress("Importing \(urls.count) files of \(key.isEmpty ? "the folder" : key)…")
            outcomes += try await importThroughPipeline(pipeline: pipeline, dbQueue: dbQueue, library: library, urls: urls,
                                                        relative: relative, entryPoint: options.entryPoint, now: options.now)
        }

        // 6. UK tax documents linked to the person's tax year.
        progress("Linking tax documents to their years…")
        let documentIds = outcomes.compactMap(\.documentId)
        let paths = pathsById(outcomes)
        try await dbQueue.write { db in try linkTaxDocuments(db: db, documentIds: documentIds, people: people, relativePaths: paths) }

        // 7. The guard.
        progress("Checking the filed years…")
        let after = try await dbQueue.read { db in try TaxFigures.snapshot(db: db, years: planYears + filedYears) }
        let impacts = FiledYearImpact.impacts(before: before, after: after, causes: ["the tax archive import"], includeInformationOnly: false)
        let rows = try await guardRows(dbQueue: dbQueue, settings: options.filed, before: beforeRows)
        var refusals: [String] = []
        for row in rows where !row.ok {
            refusals.append("\(UKTaxYear(startYear: row.startYear).label) \(row.person) · \(row.label): filed \(money(row.filed)), before \(money(row.before)), after \(money(row.after))")
        }
        let stillDiffer = rows.filter { !$0.matchesFiled }.count
        if stillDiffer > 0 { progress("\(stillDiffer) filed figure\(stillDiffer == 1 ? "" : "s") still differ from the return (see the report).") }
        let text = reportText(outcomes: outcomes, planNotes: planNotes, impacts: impacts, rows: rows, refusals: refusals, folder: options.folder)
        return Report(files: outcomes, planNotes: planNotes, filedImpacts: impacts, guardRows: rows, refusals: refusals, text: text)
    }

    static func pathsById(_ outcomes: [FileOutcome]) -> [Int64: String] {
        var paths: [Int64: String] = [:]
        for outcome in outcomes { if let id = outcome.documentId, paths[id] == nil { paths[id] = outcome.relativePath } }
        return paths
    }

    static func money(_ pence: Int?) -> String { pence.map { Money.format($0, currency: .gbp) } ?? "—" }

    // MARK: Payroll forms

    /// What to do with a P60 / P45 / P11D, decided from the records: a new employment with the
    /// form's figures when the year has none for the employer; linked to the year's existing
    /// record (pay kept as filed) when the employer is already there; filed for the year without
    /// a record when a closed year was set up from its return with other employers. Needs the
    /// user when the person or year can't be told, or the form couldn't be read in full.
    struct PayrollDecision {
        enum Action {
            case record(PayrollFormImport.Confirmed)
            /// The employment, and the pay row (P60 / P45) the form is linked to, if any.
            case linkExisting(Employment, EmploymentIncome?, note: String)
            case needsYou
        }
        var action: Action
        var person: Person?
        var startYear: Int?
        var employer: String?
        var reasons: [String]
        var label: String
    }

    static func decidePayrollForm(db: Database, relativePath: String, extraction: PayrollFormExtraction, form: PayrollFormKind,
                                  people: [Person]) throws -> PayrollDecision {
        let personId = try PayrollFormImport.suggestedPersonId(db: db, nationalInsuranceNumber: extraction.nationalInsuranceNumber)
            ?? personNamed(in: relativePath, people: people)?.id
        let startYear = extraction.startYear ?? startYear(inPath: relativePath)
        let employer = extraction.employerName
        let label = "\(form.displayName)" + (employer.map { " · \($0)" } ?? "") + (startYear.map { " · \(UKTaxYear(startYear: $0).label)" } ?? "")
        var reasons = extraction.warnings
        var decision = PayrollDecision(action: .needsYou, person: nil, startYear: startYear, employer: employer, reasons: reasons, label: label)
        guard let personId, let person = people.first(where: { $0.id == personId }) else {
            decision.reasons.insert("Whose form is it? No National Insurance number or name matched a person.", at: 0)
            return decision
        }
        decision.person = person
        guard let startYear else {
            decision.reasons.insert("Which tax year? The form doesn't say and the folder doesn't either.", at: 0)
            return decision
        }
        var confirmed = PayrollFormImport.Confirmed(extraction, kind: form, personId: personId)
        confirmed.startYear = startYear
        let reference = try? Employments.normalizedPAYEReference(confirmed.payeReference)
        let employments = try Employments.employments(db: db, startYear: startYear, personId: personId)
        let existing = try Employments.find(db: db, startYear: startYear, personId: personId, payeReference: reference ?? nil, employerName: employer)
        let status = try TaxYears.year(db: db, startYear: startYear, personId: personId)?.status
        let closed = status == .filed || status == .paid

        if let existing {
            let income = try Employments.effectiveIncome(db: db, employmentId: existing.id!)
            let benefits = try Employments.benefits(db: db, employmentId: existing.id!)
            // Figures of this form's kind already there (pay for a P60 / P45, benefits for a
            // P11D): kept, the form linked. An employment the other form created moments ago
            // (a P11D before its P60) still takes the figures.
            let hasFigures = form == .p11d ? !benefits.isEmpty : income != nil
            if hasFigures {
                let row = try EmploymentIncome.filter(Column("employmentId") == existing.id! && Column("source") == (form.incomeSource ?? .p60).rawValue)
                    .order(Column("id")).fetchOne(db)
                var note = ""
                if form != .p11d, let income, let pay = extraction.payMinorUnits, let tax = extraction.taxDeductedMinorUnits,
                   pay != income.payMinorUnits || tax != income.taxDeductedMinorUnits {
                    note = "; the form shows pay \(money(pay)), tax \(money(tax)) against \(money(income.payMinorUnits)), \(money(income.taxDeductedMinorUnits)) recorded"
                        + (closed ? " (as filed)" : "")
                }
                if form == .p11d, !benefits.isEmpty {
                    let formTotal = extraction.benefits.reduce(0) { $0 + $1.cashEquivalentMinorUnits }
                    let recorded = benefits.reduce(0) { $0 + $1.cashEquivalentMinorUnits }
                    if formTotal != recorded { note = "; the form shows benefits \(money(formTotal)) against \(money(recorded)) recorded" }
                }
                decision.employer = existing.employerName
                decision.action = .linkExisting(existing, form == .p11d ? nil : row, note: note)
                return decision
            }
        }
        if existing == nil, closed, !employments.isEmpty {
            decision.reasons.insert("\(UKTaxYear(startYear: startYear).label) is \(status == .paid ? "paid" : "filed") and its employments were recorded from the return (\(employments.map(\.employerName).joined(separator: ", "))): \(employer ?? "this employer") isn't among them.", at: 0)
            return decision
        }
        let problems = PayrollFormImport.problems(confirmed)
        guard problems.isEmpty else {
            decision.reasons.insert("The form couldn't be read in full: " + problems.map(problemText).joined(separator: ", "), at: 0)
            return decision
        }
        reasons = decision.reasons
        decision.action = .record(confirmed)
        decision.reasons = reasons
        return decision
    }

    /// Writes the decision: the links, or the records through `PayrollFormImport`.
    static func applyPayrollDecision(db: Database, _ decision: PayrollDecision, document: EvidenceDocument, relativePath: String,
                                     extraction: PayrollFormExtraction, form: PayrollFormKind) throws -> FileOutcome {
        let documentId = document.id!
        let person = decision.person
        let yearLabel = decision.startYear.map { UKTaxYear(startYear: $0).label }
        switch decision.action {
        case .needsYou:
            try linkToYear(db: db, documentId: documentId, person: person, startYear: decision.startYear, role: form.displayName)
            let forWhom = [person?.name, yearLabel].compactMap { $0 }.joined(separator: " ")
            return FileOutcome(relativePath: relativePath, kind: .needsYou, detail: "\(decision.label): filed\(forWhom.isEmpty ? "" : " for \(forWhom)"), not recorded",
                               reasons: decision.reasons, documentId: documentId)
        case .linkExisting(let employment, let row, let note):
            let entity: EvidenceEntity = row.map { .employmentIncome($0.id!) } ?? .employment(employment.id!)
            try EvidenceLinks.link(db: db, documentId: documentId, to: entity, role: form.displayName)
            try linkToYear(db: db, documentId: documentId, person: person, startYear: decision.startYear, role: form.displayName)
            return FileOutcome(relativePath: relativePath, kind: .linkedToExisting,
                               detail: "\(decision.label): linked to \(employment.employerName) (\(person?.name ?? "")), figures kept" + note,
                               reasons: decision.reasons, documentId: documentId)
        case .record(let confirmed):
            let result = try PayrollFormImport.apply(db: db, confirmed, documentId: documentId)
            try linkToYear(db: db, documentId: documentId, person: person, startYear: decision.startYear, role: form.displayName)
            var detail = "\(decision.label): \(result.createdEmployment ? "employment created" : "employment found") for \(person?.name ?? "")"
            if let income = result.income { detail += ", pay \(money(income.payMinorUnits)), tax \(money(income.taxDeductedMinorUnits))" }
            if !result.benefits.isEmpty { detail += ", benefits " + result.benefits.map { "box \($0.sa102Box) \(money($0.cashEquivalentMinorUnits))" }.joined(separator: ", ") }
            return FileOutcome(relativePath: relativePath, kind: .recorded, detail: detail, reasons: decision.reasons, documentId: documentId)
        }
    }

    static func problemText(_ problem: PayrollFormImport.Problem) -> String {
        switch problem {
        case .missingTaxYear: return "no tax year"
        case .missingEmployer: return "no employer name"
        case .missingPayOrTax: return "no pay and tax"
        case .missingLeavingDate: return "no leaving date"
        case .leavingDateOutsideYear: return "the leaving date isn't in the year"
        case .invalidPAYEReference: return "the PAYE reference doesn't look right"
        }
    }

    /// The form in the library (or the document already holding it), named like the importer
    /// names payroll forms: `<end year> - Tax - P60 - <employer> <year>`. Outside any transaction.
    static func addForm(library: EvidenceLibrary, url: URL, form: PayrollFormKind, person: Person?, startYear: Int?, employer: String?,
                        extraction: PayrollFormExtraction, now: Date) throws -> EvidenceDocument {
        if let existing = try library.document(sha256: try EvidenceLibrary.sha256(of: url)) { return existing }
        let year = startYear.map { UKTaxYear(startYear: $0) }
        let nameDate = year.map { UKTaxYear.utcCalendar.date(from: DateComponents(year: $0.startYear + 1, month: 1, day: 1))! } ?? now
        let detail = [employer, year?.label].compactMap { $0 }.joined(separator: " ")
        let name = EvidenceNaming.canonicalName(date: nameDate, precision: .year, area: "Tax", type: form.displayName, detail: detail.isEmpty ? nil : detail)
        let metadata = EvidenceMetadata(kind: form.documentKind, docDate: form == .p45 ? extraction.leavingDate : nil,
                                        periodStart: year?.start, periodEnd: year?.lastDay,
                                        persons: person.map { [$0.name] } ?? [], canonicalName: name, note: "Tax archive import")
        return try library.addAnalyzing(url, metadata: metadata, now: now).document
    }

    // MARK: Workpapers and links

    /// An accountant's template or workbook in the library (or the document already holding
    /// it): filed for the person and year its name and folder say, never read. Outside any transaction.
    static func addWorkpaper(library: EvidenceLibrary, url: URL, person: Person?, startYear: Int?, now: Date) throws -> (EvidenceDocument, isNew: Bool) {
        if let existing = try library.document(sha256: try EvidenceLibrary.sha256(of: url)) { return (existing, false) }
        let year = startYear.map { UKTaxYear(startYear: $0) }
        let nameDate = year.map { UKTaxYear.utcCalendar.date(from: DateComponents(year: $0.startYear + 1, month: 1, day: 1))! }
            ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now)
        let detail = [person?.name, year?.label].compactMap { $0 }.joined(separator: " ")
        let name = EvidenceNaming.canonicalName(date: nameDate, precision: year == nil ? .day : .year, area: "Tax UK", type: "Accountant workpaper",
                                                detail: detail.isEmpty ? url.deletingPathExtension().lastPathComponent : detail)
        let metadata = EvidenceMetadata(kind: .other, periodStart: year?.start, periodEnd: year?.lastDay,
                                        persons: person.map { [$0.name] } ?? [], canonicalName: name,
                                        note: "Accountant's workpaper (\(url.lastPathComponent)); tax archive import")
        let result = try library.add(url, metadata: metadata, now: now)
        return (result.document, result.isNew)
    }

    /// Links the document to the person's tax year record when there is one (else to the person).
    static func linkToYear(db: Database, documentId: Int64, person: Person?, startYear: Int?, role: String?) throws {
        guard let person, let personId = person.id else { return }
        if let startYear, let year = try TaxYears.year(db: db, startYear: startYear, personId: personId), let yearId = year.id {
            try EvidenceLinks.link(db: db, documentId: documentId, to: EvidenceEntity(type: .taxYear, id: yearId), role: role)
        } else {
            try EvidenceLinks.link(db: db, documentId: documentId, to: EvidenceEntity(type: .person, id: personId), role: role)
        }
    }

    /// UK tax documents the importer filed (returns, SA302s, HMRC letters and proofs, forms):
    /// linked to the tax year of the person their text or path names. The year comes from the
    /// document's text ("Calculation Result for 2023-24", "6 April 2025 to 5 April 2026", "Tax
    /// year to 5 April 2022") or else from the folder ("SA 2023:24").
    static func linkTaxDocuments(db: Database, documentIds: [Int64], people: [Person], relativePaths: [Int64: String]) throws {
        for id in Set(documentIds) {
            guard var document = try EvidenceDocument.fetchOne(db, key: id), EvidenceAnalyzer.ukKinds.contains(document.kind) else { continue }
            let links = try EvidenceLinks.links(db: db, for: id)
            if links.contains(where: { $0.entityType == .taxYear }) { continue }
            let path = relativePaths[id] ?? document.originalFileName
            let person = personMatching(text: document.extractedText, people: people) ?? personNamed(in: path, people: people)
                ?? document.persons.compactMap({ name in people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }).first
            let year = startYear(inText: document.extractedText) ?? startYear(inPath: path)
            if let person, !document.persons.contains(person.name) {
                document.persons.append(person.name)
                try document.update(db)
            }
            try linkToYear(db: db, documentId: id, person: person, startYear: year, role: document.kind.displayName)
        }
    }

    // MARK: The importer

    static func importThroughPipeline(pipeline: ImportPipeline, dbQueue: DatabaseQueue, library: EvidenceLibrary, urls: [URL],
                                      relative: (URL) -> String, entryPoint: String, now: Date) async throws -> [FileOutcome] {
        var plan = try await pipeline.plan(urls)
        var outcomes: [FileOutcome] = []
        func path(_ item: ImportItem) -> String { relative(item.file.url) }
        for item in plan.items(in: .needsYou) {
            outcomes.append(FileOutcome(relativePath: path(item), kind: .needsYou, detail: "\(item.title) (\(item.recognition.kind.displayName)): left for the review in the app",
                                        reasons: item.needsYouReasons))
        }
        for item in plan.items(in: .duplicates) {
            outcomes.append(FileOutcome(relativePath: path(item), kind: .duplicate, detail: "\(item.title): \(item.duplicate?.of ?? "duplicate")",
                                        documentId: item.duplicate?.existingDocumentId))
        }
        ImportRehearsal.leaveOutNeedsYou(&plan)
        var attempt = 0
        var applyNote: String?
        while plan.canConfirm {
            do {
                let summary = try ImportApplier(dbQueue: dbQueue, databasePath: nil, library: library).apply(plan, entryPoint: entryPoint, reasons: plan.resolutionReasons, now: now)
                applyNote = summary.text
                break
            } catch ImportApplyError.filedYearChanged(let impacts) where attempt < 5 {
                attempt += 1
                plan = try await pipeline.recheckFiledYears(plan)
                for item in plan.items(in: .needsYou) {
                    outcomes.append(FileOutcome(relativePath: path(item), kind: .needsYou, detail: "\(item.title): held back, a filed return would move",
                                                reasons: item.needsYouReasons))
                }
                if plan.items(in: .needsYou).isEmpty {
                    applyNote = "nothing applied: the filed-return backstop refused the batch (" + impacts.map(\.headline).joined(separator: "; ") + ")"
                    break
                }
                ImportRehearsal.leaveOutNeedsYou(&plan)
            }
        }
        let applied = applyNote.map { $0.hasPrefix("nothing") ? [] : ImportApplier.appliedItems(plan) } ?? []
        let appliedIds = Set(applied.map(\.id))
        let shaById = try await dbQueue.read { db -> [String: Int64] in
            var ids: [String: Int64] = [:]
            for sha in Set(applied.map(\.file.sha256)) {
                if let document = try EvidenceDocument.filter(Column("sha256") == sha).fetchOne(db) { ids[sha] = document.id }
            }
            return ids
        }
        for item in plan.items where item.section == .ready {
            if appliedIds.contains(item.id) {
                let linked = item.links.filter { $0.confidence == .certain }.map(\.label)
                outcomes.append(FileOutcome(relativePath: path(item), kind: .filed,
                                            detail: "\(item.title) (\(item.recognition.kind.displayName))" + (linked.isEmpty ? "" : " → " + linked.joined(separator: ", ")),
                                            documentId: shaById[item.file.sha256]))
            } else if item.parentId == nil {
                outcomes.append(FileOutcome(relativePath: path(item), kind: .failed, detail: "\(item.title): ready but not applied (\(applyNote ?? "no Ready item"))"))
            }
        }
        return outcomes
    }

    // MARK: Telling the person and the year

    /// The person every word of whose name (or short name) is a word of the path, diacritics
    /// and case aside; a name of one letter alone never counts. Two people named: nobody's.
    static func personNamed(in path: String, people: [Person]) -> Person? {
        let folded = path.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var found: Person?
        for person in people {
            for candidate in [person.name, person.shortName].compactMap({ $0 }) {
                let name = candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                guard !nameWords.isEmpty, nameWords.contains(where: { $0.count >= 2 }), nameWords.allSatisfy(words.contains) else { continue }
                if let found, found.id != person.id { return nil }
                found = person
            }
        }
        return found
    }

    /// The person whose National Insurance number or UTR the text shows.
    static func personMatching(text: String?, people: [Person]) -> Person? {
        guard let text, !text.isEmpty else { return nil }
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        var found: Person?
        for person in people {
            let keys = [person.ukNino, person.ukUtr].compactMap { $0 }.map { $0.uppercased().filter { $0.isLetter || $0.isNumber } }.filter { $0.count >= 8 }
            guard keys.contains(where: { compact.contains($0) }) else { continue }
            if let found, found.id != person.id { return nil }
            found = person
        }
        return found
    }

    /// The UK tax year a folder or file name carries: "SA 2022:23", "SA 2022-23", "2022/23",
    /// "2022-23", "SA_23.24", "P60-2016-17" → 2022 / 2023 / 2016; "P60_2025", "P60-2021-22" → by
    /// the end year when only one year is named with a form.
    static func startYear(inPath path: String) -> Int? {
        let patterns = [#"(20\d\d)\s*[:/\-\.]\s*(\d\d)(?!\d)"#, #"(?<!\d)(\d\d)\s*[\.\-/]\s*(\d\d)(?!\d)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: path, range: NSRange(path.startIndex..., in: path)) {
                guard let a = Range(match.range(at: 1), in: path), let b = Range(match.range(at: 2), in: path),
                      var start = Int(path[a]), let end = Int(path[b]) else { continue }
                if start < 100 { start += 2000 }
                guard (start + 1) % 100 == end, (2000...2099).contains(start) else { continue }
                return start
            }
        }
        return nil
    }

    /// The UK tax year the document's text names.
    static func startYear(inText text: String?) -> Int? {
        guard let text else { return nil }
        let patterns = [
            #"(?:Calculation Result for|Tax year|tax year|year ended?|Expenses and benefits|for the year)\s*(?:to|:)?\s*(?:5 April\s*)?(20\d\d)\s*(?:-|–|to|/)\s*(?:20)?(\d\d)"#,
            #"6 April (20\d\d) to 5 April (20\d\d)"#,
            #"(?:Tax year to|year ended|year to|year ending)\s*(?:0?5(?:th)? April|April)\s*(20\d\d)"#,
            #"(20\d\d)\s*-\s*(\d\d)\s*Tax (?:code|year)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            guard let a = Range(match.range(at: 1), in: text), let first = Int(text[a]) else { continue }
            if match.numberOfRanges > 2, let b = Range(match.range(at: 2), in: text), let second = Int(text[b]) {
                let end = second < 100 ? second : second % 100
                if (first + 1) % 100 == end { return first }
                continue
            }
            // "Tax year to 5 April 2022": the year ending in 2022 starts in 2021.
            return first - 1
        }
        return nil
    }

    // MARK: The guard

    /// Filed Self Assessment returns (2020/21 on) are compared to the penny whatever the settings
    /// say; only the disclosure years before them may carry a tolerance (at most £1).
    static func tolerance(_ year: SelfAssessmentRegression.Settings.PersonYear) -> Int {
        year.startYear >= 2020 ? 1 : min(max(year.tolerancePence ?? 1, 1), 100)
    }

    /// Every filed figure of the settings against the app's figure now (and `before`, when given).
    static func guardRows(dbQueue: DatabaseQueue, settings: SelfAssessmentRegression.Settings?, before: [GuardRow]?) async throws -> [GuardRow] {
        guard let settings else { return [] }
        return try await dbQueue.read { db in
            var rows: [GuardRow] = []
            for year in settings.personYears {
                guard let person = try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [year.person]).fetchOne(db) else { continue }
                let result = try? SelfAssessment.compute(db: db, startYear: year.startYear, personId: person.id!)
                for field in SelfAssessmentRegression.fields {
                    guard let text = year.filed[field.key], let filed = Money.parseMinorUnits(text) else { continue }
                    let app = result.flatMap { SelfAssessmentRegression.appValue(field.key, result: $0) }
                    let earlier = before?.first { $0.person == person.name && $0.startYear == year.startYear && $0.label == field.label }
                    rows.append(GuardRow(person: person.name, startYear: year.startYear, label: field.label, filed: filed,
                                         before: before == nil ? app : earlier?.after, after: app, tolerance: tolerance(year)))
                }
            }
            return rows
        }
    }

    // MARK: Report

    static func reportText(outcomes: [FileOutcome], planNotes: [String], impacts: [FiledYearImpact], rows: [GuardRow], refusals: [String], folder: URL) -> String {
        var out = "# Tax archive import · \(folder.lastPathComponent)\n\n"
        func count(_ kind: FileOutcome.Kind) -> Int { outcomes.filter { $0.kind == kind }.count }
        out += "Files: \(outcomes.count) · recorded \(count(.recorded)) · linked to existing records \(count(.linkedToExisting)) · filed \(count(.filed))"
        out += " · duplicates \(count(.duplicate)) · needs you \(count(.needsYou)) · skipped \(count(.skipped)) · failed \(count(.failed))\n\n"
        let stillDiffer = rows.filter { !$0.matchesFiled }
        if refusals.isEmpty {
            out += stillDiffer.isEmpty
                ? "**Filed years: every compared figure equals the return as filed.**\n\n"
                : "**Filed years: no figure moved away from the return; \(stillDiffer.count) of \(rows.count) still differ from it (marked ~ below, as before the run or nearer the return).**\n\n"
        } else {
            out += "**REFUSED: \(refusals.count) filed figure\(refusals.count == 1 ? "" : "s") would end up neither as filed nor as before:**\n"
            for line in refusals { out += "- \(line)\n" }
            out += "\n"
        }
        if !planNotes.isEmpty {
            out += "## Plan\n"
            for line in planNotes { out += line + "\n" }
            out += "\n"
        }
        out += "## Filed figures (filed · before · after)\n"
        let groups = Dictionary(grouping: rows) { "\($0.startYear)|\($0.person)" }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let matched = group.filter(\.matchesFiled).count
            out += "\n### \(UKTaxYear(startYear: group[0].startYear).label) · \(group[0].person): \(matched) of \(group.count) equal the return\n"
            for row in group {
                let mark = row.matchesFiled ? "=" : (row.ok ? "~" : "!")
                out += "\(mark) \(row.label): \(money(row.filed)) · \(money(row.before)) · \(money(row.after))\n"
            }
        }
        out += "\n## Filed or paid years whose figures moved\n"
        if impacts.isEmpty { out += "none\n" }
        for impact in impacts {
            out += "- \(impact.headline)\n"
            for line in impact.explanation { out += "    \(line)\n" }
        }
        let order: [FileOutcome.Kind] = [.recorded, .linkedToExisting, .needsYou, .failed, .filed, .duplicate, .skipped]
        let titles: [FileOutcome.Kind: String] = [.recorded: "Recorded (employment, pay, benefits)", .linkedToExisting: "Linked to records the year already had",
                                                  .needsYou: "Needs you (import these from the app's review)", .failed: "Failed", .filed: "Filed",
                                                  .duplicate: "Duplicates (already in the library)", .skipped: "Skipped"]
        for kind in order {
            let items = outcomes.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            out += "\n## \(titles[kind]!) (\(items.count))\n"
            for item in items.sorted(by: { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }) {
                out += "- `\(item.relativePath)` — \(item.detail)\n"
                for reason in item.reasons { out += "    - \(reason)\n" }
            }
        }
        return out
    }
}
