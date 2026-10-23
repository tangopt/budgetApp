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
public enum SyncSchema {
    /// Synced tables, parents before children (each foreign key's table is listed earlier).
    public static let tables: [SyncTableSchema] = [
        SyncTableSchema("person",
                        synced: ["name", "shortName", "ukUtr", "ukNino", "ptNif", "notes"]),
        SyncTableSchema("appUser",
                        synced: ["personId", "displayName", "cloudKitUserRecordName", "isAdmin", "createdAt"],
                        foreignKeys: ["personId": "person"],
                        localOnly: ["lastSignInAt"]),
        SyncTableSchema("account",
                        synced: ["name", "currency", "kind", "trackingMode", "alias", "sortCode", "accountNumber", "iban", "sortOrder", "statementMismatchMinorUnits", "statementMismatchDate", "statementMismatchClosingMinorUnits", "statementLastCheckedDate", "balanceConfirmedAt", "bankRegion", "bankName", "routingNumber", "bic", "isMain", "includeInNetWorth"]),
        SyncTableSchema("categoryGroup",
                        synced: ["name", "type"]),
        SyncTableSchema("category",
                        synced: ["name", "type", "groupId", "isReserved", "excludeFromAutoForecast", "isExternalTransfer", "iconName", "builtInRole", "transferAccountId"],
                        foreignKeys: ["transferAccountId": "account"]),
        SyncTableSchema("importRun",
                        synced: ["confirmedAt", "entryPoint", "summary", "reasonsJSON", "undoneAt", "undoSummary", "appUserId"],
                        foreignKeys: ["appUserId": "appUser"],
                        localOnly: ["backupPath"]),
        SyncTableSchema("importBatch",
                        synced: ["accountId", "sourceFileName", "importedAt", "importRunId"],
                        foreignKeys: ["importRunId": "importRun", "accountId": "account"],
                        batchKey: "importRunId"),
        SyncTableSchema("importChange",
                        synced: ["runId", "seq", "tableName", "rowId", "operation", "beforeJSON", "afterJSON"],
                        foreignKeys: ["runId": "importRun"],
                        batchKey: "runId"),
        SyncTableSchema("document",
                        synced: ["sha256", "storedRelativePath", "originalFileName", "byteCount", "canonicalName", "kind", "docDate", "periodStart", "periodEnd", "amountMinorUnits", "currency", "persons", "textStatus", "extractedText", "addedAt", "note"],
                        localOnly: ["sourceFolderId", "sourceRelativePath", "sourceModifiedAt"]),
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
                        synced: ["name", "scope", "kinds", "direction", "excludedAccountIds", "usualSource", "activeFrom", "activeTo", "notes", "createdAt"]),
        SyncTableSchema("evidenceWaiver",
                        synced: ["requirementId", "entityType", "entityId", "slotStart", "reason", "note", "createdAt"],
                        foreignKeys: ["requirementId": "evidenceRequirement"]),
        SyncTableSchema("property",
                        synced: ["name", "country", "currency", "matrixArticle", "purchasePriceMinorUnits", "purchaseDate", "notes"]),
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
    ]

    /// Never synced (sync spec §4.3, §11.6): sync bookkeeping, credentials and settings of this device,
    /// linked source folders and their files (paths and bookmarks), and SQLite's and GRDB's own tables.
    public static let localOnlyTables: Set<String> = [
        "syncRecord", "syncStaging", "syncConflict", "syncTombstone", "syncState",
        "syncPending", "syncFieldClock", "syncWriter", "syncApplying",
        "localCredential", "localSetting",
        "sourceFolder", "sourceFile",
        "grdb_migrations", "sqlite_sequence",
    ]

    private static let byName: [String: SyncTableSchema] = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

    public static func table(_ name: String) -> SyncTableSchema? { byName[name] }
}
