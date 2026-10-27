import Foundation

/// What one table sends to the cloud (sync spec §4.1). Record type = table name.
public struct SyncTableSchema: Equatable, Sendable {
    public let name: String
    /// The local primary key, which never syncs as a value (the record's UUID stands for it). It is
    /// `id` everywhere except `propertyMortgageTerms`, whose key is its `propertyId` foreign key, so
    /// there it also appears in `syncedColumns` and `foreignKeys`.
    public let localIdColumn: String
    public let syncedColumns: [String]
    /// Column to referenced table, exactly the database's declared foreign keys on synced columns.
    /// They travel as the parent's UUID and come back as that device's local id.
    public let foreignKeys: [String: String]
    /// Columns that mean something only on this device and never leave it.
    public let localOnlyColumns: [String]
    /// The column naming the import batch a row belongs to, directly (`importRunId`, `runId`) or through
    /// its import batch (`transaction_.importBatchId`); nil where the table stores none.
    public let batchKey: String?

    public init(_ name: String, localIdColumn: String = "id", synced: [String], foreignKeys: [String: String] = [:],
                localOnly: [String] = [], batchKey: String? = nil) {
        self.name = name
        self.localIdColumn = localIdColumn
        self.syncedColumns = synced
        self.foreignKeys = foreignKeys
        self.localOnlyColumns = localOnly
        self.batchKey = batchKey
    }
}

/// Every table and column, classified as synced or local-only. `SyncSchemaTests` fails, naming the column,
/// when a migration adds a table or column that isn't listed here.
///
/// Rulings that aren't obvious (the full list is in the step 3 task 1 report):
/// - `appUser.lastSignInAt` is local-only: it records a sign-in on this device.
/// - `importRun.backupPath` is local-only: a path to a backup file on this Mac.
/// - `document.sourceFolderId`, `sourceRelativePath`, `sourceModifiedAt` are local-only: they locate the
///   file in a linked folder on this Mac. `document.storedRelativePath` syncs: it is derived from the
///   hash inside the app's library, the same on every device.
/// - `importRunFile` syncs: it holds file names (last path component) and hashes, no paths.
/// - `importChange` syncs with its run: undo is a batch and uses the change log (sync spec §5.2).
/// - `account.statementLastCheckedDate` and the statement-mismatch columns sync: they describe statements,
///   which are household data, not this device.
/// - `document.extractedText` is local-only (ruling R4): it is re-derived from the document's file on each
///   device, and it would push records past CloudKit's size limit.
public enum SyncSchema {
    /// Bumped whenever `tables` or the tracking triggers change (`SyncChangeTrackerTests` pins the hash of
    /// each version). A build never replaces triggers a newer version installed.
    public static let version = 9

