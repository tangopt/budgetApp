import Foundation
import GRDB

/// Where a statement shortcut sits: the Dashboard's or the Accounts screen's import buttons.
public enum StatementOrigin: String, Sendable {
    case dashboard, accounts
}

/// Where an "add a document to this record" shortcut sits.
public enum AttachOrigin: String, Sendable {
    case property, manualItem, missingEvidence, transaction, linkPicker
    /// A record sheet on a tax year's Income tab (employment, income, pension, HMRC payment).
    case incomeRecord
    /// An HMRC payment's sheet opened from a tax year's Tax return tab.
    case taxReturn
}

/// Every import button in the app is a shortcut into the one importer: it only pre-sets what the
/// files are expected to be, the property, person, account or tax year, or the record they are
/// added to (`intent`). It never skips the review: nothing is written before Confirm import, and a
/// file that contradicts the shortcut is a `kindMismatch` Needs-you item. `entryPoint` is the
/// name recorded on the run and shown in Import history.
public enum ImportShortcut: Equatable, Sendable {
    case statement(accountId: Int64, format: ImportFormat, from: StatementOrigin)
    case editColumnMapping(accountId: Int64)
    case rentReceiptsExport(propertyId: Int64)
    /// A rent receipt's PDF, added or (with `replacing`, the documents now linked) replaced.
    case receiptPDF(receiptId: Int64, replacing: [Int64])
    case tenancyContract(tenancyId: Int64)
    case utilityInvoices(propertyId: Int64)
    /// The Documents screen's Add documents… (`dropped`: files dropped on it).
    case documents(dropped: Bool)
    /// A source folder's new and changed files (they carry the folder's metadata).
    case sourceFolder(folderId: Int64, name: String)
    case payrollForms(personId: Int64?, taxYear: Int?)
    /// A document for a record. `expected`: the document kind the record asks for (Missing
    /// evidence ▸ Add: the item's kind), matched by library kind whichever reader reads the file
    /// (`ImportIntent.expectedByDocumentKind`); nil: any file. `period`: the slot the record asks
    /// a document for (`[start, end)`), given to a document that has no period of its own.
    case attach(EvidenceEntity, role: String?, from: AttachOrigin, expected: DocumentKindRef? = nil, period: DateInterval? = nil)

    /// What the shortcut pre-sets, with its entry point.
    public var intent: ImportIntent {
        var intent: ImportIntent
        switch self {
        case .statement(let accountId, let format, _):
            intent = ImportIntent(expected: format == .pdf ? .bankStatementPDF : .bankStatementCSV, accountId: accountId)
        case .editColumnMapping(let accountId):
            intent = ImportIntent(expected: .bankStatementCSV, accountId: accountId, remapStatement: true)
        case .rentReceiptsExport(let propertyId):
            intent = ImportIntent(expected: .rentReceiptsExport, propertyId: propertyId)
        case .receiptPDF(let receiptId, let replacing):
            intent = ImportIntent(expected: .rentReceiptPDF,
                                  target: .init(entity: .rentReceipt(receiptId), role: "Receipt", replacing: replacing))
        case .tenancyContract(let tenancyId):
            intent = ImportIntent(expected: .evidence(.rentContract), target: .init(entity: .tenancy(tenancyId), role: "Contract"))
        case .utilityInvoices(let propertyId):
            intent = ImportIntent(expected: .utilityInvoice, propertyId: propertyId)
        case .documents, .sourceFolder:
            intent = ImportIntent()
        case .payrollForms(let personId, let taxYear):
            // Any payroll form matches the expected P60 (`ImportDetector.intentIssue`): P45 and P11D too.
            intent = ImportIntent(expected: .payrollForm(.p60), personId: personId, taxYear: taxYear)
        case .attach(let entity, let role, _, let expected, let period):
            intent = ImportIntent(target: .init(entity: entity, role: role))
            intent.period = period
            switch expected {
            case .builtIn(let kind)?:
                intent.expected = .evidence(kind)
                intent.expectedByDocumentKind = true
            case .custom(let id)?:
                // A custom kind is matched as itself.
                intent.expected = .customEvidence(.saved(id))
            case nil:
                break
            }
        }
        intent.entryPoint = entryPoint
        return intent
    }