    /// Synced tables, parents before children (each foreign key's table is listed earlier).
    public static let tables: [SyncTableSchema] = [
        SyncTableSchema("person",
                        synced: ["name", "shortName", "ukUtr", "ukNino", "ptNif", "notes"]),
        SyncTableSchema("appUser",
                        synced: ["personId", "displayName", "cloudKitUserRecordName", "isAdmin", "createdAt"],
                        foreignKeys: ["personId": "person"],
                        localOnly: ["lastSignInAt"]),
        SyncTableSchema("personSharing",
                        synced: ["personId", "taxIncomeLevel", "ownershipConfirmedAt"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("memberPermission",
                        synced: ["appUserId", "area", "level"],
                        foreignKeys: ["appUserId": "appUser"]),
        SyncTableSchema("account",
                        synced: ["name", "currency", "kind", "trackingMode", "alias", "sortCode", "accountNumber", "iban", "sortOrder", "statementMismatchMinorUnits", "statementMismatchDate", "statementMismatchClosingMinorUnits", "statementLastCheckedDate", "balanceConfirmedAt", "bankRegion", "bankName", "routingNumber", "bic", "isMain", "includeInNetWorth", "ownerPersonId", "sharingLevel"],
                        foreignKeys: ["ownerPersonId": "person"]),
        SyncTableSchema("categoryGroup",
                        synced: ["name", "type"]),
        SyncTableSchema("category",
                        synced: ["name", "type", "groupId", "isReserved", "excludeFromAutoForecast", "isExternalTransfer", "iconName", "builtInRole", "transferAccountId"],
                        foreignKeys: ["transferAccountId": "account"]),
        // Summaries of accounts below Everything (sharing spec 2026-10-25 §3), rebuilt by the owner's devices.
        SyncTableSchema("accountBalancePoint",
                        synced: ["accountId", "payMonth", "date", "balanceMinorUnits"],
                        foreignKeys: ["accountId": "account"]),
        SyncTableSchema("accountSummaryMonth",
                        synced: ["accountId", "payMonth", "categoryId", "amountMinorUnits", "gbpAmountMinorUnits", "transactionCount"],
                        foreignKeys: ["accountId": "account", "categoryId": "category"]),
        SyncTableSchema("importRun",
                        synced: ["confirmedAt", "entryPoint", "summary", "reasonsJSON", "undoneAt", "undoSummary", "appUserId"],
                        foreignKeys: ["appUserId": "appUser"],
                        localOnly: ["backupPath"]),
        // Files kept for later (spec 2026-10-24 §1): the household's list; each device reads the text
        // and suggests on its own.
        SyncTableSchema("importWaitingFile",
                        synced: ["sha256", "originalFileName", "byteCount", "storedRelativePath", "reason", "recognisedAs", "keptAt", "importedRunId",
                                 "keptByAppUserId"],
                        foreignKeys: ["importedRunId": "importRun", "keptByAppUserId": "appUser"],
                        localOnly: ["text", "textStatus", "suggestion", "checkedSignature"]),
        SyncTableSchema("importBatch",
                        synced: ["accountId", "sourceFileName", "importedAt", "importRunId"],
                        foreignKeys: ["importRunId": "importRun", "accountId": "account"],
                        batchKey: "importRunId"),
        SyncTableSchema("importChange",
                        synced: ["runId", "seq", "tableName", "rowId", "operation", "beforeJSON", "afterJSON", "rowUuid"],
                        foreignKeys: ["runId": "importRun"],
                        batchKey: "runId"),
        SyncTableSchema("customDocumentKind",
                        synced: ["name", "area", "createdAt", "mergedIntoKind"]),
        SyncTableSchema("document",
                        synced: ["sha256", "storedRelativePath", "originalFileName", "byteCount", "canonicalName", "kind", "docDate", "periodStart", "periodEnd", "amountMinorUnits", "currency", "persons", "textStatus", "addedAt", "note", "customKindId"],
                        foreignKeys: ["customKindId": "customDocumentKind"],
                        localOnly: ["sourceFolderId", "sourceRelativePath", "sourceModifiedAt", "extractedText"]),
        SyncTableSchema("importRunFile",
                        synced: ["runId", "fileName", "sha256", "documentId", "outcome", "detail"],
                        foreignKeys: ["runId": "importRun"],
                        batchKey: "runId"),
        SyncTableSchema("importProfile",
                        synced: ["accountId", "format", "csvDelimiter", "csvDateColumnIndex", "csvDescriptionColumnIndex", "csvAmountColumnIndex", "csvDateFormat", "pdfLayoutConfig", "csvCreditAmountColumnIndex", "csvBalanceColumnIndex", "csvNegateAmounts", "csvFeeColumnIndex", "csvStatusColumnIndex", "csvSortCodeColumnIndex", "csvAccountNumberColumnIndex"],
                        foreignKeys: ["accountId": "account"]),
        SyncTableSchema("importRule",
                        synced: ["kind", "matchKey", "matchLabel", "actionJSON", "actionLabel", "isEnabled", "createdAt", "lastUsedAt", "useCount", "createdByAppUserId", "lastLearntByAppUserId"],
                        foreignKeys: ["lastLearntByAppUserId": "appUser", "createdByAppUserId": "appUser"]),
        SyncTableSchema("transaction_",
                        synced: ["importBatchId", "accountId", "date", "rawDescription", "amountMinorUnits", "categoryId", "status", "categorizedBy", "fingerprint", "note", "isManual"],
                        foreignKeys: ["categoryId": "category", "accountId": "account", "importBatchId": "importBatch"],
                        batchKey: "importBatchId"),
        SyncTableSchema("transferLink",
                        synced: ["outTransactionId", "inTransactionId", "origin", "isDismissed"],
                        foreignKeys: ["inTransactionId": "transaction_", "outTransactionId": "transaction_"]),
        SyncTableSchema("rule",
                        synced: ["matchPattern", "matchType", "categoryId", "priority"],
                        foreignKeys: ["categoryId": "category"]),
        SyncTableSchema("payPeriod",
                        synced: ["startDate", "endDate", "type"]),
        SyncTableSchema("payMonthClose",
                        synced: ["year", "month", "closeDate"]),
        SyncTableSchema("scenario",
                        synced: ["name", "createdAt", "refreshedAt"]),
        SyncTableSchema("forecastGroup",
                        synced: ["name", "note", "isEnabled", "isSystemManaged"]),
        SyncTableSchema("forecastEntry",
                        synced: ["groupId", "categoryId", "amountMinorUnits", "frequency", "interval", "startDate", "endDate", "isEnabled", "status", "note", "anchorDay", "scenarioId", "sourceEntryId", "scenarioChange", "accountId"],
                        foreignKeys: ["accountId": "account", "scenarioId": "scenario", "categoryId": "category", "groupId": "forecastGroup"]),
        SyncTableSchema("plannedOccurrenceException",
                        synced: ["entryId", "originalDate", "isSkipped", "amountMinorUnits", "date", "categoryId"],
                        foreignKeys: ["categoryId": "category", "entryId": "forecastEntry"]),
        SyncTableSchema("scenarioApplication",
                        synced: ["scenarioId", "appliedAt", "undoneAt", "journal"],
                        foreignKeys: ["scenarioId": "scenario"]),
        SyncTableSchema("balanceSnapshot",
                        synced: ["accountId", "date", "balanceMinorUnits", "note"],
                        foreignKeys: ["accountId": "account"]),
        SyncTableSchema("balanceSnapshotArchive",
                        synced: ["accountId", "date", "balanceMinorUnits", "note", "archivedAt"],
                        foreignKeys: ["accountId": "account"]),
        SyncTableSchema("exchangeRateSetting",
                        synced: ["eurToGbpRate", "updatedAt"]),
        SyncTableSchema("documentLink",
                        synced: ["documentId", "entityType", "entityId", "role", "createdAt"],
                        foreignKeys: ["documentId": "document"]),
        SyncTableSchema("evidenceRequirement",
                        synced: ["name", "scope", "kinds", "direction", "excludedAccountIds", "usualSource", "activeFrom", "activeTo", "notes", "createdAt", "customKindIds"]),
        SyncTableSchema("evidenceWaiver",
                        synced: ["requirementId", "entityType", "entityId", "slotStart", "reason", "note", "createdAt"],
                        foreignKeys: ["requirementId": "evidenceRequirement"]),
        SyncTableSchema("property",
                        synced: ["name", "country", "currency", "matrixArticle", "purchasePriceMinorUnits", "purchaseDate", "notes",
                                 "address", "postcode", "city", "latitude", "longitude", "locationSource"]),
        SyncTableSchema("propertyAccount",
                        synced: ["propertyId", "accountId", "role"],
                        foreignKeys: ["accountId": "account", "propertyId": "property"]),
        SyncTableSchema("propertyCategoryGroup",
                        synced: ["propertyId", "categoryGroupId"],
                        foreignKeys: ["categoryGroupId": "categoryGroup", "propertyId": "property"]),
        SyncTableSchema("propertyMortgageTerms",
                        localIdColumn: "propertyId",
                        synced: ["propertyId", "revisionMonths", "rateNote", "finalInstalmentDate", "balloonMinorUnits", "annualRatePercent", "rateIndex", "spreadPercent", "fixingConvention", "fixingBusinessDays", "dayCount", "totalInstalments", "firstInstalmentDate", "indexDecimals", "interestRounding", "amountBorrowedMinorUnits"],
                        foreignKeys: ["propertyId": "property"]),
        SyncTableSchema("propertyOwner",
                        synced: ["propertyId", "personId", "shareBasisPoints", "fromDate", "toDate"],
                        foreignKeys: ["personId": "person", "propertyId": "property"]),
        SyncTableSchema("mortgageRateOverride",
                        synced: ["propertyId", "periodStart", "ratePercent", "note"],
                        foreignKeys: ["propertyId": "property"]),
        SyncTableSchema("interestIndexValue",
                        synced: ["indexName", "period", "date", "valuePercent", "source", "fetchedAt"]),
        SyncTableSchema("propertyCheckDecision",
                        synced: ["propertyId", "categoryId", "accountId", "seriesKey", "lastSeenDate", "decision", "createdAt"],
                        foreignKeys: ["propertyId": "property", "categoryId": "category", "accountId": "account"]),
        SyncTableSchema("tenancy",
                        synced: ["propertyId", "referenceLabel", "contractNumber", "tenantName", "startDate", "endDate", "advanceRentMonths", "depositMonths", "notes", "tenantEmail"],
                        foreignKeys: ["propertyId": "property"]),
        SyncTableSchema("tenancyRent",
                        synced: ["tenancyId", "fromDate", "monthlyAmountMinorUnits"],
                        foreignKeys: ["tenancyId": "tenancy"]),
        SyncTableSchema("rentReceipt",
                        synced: ["tenancyId", "receiptNumber", "periodStart", "periodEnd", "receiptDate", "amountMinorUnits", "withholdingMinorUnits", "amountReceivedMinorUnits", "status"],
                        foreignKeys: ["tenancyId": "tenancy"]),
        SyncTableSchema("rentReceiptPayment",
                        synced: ["rentReceiptId", "transactionId", "rentMinorUnits", "otherMinorUnits", "origin", "isDismissed"],
                        foreignKeys: ["transactionId": "transaction_", "rentReceiptId": "rentReceipt"]),
        SyncTableSchema("utilityProvider",
                        synced: ["propertyId", "name", "kind", "accountReference", "bankDescriptionPattern", "notes", "invoiceRules"],
                        foreignKeys: ["propertyId": "property"]),
        SyncTableSchema("utilityInvoice",
                        synced: ["providerId", "invoiceNumber", "periodStart", "periodEnd", "issueDate", "amountMinorUnits", "documentId", "transactionId", "notes"],
                        foreignKeys: ["transactionId": "transaction_", "documentId": "document", "providerId": "utilityProvider"]),
        SyncTableSchema("rechargeStatement",
                        synced: ["tenancyId", "month", "totalMinorUnits", "status", "sentAt", "notes"],
                        foreignKeys: ["tenancyId": "tenancy"]),
        SyncTableSchema("rechargeLine",
                        synced: ["statementId", "invoiceId", "lineDescription", "amountMinorUnits", "note", "documentId", "daysInTenancy", "daysInPeriod", "isRounding", "transactionId"],
                        foreignKeys: ["transactionId": "transaction_", "documentId": "document", "invoiceId": "utilityInvoice", "statementId": "rechargeStatement"]),
        SyncTableSchema("rechargePayment",
                        synced: ["statementId", "transactionId", "amountMinorUnits", "origin", "isDismissed"],
                        foreignKeys: ["transactionId": "transaction_", "statementId": "rechargeStatement"]),
        SyncTableSchema("rechargeEmailTemplate",
                        synced: ["propertyId", "language", "subject", "body"],
                        foreignKeys: ["propertyId": "property"]),
        SyncTableSchema("rechargeNettingRule",
                        synced: ["startYear", "mode", "notes"]),
        SyncTableSchema("employment",
                        synced: ["startYear", "personId", "employerName", "payeReference", "startDate", "endDate", "notes"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("employmentIncome",
                        synced: ["employmentId", "source", "payMinorUnits", "taxDeductedMinorUnits", "taxCode", "periodEnd", "entryMethod", "notes"],
                        foreignKeys: ["employmentId": "employment"]),
        SyncTableSchema("benefitInKind",
                        synced: ["employmentId", "kind", "sa102Box", "description", "cashEquivalentMinorUnits", "entryMethod", "isFromP11DImport", "notes"],
                        foreignKeys: ["employmentId": "employment"]),
        SyncTableSchema("otherIncome",
                        synced: ["startYear", "personId", "kind", "payer", "amountMinorUnits", "taxDeductedMinorUnits", "currency", "date", "notes"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("pensionContribution",
                        synced: ["startYear", "personId", "kind", "provider", "paidMinorUnits", "date", "notes"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("hmrcPayment",
                        synced: ["personId", "startYear", "date", "amountMinorUnits", "kind", "reference", "notes"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("hmrcRate",
                        synced: ["startYear", "currencyCode", "gbpPerUnit", "unitsPerPound", "source", "fetchedAt", "notes"]),
        SyncTableSchema("taxYear",
                        synced: ["startYear", "personId", "status", "notes", "foreignTaxInPence"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("taxFiledBox",
                        synced: ["startYear", "personId", "field", "valueMinorUnits", "note"],
                        foreignKeys: ["personId": "person"]),
        SyncTableSchema("taxYearSplit",
                        synced: ["startYear", "personId", "propertyId", "expenseType", "shareBasisPoints"],
                        foreignKeys: ["propertyId": "property", "personId": "person"]),
        SyncTableSchema("taxAttributionRule",
                        synced: ["expenseType", "startYear", "rule", "defaultCoverMonths", "notes", "windowShiftMonths"]),
        SyncTableSchema("taxExpenseTypeMap",
                        synced: ["categoryId", "expenseType"],
                        foreignKeys: ["categoryId": "category"]),
        SyncTableSchema("taxManualItem",
                        synced: ["startYear", "personId", "propertyId", "expenseType", "label", "amountMinorUnits", "currency", "date", "isWholeProperty", "notes"],
                        foreignKeys: ["propertyId": "property", "personId": "person"]),
        SyncTableSchema("taxPolicyReceipt",
                        synced: ["propertyId", "expenseType", "transactionId", "date", "amountMinorUnits", "currency", "policyYear", "instalment", "instalmentCount", "coverStart", "coverEnd", "notes"],
                        foreignKeys: ["transactionId": "transaction_", "propertyId": "property"]),
        SyncTableSchema("taxNotClaimed",
                        synced: ["startYear", "transactionId", "manualItemId", "policyReceiptId", "notes"],
                        foreignKeys: ["policyReceiptId": "taxPolicyReceipt", "manualItemId": "taxManualItem", "transactionId": "transaction_"]),
        SyncTableSchema("taxTransactionOwner",
                        synced: ["transactionId", "personId", "notes"],
                        foreignKeys: ["personId": "person", "transactionId": "transaction_"]),
        // The iPad browser's saved sites (step 10 Task 6, schema 9): the household's, addresses only.
        SyncTableSchema("savedSite",
                        synced: ["name", "url", "kind", "sortOrder"]),
    ]

    /// Tables that record history, whose references may name rows that are gone (ruling R7): the import
    /// change log, which an Undo reads. A reference to a deleted row travels as the UUID the row had (its
    /// tombstone), and comes back as this device's deleted row, so an Undo anywhere re-inserts it under
    /// the same identity.
    public static let historyTables: Set<String> = ["importChange"]

    /// Never synced (sync spec §4.3, §11.6): sync bookkeeping, credentials and settings of this device,
    /// linked source folders and their files (paths and bookmarks), the automatic links undone here (`autoLinkDeclined`), and SQLite's and GRDB's own tables.
    public static let localOnlyTables: Set<String> = [
        "syncRecord", "syncStaging", "syncConflict", "syncTombstone", "syncState",
        "syncPending", "syncFieldClock", "syncWriter", "syncApplying", "syncBatch", "syncBatchMember",
        "localCredential", "localSetting",
        "autoLinkDeclined",
        "sourceFolder", "sourceFile",
        "syncZoneMove", "syncCompanion", "syncAccessRevert", "syncPresence", "syncZoneCleanup",
        "grdb_migrations", "sqlite_sequence",
    ]

    private static let byName: [String: SyncTableSchema] = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

    public static func table(_ name: String) -> SyncTableSchema? { byName[name] }
}

// MARK: References the database doesn't declare (ruling R1)

/// A pair of columns naming a row of one of several tables: the type column says which table, the id
/// column holds that table's local id (`documentLink.entityType` / `entityId`).
public struct SyncPolymorphicReference: Equatable, Sendable {
    /// What a type value that names no table means.
    public enum Unlisted: Equatable, Sendable {
        /// The id isn't a row id (`EvidenceEntityType.other`): it travels as it is.
        case passThrough(Set<String>)
        /// The row is in a table that doesn't sync (an import's change to `sourceFile`): it names no row
        /// on another device.
        case dangling
    }

    public let table: String
    public let typeColumn: String
    public let idColumn: String
    /// Type value to table.
    public let targets: [String: String]
    public let unlisted: Unlisted
}

/// One place inside a JSON value that names rows, as a path from the root: object keys separated by `.`,
/// `[]` for every element of an array (`operations[].created[].entryId`, or `[]` alone for a root array).
public struct SyncJSONRule: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// A number: a local id of the table.
        case row(String)
        /// An object `{"type": <EvidenceEntityType>, "id": <local id>}` (`EvidenceEntity`).
        case evidenceEntity
        /// A string: `ScenarioApply`'s fingerprint of a forecast entry, which embeds its group, category
        /// and account ids and its exceptions' category ids.
        case forecastFingerprint
    }

    public let path: String
    public let target: Target

    public init(_ path: String, _ target: Target) {
        self.path = path
        self.target = target
    }
}

/// A JSON column whose content names rows.
public struct SyncJSONReference: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// The places listed.
        case rules([SyncJSONRule])
        /// A whole row of the table named by `typeColumn` of the same row, as `ImportChangeCapture` records it
        /// (`importChange.beforeJSON` / `afterJSON`): every reference that table declares is translated.
        case rowOfTable(typeColumn: String)
    }

    public let table: String
    public let column: String
    public let content: Content
    /// Numbers in the known shapes that aren't row ids (dates, counts), so the guard test can tell a new
    /// id path from a known plain number.
    public let plainNumbers: Set<String>
}

extension SyncSchema {
    /// Columns holding another row's local id without a declared foreign key (`table.column` to the table).
    /// They travel as the row's UUID, like foreign keys.
    public static let logicalReferences: [String: String] = [
        "category.groupId": "categoryGroup",
        "forecastEntry.sourceEntryId": "forecastEntry",
        "importRunFile.documentId": "document",
    ]

    /// The table of each `EvidenceEntityType` that names a row (as `ImportUndo.entityTables`).
    public static let evidenceEntityTables: [String: String] = [
        "transaction": "transaction_", "account": "account", "category": "category", "property": "property",
        "person": "person", "tenancy": "tenancy", "rentReceipt": "rentReceipt", "taxYear": "taxYear",
        "taxManualItem": "taxManualItem", "employment": "employment", "employmentIncome": "employmentIncome",
        "hmrcPayment": "hmrcPayment", "otherIncome": "otherIncome", "pensionContribution": "pensionContribution",
        "taxPolicyReceipt": "taxPolicyReceipt",
    ]

    /// Evidence entity types whose id names no row.
    public static let evidenceEntityPassThrough: Set<String> = ["other"]

    public static let polymorphicReferences: [SyncPolymorphicReference] = [
        SyncPolymorphicReference(table: "documentLink", typeColumn: "entityType", idColumn: "entityId",
                                 targets: evidenceEntityTables, unlisted: .passThrough(evidenceEntityPassThrough)),
        SyncPolymorphicReference(table: "evidenceWaiver", typeColumn: "entityType", idColumn: "entityId",
                                 targets: evidenceEntityTables, unlisted: .passThrough(evidenceEntityPassThrough)),
        SyncPolymorphicReference(table: "importChange", typeColumn: "tableName", idColumn: "rowId",
                                 targets: Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.name) }), unlisted: .dangling),
    ]

    public static let jsonReferences: [SyncJSONReference] = [
        SyncJSONReference(table: "importChange", column: "beforeJSON", content: .rowOfTable(typeColumn: "tableName"), plainNumbers: []),
        SyncJSONReference(table: "importChange", column: "afterJSON", content: .rowOfTable(typeColumn: "tableName"), plainNumbers: []),
        SyncJSONReference(table: "evidenceRequirement", column: "excludedAccountIds", content: .rules([
            SyncJSONRule("[]", .row("account")),
        ]), plainNumbers: []),
        SyncJSONReference(table: "evidenceRequirement", column: "customKindIds", content: .rules([
            SyncJSONRule("[]", .row("customDocumentKind")),
        ]), plainNumbers: []),
        SyncJSONReference(table: "evidenceRequirement", column: "scope", content: .rules([
            SyncJSONRule("transactionsInCategory.categoryId", .row("category")),
            SyncJSONRule("transactionsInCategoryGroup.groupId", .row("categoryGroup")),
            SyncJSONRule("transactionsMatching.categoryIds[]", .row("category")),
            SyncJSONRule("transactionsMatching.accountIds[]", .row("account")),
            SyncJSONRule("periodic.entity", .evidenceEntity),
            SyncJSONRule("single.entity", .evidenceEntity),
            SyncJSONRule("recordsOfProperty.propertyId", .row("property")),
        ]), plainNumbers: []),
        SyncJSONReference(table: "importRule", column: "actionJSON", content: .rules([
            SyncJSONRule("accountId", .row("account")),
            SyncJSONRule("entity", .evidenceEntity),
            SyncJSONRule("customKindId", .row("customDocumentKind")),
            SyncJSONRule("sourceAccountId", .row("account")),
        ]), plainNumbers: ["occurrence"]),
        SyncJSONReference(table: "scenarioApplication", column: "journal", content: .rules([
            SyncJSONRule("operations[].differenceId", .row("forecastEntry")),
            SyncJSONRule("operations[].created[].entryId", .row("forecastEntry")),
            SyncJSONRule("operations[].created[].after", .forecastFingerprint),
            SyncJSONRule("operations[].modified[].entryId", .row("forecastEntry")),
            SyncJSONRule("operations[].modified[].after", .forecastFingerprint),
            SyncJSONRule("operations[].categoryIds[]", .row("category")),
            SyncJSONRule("enabledGroupIds[]", .row("forecastGroup")),
            SyncJSONRule("createdGroupIds[]", .row("forecastGroup")),
            SyncJSONRule("lastEntryId", .row("forecastEntry")),
        ]), plainNumbers: ["boundary", "operations[].modified[].before.endDate"]),
    ]

    /// JSON columns whose known shapes name no rows (`importRun.reasonsJSON` is keyed by plan item UUIDs).
    public static let jsonColumnsWithoutReferences: Set<String> = [
        "document.persons", "evidenceRequirement.kinds", "utilityProvider.invoiceRules",
        "importProfile.pdfLayoutConfig", "importRun.reasonsJSON",
    ]

    /// Every reference column of `table` that isn't a declared foreign key, column to target table.
    static func logicalReferences(of table: String) -> [String: String] {
        logicalByTable[table] ?? [:]
    }

    private static let logicalByTable: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for (key, target) in logicalReferences {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            result[parts[0], default: [:]][parts[1]] = target
        }
        return result
    }()

    static func polymorphicReferences(of table: String) -> [SyncPolymorphicReference] {
        polymorphicReferences.filter { $0.table == table }
    }

    static func jsonReferences(of table: String) -> [SyncJSONReference] {
        jsonReferences.filter { $0.table == table }
    }
}

// MARK: Unique keys (what two devices making "the same" row means)

/// What to do when an incoming record collides with another row on a unique key.
public enum SyncUniqueResolution: Equatable, Sendable {
    /// The key names one real thing (a built-in category, a file by its hash, one property's mortgage terms,
    /// a link between two records): the two records are the same record and merge.
    case identity
    /// Different records that happen to share a text: both are kept, and the one with the greater UUID (the
    /// same choice on every device) gets the column suffixed, " (2)".
    case suffix(String)
    /// A flag only one row may hold (`account.isMain`): the later setting of it wins, the other row's flag is
    /// cleared.
    case exclusiveFlag(String)
    /// Different records competing for a slot: the one with the greater UUID steps out by setting the column
    /// to the value (a second active transfer link is dismissed).
    case yield(String, SyncValue)
}

/// A unique key of a synced table, as `PRAGMA index_xinfo` lists its key columns (`<expr>` for an
/// expression), or the table's primary key when it is a synced column.
public struct SyncUniqueKey: Equatable, Sendable {
    public let table: String
    public let columns: [String]
    public let resolution: SyncUniqueResolution

    public init(_ table: String, _ columns: [String], _ resolution: SyncUniqueResolution) {
        self.table = table
        self.columns = columns
        self.resolution = resolution
    }
}

extension SyncSchema {
    /// Every unique key of every synced table. `SyncReferenceClassificationTests` fails, naming the index, when
    /// one isn't listed. Identity is kept to keys that mean the same thing on every device; any other
    /// collision keeps both records. Ruling R9: natural keys of real-world items (a statement row by its
    /// fingerprint, a receipt, an invoice or a contract by its number) are identities, because a suffixed
    /// duplicate would count the money twice.
    public static let uniqueKeys: [SyncUniqueKey] = [
        SyncUniqueKey("person", ["name"], .suffix("name")),
        SyncUniqueKey("appUser", ["personId"], .identity),                     // one app user per person
        SyncUniqueKey("appUser", ["cloudKitUserRecordName"], .identity),       // one app user per iCloud user
        SyncUniqueKey("personSharing", ["personId"], .identity),               // one sharing row per person
        SyncUniqueKey("memberPermission", ["appUserId", "area"], .identity),   // one level per user and area
        SyncUniqueKey("account", ["isMain"], .exclusiveFlag("isMain")),
        SyncUniqueKey("account", ["name"], .suffix("name")),
        SyncUniqueKey("categoryGroup", ["name"], .suffix("name")),
        SyncUniqueKey("category", ["transferAccountId"], .yield("transferAccountId", .null)),
        SyncUniqueKey("category", ["builtInRole"], .identity),
        SyncUniqueKey("category", ["name"], .suffix("name")),
        SyncUniqueKey("accountBalancePoint", ["accountId", "payMonth"], .identity),
        SyncUniqueKey("accountSummaryMonth", ["accountId", "payMonth", "categoryId"], .identity),
        SyncUniqueKey("accountSummaryMonth", ["accountId", "payMonth"], .identity),  // the uncategorised row (partial index)
        SyncUniqueKey("customDocumentKind", ["name"], .identity),              // one kind per name (ignoring case) on every device
        SyncUniqueKey("document", ["sha256"], .identity),                      // the same file
        SyncUniqueKey("importProfile", ["accountId", "format"], .identity),    // the account's profile for a format
        SyncUniqueKey("importRule", ["kind", "matchKey"], .identity),          // one learnt rule per key (`ImportRuleStore.learn`)
        SyncUniqueKey("importWaitingFile", ["sha256"], .identity),             // one waiting row per file content
        SyncUniqueKey("transaction_", ["accountId", "fingerprint"], .identity),   // the same statement row (ruling R9)
        SyncUniqueKey("transferLink", ["inTransactionId"], .yield("isDismissed", .bool(true))),
        SyncUniqueKey("payMonthClose", ["year", "month"], .identity),
        SyncUniqueKey("scenario", ["name"], .suffix("name")),
        SyncUniqueKey("plannedOccurrenceException", ["entryId", "originalDate"], .identity),
        SyncUniqueKey("documentLink", ["documentId", "entityType", "entityId"], .identity),
        SyncUniqueKey("evidenceWaiver", ["requirementId", "entityType", "entityId", "<expr>"], .identity),
        SyncUniqueKey("property", ["name"], .suffix("name")),
        SyncUniqueKey("propertyAccount", ["propertyId", "accountId"], .identity),
        SyncUniqueKey("propertyCategoryGroup", ["propertyId", "categoryGroupId"], .identity),
        SyncUniqueKey("propertyMortgageTerms", ["propertyId"], .identity),     // the primary key (ruling R2)
        SyncUniqueKey("mortgageRateOverride", ["propertyId", "periodStart"], .identity),
        SyncUniqueKey("interestIndexValue", ["indexName", "period", "date"], .identity),
        SyncUniqueKey("tenancy", ["propertyId", "contractNumber"], .identity),  // the same contract (R9)
        SyncUniqueKey("tenancyRent", ["tenancyId", "fromDate"], .identity),
        SyncUniqueKey("rentReceipt", ["tenancyId", "receiptNumber"], .identity), // the same receipt (R9)
        SyncUniqueKey("rentReceiptPayment", ["rentReceiptId", "transactionId"], .identity),
        SyncUniqueKey("utilityProvider", ["propertyId", "name"], .suffix("name")),
        SyncUniqueKey("utilityInvoice", ["providerId", "invoiceNumber"], .identity), // the same invoice (R9)
        SyncUniqueKey("rechargeStatement", ["tenancyId", "month"], .identity),
        SyncUniqueKey("rechargeLine", ["statementId", "invoiceId"], .identity),
        SyncUniqueKey("rechargePayment", ["statementId", "transactionId"], .identity),
        SyncUniqueKey("rechargeEmailTemplate", ["propertyId", "language"], .identity),
        SyncUniqueKey("rechargeNettingRule", ["<expr>"], .identity),           // one rule per start year
        SyncUniqueKey("hmrcRate", ["startYear", "currencyCode"], .identity),
        SyncUniqueKey("taxYear", ["startYear", "personId"], .identity),
        SyncUniqueKey("taxFiledBox", ["startYear", "personId", "field"], .identity),
        // One share per year, person, property and expense type: both devices setting it is one setting
        // edited twice; every differing field goes to the conflict log.
        SyncUniqueKey("taxYearSplit", ["startYear", "personId", "propertyId", "<expr>"], .identity),
        SyncUniqueKey("taxAttributionRule", ["expenseType", "<expr>"], .identity),
        SyncUniqueKey("taxExpenseTypeMap", ["categoryId"], .identity),
        SyncUniqueKey("taxNotClaimed", ["startYear", "transactionId"], .identity),
        SyncUniqueKey("taxNotClaimed", ["startYear", "manualItemId"], .identity),
        SyncUniqueKey("taxNotClaimed", ["startYear", "policyReceiptId"], .identity),
        SyncUniqueKey("taxTransactionOwner", ["transactionId"], .identity),
        SyncUniqueKey("savedSite", ["url"], .identity),                        // the same site, saved on two devices
    ]

    static func uniqueKey(table: String, columns: [String]) -> SyncUniqueKey? {
        uniqueKeys.first { $0.table == table && $0.columns == columns }
    }
}