    /// The button's place and title, as recorded on the run: "Dashboard ▸ Import CSV…",
    /// "Dashboard ▸ Import PDF…", "Accounts ▸ Import CSV…", "Accounts ▸ Import PDF…",
    /// "Accounts ▸ Edit column mapping…", "Tenancies ▸ Import receipts…", "Receipt ▸ Add PDF…",
    /// "Receipt ▸ Replace PDF…", "Tenancy ▸ Add contract…", "Utility invoices…",
    /// "Documents ▸ Add documents…", "Documents ▸ Drop", "Source folder ▸ <folder name>",
    /// "Income ▸ Import P60, P45 or P11D…", "Property ▸ Add document…", "Manual item ▸ Add document…",
    /// "Missing evidence ▸ Add", "Transaction ▸ Add document", "Link document ▸ Add file…",
    /// "Income ▸ Add document…", "Tax return ▸ Add document…".
    public var entryPoint: String {
        switch self {
        case .statement(_, let format, let origin):
            let screen = origin == .dashboard ? "Dashboard" : "Accounts"
            return "\(screen) ▸ Import \(format == .pdf ? "PDF" : "CSV")…"
        case .editColumnMapping: return "Accounts ▸ Edit column mapping…"
        case .rentReceiptsExport: return "Tenancies ▸ Import receipts…"
        case .receiptPDF(_, let replacing): return replacing.isEmpty ? "Receipt ▸ Add PDF…" : "Receipt ▸ Replace PDF…"
        case .tenancyContract: return "Tenancy ▸ Add contract…"
        case .utilityInvoices: return "Utility invoices…"
        case .documents(let dropped): return dropped ? "Documents ▸ Drop" : "Documents ▸ Add documents…"
        case .sourceFolder(_, let name): return "Source folder ▸ \(name)"
        case .payrollForms: return "Income ▸ Import P60, P45 or P11D…"
        case .attach(_, _, let origin, _, _):
            switch origin {
            case .property: return "Property ▸ Add document…"
            case .manualItem: return "Manual item ▸ Add document…"
            case .missingEvidence: return "Missing evidence ▸ Add"
            case .transaction: return "Transaction ▸ Add document"
            case .linkPicker: return "Link document ▸ Add file…"
            case .incomeRecord: return "Income ▸ Add document…"
            case .taxReturn: return "Tax return ▸ Add document…"
            }
        }
    }

    /// The library's documents the shortcut brings into the review besides the files chosen:
    /// for Utility invoices…, the property's documents that read as its utility invoices and
    /// aren't recorded yet (`UtilityInvoiceIntake.pendingDocuments`, oldest first) — read again
    /// re-using their document ("From library"). None for the other shortcuts.
    public func libraryDocumentIds(db: Database) throws -> [Int64] {
        guard case .utilityInvoices(let propertyId) = self else { return [] }
        return try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: propertyId).compactMap(\.id)
    }

    /// Whether the shortcut can bring library documents (`libraryDocumentIds`): its button is a
    /// menu, "Choose files…" and "From library (N)".
    public var offersLibrary: Bool {
        if case .utilityInvoices = self { return true }
        return false
    }

    /// The open panel's file types (UTType identifiers); none for a source folder (scanned, not picked).
    public var allowedContentTypes: [String] {
        switch self {
        case .statement(_, let format, _): return format == .pdf ? [Self.pdf] : [Self.csv]
        case .editColumnMapping: return [Self.csv]
        case .rentReceiptsExport: return ["org.openxmlformats.spreadsheetml.sheet"]
        case .payrollForms: return [Self.pdf, "public.image"]
        case .sourceFolder: return []
        case .receiptPDF, .tenancyContract, .utilityInvoices, .documents, .attach: return [Self.pdf, "public.image", "public.data"]
        }
    }

    /// Whether the open panel takes several files: not for a replacement, a mapping set up from
    /// one statement, or the one receipts export.
    public var allowsMultiple: Bool {
        switch self {
        case .receiptPDF(_, let replacing): return replacing.isEmpty
        case .editColumnMapping, .rentReceiptsExport: return false
        default: return true
        }
    }

    /// Whether the open panel also takes folders: only the Documents screen's Add documents….
    public var allowsFolders: Bool {
        if case .documents = self { return true }
        return false
    }

    private static let pdf = "com.adobe.pdf"
    private static let csv = "public.comma-separated-values-text"
}
