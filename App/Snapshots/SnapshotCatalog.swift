// App/Snapshots/SnapshotCatalog.swift
#if SNAPSHOTS
import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// One capture target: a screen and tab in the main window, or a sheet over it.
struct SnapshotRoute {
    /// `<screen>-<tab>`, the PNGs' prefix (words joined by underscores).
    let name: String
    let title: String
    /// Multiplies the load time before the first capture.
    var settleFactor: Double = 1
    let makeView: @MainActor (SnapshotContext) async throws -> AnyView
}

struct SnapshotMissing: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what) not in the database" }
}

/// Every route the harness renders: each sidebar screen, each tab of Forecast, Property and
/// Tax years, the main sheets of the new screens, a few polished sheets to compare with, and
/// the shared components' gallery (`ComponentGallery`, `gallery-*`).
/// Records are found by the demo database's names ("Person A", "Tenancy 2") — the app doesn't
/// link the demo builder (`BudgetDemo`).
@MainActor
enum SnapshotCatalog {
    static var routes: [SnapshotRoute] { screens + propertyTabs + taxTabs + sheets + ComponentGallery.routes }

    // MARK: Screens

    static func screen(_ screen: String, _ tab: String, _ title: String, _ appScreen: AppScreen, settle: Double = 1,
                       prepare: @escaping @MainActor (SnapshotScreenModels, SnapshotContext) -> Void = { _, _ in }) -> SnapshotRoute {
        SnapshotRoute(name: "\(screen)-\(tab)", title: title, settleFactor: settle) { context in
            AnyView(ContentView(environment: context.environment,
                                snapshotSetup: SnapshotSetup(screen: appScreen, prepare: { models in prepare(models, context) })))
        }
    }

    static var screens: [SnapshotRoute] {
        [
            screen("dashboard", "main", "Dashboard", .dashboard, settle: 1.5),
            screen("search", "main", "Search", .search),
            screen("search", "query", "Search: “greenleaf”", .search) { models, _ in models.search.queryText = "greenleaf" },
            // Show in Search from another screen: the latest rent credit, its row selected.
            screen("search", "revealed", "Search: a transaction shown from Property", .search) { models, context in
                if let transaction = context.latestRentCredit() { models.search.reveal(transaction) }
            },
            screen("budget", "main", "Budget grid", .budgetGrid, settle: 1.5),
            screen("forecast", "compare", "Forecast: Compare", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .compare },
            screen("forecast", "differences", "Forecast: Differences", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .differences },
            screen("forecast", "grid", "Forecast: Grid", .forecast, settle: 1.5) { models, _ in models.scenarioLab.tab = .grid },
            screen("accounts", "main", "Accounts", .accounts),
            screen("accounts", "euro_current", "Accounts: Euro Current", .accounts) { models, context in
                models.accounts.selectedAccountId = context.accountId("Euro Current")
            },
            screen("documents", "main", "Documents", .documents),
            screen("documents", "selected", "Documents: a rent receipt selected", .documents) { models, context in
                models.documents.selectedId = context.documentId(kind: .rentReceipt)
            },
            screen("missing_evidence", "main", "Missing evidence (2025/26)", .missingEvidence) { models, _ in
                models.missingEvidence.periodChoice = .taxYear(2025)
            },
            screen("missing_evidence", "all", "Missing evidence (2025/26, satisfied too)", .missingEvidence) { models, _ in
                models.missingEvidence.periodChoice = .taxYear(2025)
                models.missingEvidence.missingOnly = false
            },
            screen("rules", "main", "Rules", .rules),
            screen("categories", "main", "Categories", .categories),
            screen("uncategorized", "main", "Uncategorized", .uncategorized),
            // A statement staged for review (read only: nothing is saved until Finish import).
            screen("import", "review", "Import: a statement in review", .importReview, settle: 3.5) { models, context in
                guard let account = try? context.dbQueue.read({ db in try Account.filter(Column("name") == "Everyday Current").fetchOne(db) }) else { return }
                Task { @MainActor in
                    await models.importReview.stagePDF(lines: demoStatementLines, config: demoStatementLayout, account: account,
                                                       sourceFileName: "Everyday Current October.pdf")
                }
            },
            SnapshotRoute(name: "settings-main", title: "Settings window") { _ in AnyView(SnapshotStandaloneCanvas(content: SettingsView())) }
        ]
    }

    /// An invented statement for the Import route: merchants the demo's rules match or its
    /// history knows by the same name (so nothing asks the on-device model), a long
    /// description, a credit and a line that doesn't parse.
    static let demoStatementLines = [
        "02/10/2026 GREENLEAF MARKET LONDON 63.47",
        "03/10/2026 CITY TRANSIT ZONE 1-2 2.85",
        "04/10/2026 BEAN THERE COFFEE KINGS CROSS 4.35",
        "05/10/2026 STREAMFLIX 10.99",
        "06/10/2026 CORNER GROCER 17.62",
        "06/10/2026 CORNER GROCER 8.14",
        "07/10/2026 IRONWORKS GYM 39.00",
        "08/10/2026 QUICKRIDE TRIP 23.15",
        "09/10/2026 PEBBLE MOBILE 18.00",
        "10/10/2026 FIBRELINE BROADBAND 32.00",
        "12/10/2026 TUNEBOX MUSIC 11.99",
        "13/10/2026 CLOUDVAULT STORAGE 2.99",
        "14/10/2026 ACME WIDGETS LTD SALARY 3,412.88 CR",
        "14/10/2026 GREENLEAF MARKET WESTFIELD STRATFORD CITY BRANCH 0412 CONTACTLESS 1,204.56",
        "Balance carried forward 4,723.86"
    ]
    static let demoStatementLayout = PDFLayoutConfig(regexPattern: #"^(\d{2}/\d{2}/\d{4})\s+(.+?)\s+([\d,]+\.\d{2})(?:\s+(?:DR|CR))?$"#,
                                                     dateFormat: "dd/MM/yyyy")

    static var propertyTabs: [SnapshotRoute] {
        let august = DateInterval(start: MonthRange.of(year: 2026, month: 8).start, end: MonthRange.of(year: 2026, month: 9).start)
        return PropertyViewModel.Tab.allCases.map { tab in
            screen("property", tab.rawValue.lowercased(), "Property: \(tab.rawValue)", .property, settle: 1.3) { models, _ in
                models.property.tab = tab
            }
        } + [
            screen("property", "overview_month", "Property: Overview, August's transactions open", .property, settle: 1.5) { models, _ in
                models.property.tab = .overview
                models.property.sidePanel = .month(august)
            },
            screen("property", "money_month", "Property: Money, August's transactions open", .property, settle: 1.5) { models, _ in
                models.property.tab = .money
                models.property.sidePanel = .month(august)
            },
            screen("property", "overview_loan_5y", "Property: Overview, the loan five years each side", .property, settle: 1.3) { models, _ in
                models.property.tab = .overview
                models.property.loanRange = .fiveYears
            },
            screen("property", "overview_loan_end", "Property: Overview, the loan to the end", .property, settle: 1.3) { models, _ in
                models.property.tab = .overview
                models.property.loanRange = .toTheEnd
            },
            // The running tenancy's latest paid statement, and August's recharges.
            screen("property", "recharges_statement", "Property: Recharges, a paid statement open", .property, settle: 1.5) { models, context in
                models.property.tab = .recharges
                if let (statement, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeStatement(id: statement, tenancyId: tenancy)
                }
            },
            // The running tenancy's latest receipt with its PDF and a credit.
            screen("property", "tenancies_receipt", "Property: Tenancies, a receipt open", .property, settle: 1.6) { models, context in
                models.property.tab = .tenancies
                if let (receipt, tenancy) = context.latestReceiptWithPDF() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .receipt(id: receipt, tenancyId: tenancy)
                }
            },
            screen("property", "recharges_month", "Property: Recharges, August's month open", .property, settle: 1.5) { models, context in
                models.property.tab = .recharges
                if let (_, tenancy) = context.latestPaidStatement() {
                    models.property.selectedTenancyId = tenancy
                    models.property.sidePanel = .rechargeMonth(august.start, tenancyId: tenancy)
                }
            }
        ]
    }

    static var taxTabs: [SnapshotRoute] {
        let tabs = TaxYearsViewModel.Tab.allCases.map { tab in
            screen("tax_years", tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"), "Tax years: \(tab.rawValue) (Person A, 2025/26)",
                   .taxYears, settle: 1.5) { models, context in
                models.taxYears.selection = context.taxYear("Person A", 2025)
                models.taxYears.tab = tab
            }
        }
        let filed = [TaxYearsViewModel.Tab.accounts, .taxReturn, .filing].map { tab in
            screen("tax_years", "filed_" + tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"),
                   "Tax years: \(tab.rawValue) (Person A, 2024/25, filed)", .taxYears, settle: 1.5) { models, context in
                models.taxYears.selection = context.taxYear("Person A", 2024)
                models.taxYears.tab = tab
            }
        }
        return tabs + filed
    }

    // MARK: Sheets

    static func sheet(_ name: String, _ title: String, settle: Double = 0.6,
                      _ make: @escaping @MainActor (SnapshotContext) async throws -> AnyView) -> SnapshotRoute {
        SnapshotRoute(name: "sheet-\(name)", title: "Sheet: \(title)", settleFactor: settle) { context in
            AnyView(SnapshotSheetCanvas(sheet: try await make(context)))
        }
    }

    static var sheets: [SnapshotRoute] {
        [
            // Property
            sheet("property_form", "Edit property") { context in
                let model = await context.propertyModel()
                return AnyView(PropertyFormSheet(viewModel: model, draft: PropertyDraft(model.property)))
            },
            sheet("owners", "Owners") { context in AnyView(OwnersSheet(viewModel: await context.propertyModel())) },
            sheet("owners_error", "Owners (shares not adding up: Save's error)") { context in
                // Save's real message: the shares as entered are refused (the write rolls back).
                let model = await context.propertyModel()
                let propertyId = try context.propertyId()
                let people = model.snapshot.people
                guard let a = people.first(where: { $0.name == "Person A" })?.id, let b = people.first(where: { $0.name == "Person B" })?.id else {
                    throw SnapshotMissing("Person A and Person B")
                }
                let purchase = model.property?.purchaseDate
                let error = model.setOwners([PropertyOwner(propertyId: propertyId, personId: a, shareBasisPoints: 6_000, fromDate: purchase),
                                             PropertyOwner(propertyId: propertyId, personId: b, shareBasisPoints: 3_000, fromDate: purchase)])
                    ?? "The shares don't add up to 100%."
                return AnyView(OwnersSheet(viewModel: model, rows: [OwnersSheet.Row(personId: a, shareText: "60", from: purchase),
                                                                    OwnersSheet.Row(personId: b, shareText: "30", from: purchase)],
                                           error: error))
            },
            sheet("person_form", "Edit person") { context in
                let model = await context.propertyModel()
                guard let person = model.snapshot.people.first(where: { $0.name == "Person A" }) else { throw SnapshotMissing("Person A") }
                return AnyView(PersonFormSheet(viewModel: model, person: person))
            },
            sheet("link_account", "Link account") { context in AnyView(LinkAccountSheet(viewModel: await context.propertyModel())) },
            sheet("mortgage_terms", "Mortgage terms") { context in AnyView(MortgageTermsSheet(viewModel: await context.propertyModel())) },
            sheet("tenancy_form", "Edit tenancy") { context in
                let model = await context.propertyModel()
                guard let tenancy = model.snapshot.tenancies.first(where: { $0.referenceLabel == "Tenancy 2" }) else { throw SnapshotMissing("Tenancy 2") }
                return AnyView(TenancyFormSheet(viewModel: model, draft: TenancyDraft(tenancy, rents: model.snapshot.rents[tenancy.id!] ?? [],
                                                                                   propertyId: tenancy.propertyId)))
            },
            sheet("tenancy_form_new", "New tenancy") { context in
                let model = await context.propertyModel()
                return AnyView(TenancyFormSheet(viewModel: model, draft: TenancyDraft(nil, rents: [], propertyId: try context.propertyId())))
            },
            sheet("import_receipts", "Import rent receipts") { context in AnyView(ImportReceiptsSheet(viewModel: await context.propertyModel())) },
            sheet("import_receipts_preview", "Import rent receipts (a file read)") { context in
                let model = await context.propertyModel()
                return AnyView(ImportReceiptsSheet(viewModel: model, preview: try await context.receiptsImportPreview()))
            },
            sheet("tenancy_documents", "Tenancy documents") { context in
                let model = await context.propertyModel()
                guard let tenancy = model.snapshot.tenancies.last else { throw SnapshotMissing("a tenancy") }
                return AnyView(PropertyDocumentsSheet(viewModel: model, entity: EvidenceEntity(type: .tenancy, id: tenancy.id!),
                                                      title: "Documents · \(tenancy.referenceLabel)"))
            },
            sheet("money_drill_down", "Money: costs drill-down") { context in
                let model = await context.propertyModel()
                return AnyView(PropertyDrillDownSheet(title: "Costs", rows: model.transactions(.costs(categoryId: nil)), openTransaction: { _ in }))
            },
            sheet("recharge_statement_paid", "Recharge statement (paid)") { context in
                try await context.statementSheet(status: .paid)
            },
            sheet("recharge_statement_sent", "Recharge statement (sent)") { context in
                try await context.statementSheet(status: .sent)
            },
            sheet("recharge_statement_draft", "Recharge statement (draft, email)") { context in
                try await context.statementSheet(status: .draft)
            },
            sheet("utility_providers", "Utility providers") { context in
                AnyView(UtilityProvidersSheet(dbQueue: context.dbQueue, propertyId: try context.propertyId()))
            },
            sheet("utility_provider_form", "Edit utility provider") { context in
                let propertyId = try context.propertyId()
                guard let provider = try await context.dbQueue.read({ db in try Recharges.providers(db: db, propertyId: propertyId).first }) else {
                    throw SnapshotMissing("a utility provider")
                }
                return AnyView(UtilityProviderFormSheet(dbQueue: context.dbQueue, provider: provider))
            },
            sheet("invoice_intake", "Utility invoice intake (empty)", settle: 1.5) { context in
                AnyView(UtilityInvoiceIntakeSheet(dbQueue: context.dbQueue, library: context.library, propertyId: try context.propertyId(), currency: .eur))
            },
            sheet("invoice_intake_lines", "Utility invoice intake (a library invoice to check)", settle: 1.5) { context in
                let model = UtilityInvoiceIntakeModel(dbQueue: context.dbQueue, library: context.library, propertyId: try context.propertyId(), currency: .eur)
                model.loadProviders()
                model.addFromLibrary()
                await context.settle(1)
                return AnyView(UtilityInvoiceIntakeSheet(model: model))
            },
            sheet("invoice_intake_problems", "Utility invoice intake (a scan that needs filling in)", settle: 1.5) { context in
                let model = UtilityInvoiceIntakeModel(dbQueue: context.dbQueue, library: context.library, propertyId: try context.propertyId(), currency: .eur)
                model.loadProviders()
                model.addFromLibrary()
                await context.settle(1)
                // A second line as a phone scan would arrive: read by OCR, nothing found.
                if var proposal = model.rows.first?.proposal {
                    proposal.fileName = "Scan 2026-10-02 water bill.jpg"
                    proposal.usedOCR = true
                    model.rows.append(UtilityInvoiceIntakeModel.Row(proposal: proposal, include: true, providerId: nil, invoiceNumber: "",
                                                                    issueDate: nil, amountText: "", transactionId: nil, candidates: []))
                }
                return AnyView(UtilityInvoiceIntakeSheet(model: model))
            },
            // Tax years
            sheet("tax_line_sources", "Rental accounts: line sources") { context in
                let model = await context.taxModel()
                guard let accounts = model.accounts, let line = accounts.expenses.first(where: { !$0.sources.isEmpty }) else {
                    throw SnapshotMissing("a rental accounts line")
                }
                return AnyView(TaxLineSourcesSheet(viewModel: model, line: line, currency: accounts.currency, openTransaction: { _ in }))
            },
            sheet("tax_manual_item", "Manual item") { context in
                let model = await context.taxModel()
                guard let item = model.page?.manualItems.first else { throw SnapshotMissing("a manual item") }
                return AnyView(TaxManualItemSheet(viewModel: model, draft: ManualItemDraft(item)))
            },
            sheet("tax_rate", "HMRC rate") { context in
                let model = await context.taxModel()
                guard let page = model.page else { throw SnapshotMissing("the tax year page") }
                return AnyView(TaxRateSheet(viewModel: model, year: page.row.year, current: page.rates.first { $0.currencyCode == "EUR" }))
            },
            sheet("tax_split", "Split") { context in
                let model = await context.taxModel()
                guard let page = model.page else { throw SnapshotMissing("the tax year page") }
                return AnyView(TaxSplitSheet(viewModel: model, page: page, draft: TaxSettingsTab.SplitDraft(expenseType: .repairs, shareBasisPoints: 5_000)))
            },
            sheet("tax_rule", "Attribution rule") { context in
                let model = await context.taxModel()
                guard let page = model.page, let row = page.rules.first(where: { $0.expenseType == .insurance }) ?? page.rules.first else {
                    throw SnapshotMissing("an attribution rule")
                }
                return AnyView(TaxRuleSheet(viewModel: model, year: page.row.year, row: row))
            },
            sheet("employment", "Employment") { context in
                let model = await context.taxModel()
                guard let row = model.page?.income.employments.first else { throw SnapshotMissing("an employment") }
                return AnyView(EmploymentSheet(viewModel: model, employment: row.employment))
            },
            sheet("employment_income", "Pay and tax (P60)") { context in
                let model = await context.taxModel()
                guard let income = model.page?.income.employments.first?.incomes.first else { throw SnapshotMissing("employment income") }
                return AnyView(EmploymentIncomeSheet(viewModel: model, income: income))
            },
            sheet("benefit", "Benefit in kind") { context in
                let model = await context.taxModel()
                guard let benefit = model.page?.income.employments.first?.benefits.first else { throw SnapshotMissing("a benefit") }
                return AnyView(BenefitSheet(viewModel: model, benefit: benefit))
            },
            sheet("other_income", "Other income") { context in
                let model = await context.taxModel()
                guard let income = model.page?.income.otherIncomes.first else { throw SnapshotMissing("other income") }
                return AnyView(OtherIncomeSheet(viewModel: model, income: income))
            },
            sheet("pension", "Pension contribution") { context in
                let model = await context.taxModel()
                guard let pension = model.page?.income.pensions.first else { throw SnapshotMissing("a pension contribution") }
                return AnyView(PensionSheet(viewModel: model, contribution: pension))
            },
            sheet("hmrc_payment", "HMRC payment") { context in
                let model = await context.taxModel()
                guard let page = model.page, let payment = page.income.payments.first else { throw SnapshotMissing("an HMRC payment") }
                return AnyView(HMRCPaymentSheet(viewModel: model, payment: payment, yearStatus: page.row.status))
            },
            // The P60 / P45 / P11D import's confirm sheet, over forms already in the library (so
            // closing it removes nothing): a clean P60, and a P11D read by OCR with a warning.
            sheet("payroll_confirm", "Confirm P60 (import)") { context in
                let model = await context.taxModel(tab: .income)
                let document = try await context.payrollDocument("P60 2025-26 Acme Widgets Ltd.pdf")
                // As the reader gives a clean P60 (the demo PDF's layout isn't the reader's).
                let extraction = PayrollFormExtraction(kind: .p60, entryMethod: .textLayer, startYear: 2025, employerName: "Acme Widgets Ltd",
                                                       payeReference: "123/AB45678", taxCode: "1257L", payMinorUnits: 4_176_000,
                                                       taxDeductedMinorUnits: 583_800, totalPayMinorUnits: 4_176_000, totalTaxMinorUnits: 583_800)
                let draft = TaxYearsViewModel.FormImportDraft(documentId: document.id!, fileName: document.originalFileName, extraction: extraction,
                                                              isNewDocument: false, personWarnings: [])
                return AnyView(PayrollFormConfirmSheet(viewModel: model, draft: draft, personId: model.selection?.personId ?? 0, defaultYear: 2025))
            },
            sheet("payroll_confirm_p11d", "Confirm P11D (import, read by OCR)") { context in
                let model = await context.taxModel(tab: .income)
                let document = try await context.payrollDocument("P11D 2025-26 Acme Widgets Ltd.pdf")
                let extraction = PayrollFormExtraction(kind: .p11d, entryMethod: .ocr, startYear: 2025, employerName: "Acme Widgets Ltd",
                                                       payeReference: "123/AB45678",
                                                       benefits: [.init(kind: .medical, cashEquivalentMinorUnits: 121_000),
                                                                  .init(kind: .carFuel, cashEquivalentMinorUnits: 0)],
                                                       warnings: ["Section F wasn't clear: check the car fuel figure."])
                let draft = TaxYearsViewModel.FormImportDraft(documentId: document.id!, fileName: document.originalFileName, extraction: extraction,
                                                              isNewDocument: false, personWarnings: [])
                return AnyView(PayrollFormConfirmSheet(viewModel: model, draft: draft, personId: model.selection?.personId ?? 0, defaultYear: 2025))
            },
            // Documents and Missing evidence
            sheet("link_transaction", "Link to transaction", settle: 1.2) { context in
                let model = DocumentsViewModel(dbQueue: context.dbQueue, library: context.library)
                model.load()
                await context.settle(0.8)
                return AnyView(LinkTransactionSheet(documentName: "Rent receipt T2-024.pdf", viewModel: model))
            },
            sheet("link_document", "Link document", settle: 1.2) { context in
                let id = try context.transactionId(description: "BOILER REPAIR LDA")
                let model = TransactionDocumentsModel(transactionId: id, library: context.library, dbQueue: context.dbQueue)
                model.load()
                return AnyView(LinkDocumentSheet(model: model, transactionName: "BOILER REPAIR LDA"))
            },
            sheet("link_evidence", "Missing evidence: link", settle: 1.2) { context in
                let model = await context.missingEvidenceModel()
                guard let item = model.items.first(where: { $0.status == .missing }) else { throw SnapshotMissing("a missing item") }
                return AnyView(LinkEvidenceSheet(item: item, viewModel: model))
            },
            sheet("waive_evidence", "Missing evidence: waive") { context in
                let model = await context.missingEvidenceModel()
                guard let item = model.items.first(where: { $0.status == .missing }) else { throw SnapshotMissing("a missing item") }
                return AnyView(WaiveEvidenceSheet(item: item, viewModel: model))
            },
            sheet("evidence_rules", "Evidence rules") { context in AnyView(EvidenceRulesSheet(viewModel: await context.missingEvidenceModel())) },
            sheet("evidence_rule_editor", "Evidence rule editor") { context in
                let model = await context.missingEvidenceModel()
                return AnyView(EvidenceRuleEditorSheet(viewModel: model, requirement: model.requirements.first))
            },
            sheet("property_rules", "Property evidence rules") { context in AnyView(PropertyRulesSheet(viewModel: await context.missingEvidenceModel())) },
            sheet("property_rules_preview", "Property evidence rules (a group chosen)") { context in
                let model = await context.missingEvidenceModel()
                // The demo's property group has its rules already: the first expense group with rules to add.
                let group = model.categoryGroups.filter { $0.sectionType == .expense }.first { group in
                    guard let id = group.id, case .success(let rules) = model.propertyRulesPreview(groupId: id, mortgageAccountIds: []) else { return false }
                    return !rules.isEmpty
                }
                guard let group else { throw SnapshotMissing("an expense group without rules") }
                return AnyView(PropertyRulesSheet(viewModel: model, groupId: group.id))
            },
            sheet("folder_review", "Review a source folder (a scan's result)", settle: 1.2) { context in
                AnyView(FolderReviewSheet(model: try await context.folderReviewModel()))
            },
            // Polished sheets, for comparison
            sheet("ref_add_account", "Reference: Add account") { context in
                let model = AccountsViewModel(dbQueue: context.dbQueue)
                _ = model.load()
                return AnyView(AddAccountSheet(viewModel: model))
            },
            sheet("ref_update_balance", "Reference: Update balance") { context in
                let model = AccountsViewModel(dbQueue: context.dbQueue)
                _ = model.load()
                guard let row = model.overview?.groups.first?.rows.first else { throw SnapshotMissing("an account row") }
                return AnyView(UpdateBalanceSheet(viewModel: model, row: row))
            },
            sheet("ref_edit_transaction", "Reference: Edit transaction") { context in
                let model = SearchViewModel(dbQueue: context.dbQueue)
                model.load()
                let id = try context.transactionId(description: "GREENLEAF MARKET")
                guard let transaction = try await context.dbQueue.read({ db in try Transaction.fetchOne(db, key: id) }) else {
                    throw SnapshotMissing("a transaction")
                }
                return AnyView(EditTransactionSheet(
                    transaction: transaction, categories: model.categories, groups: model.groups, recentIds: model.recentCategoryIds,
                    createCategory: model.createCategory, transfer: model.transferActions, manual: model.manualActions,
                    onSave: { _ in .saved }))
            }
        ]
    }
}

// MARK: - Demo records

extension SnapshotContext {
    /// The latest paid recharge statement of the latest tenancy, and that tenancy.
    func latestPaidStatement() -> (Int64, Int64)? {
        try? dbQueue.read { db in
            guard let tenancy = try Tenancy.order(Column("startDate").desc).fetchOne(db)?.id,
                  let statement = try RechargeStatement.filter(Column("tenancyId") == tenancy && Column("status") == RechargeStatementStatus.paid.rawValue)
                    .order(Column("month").desc).fetchOne(db)?.id else { return nil }
            return (statement, tenancy)
        }
    }

    /// The latest tenancy's latest receipt that has a PDF and a credit linked, and that tenancy.
    func latestReceiptWithPDF() -> (Int64, Int64)? {
        try? dbQueue.read { db in
            guard let tenancy = try Tenancy.order(Column("startDate").desc).fetchOne(db)?.id,
                  let receipt = try Int64.fetchOne(db, sql: """
                      SELECT r.id FROM rentReceipt r
                      WHERE r.tenancyId = ?
                        AND EXISTS (SELECT 1 FROM documentLink l WHERE l.entityType = ? AND l.entityId = r.id)
                        AND EXISTS (SELECT 1 FROM rentReceiptPayment p WHERE p.rentReceiptId = r.id)
                      ORDER BY r.periodStart DESC LIMIT 1
                      """, arguments: [tenancy, EvidenceEntityType.rentReceipt.rawValue]) else { return nil }
            return (receipt, tenancy)
        }
    }

    /// The latest credit linked to a rent receipt.
    func latestRentCredit() -> Transaction? {
        try? dbQueue.read { db in
            try Transaction.fetchOne(db, sql: """
                SELECT t.* FROM transaction_ t JOIN rentReceiptPayment p ON p.transactionId = t.id
                ORDER BY t.date DESC LIMIT 1
                """)
        }
    }

    func accountId(_ name: String) -> Int64? {
        try? dbQueue.read { db in try Account.filter(Column("name") == name).fetchOne(db)?.id }
    }

    func propertyId() throws -> Int64 {
        guard let id = try dbQueue.read({ db in try Property.order(Column("id")).fetchOne(db)?.id }) else { throw SnapshotMissing("a property") }
        return id
    }

    /// A payroll form of the demo library, by its file name.
    func payrollDocument(_ fileName: String) async throws -> EvidenceDocument {
        guard let document = try await dbQueue.read({ db in
            try EvidenceDocument.filter(Column("originalFileName") == fileName).fetchOne(db)
        }), document.id != nil else { throw SnapshotMissing("“\(fileName)”") }
        return document
    }

    func documentId(kind: DocumentKind) -> Int64? {
        try? dbQueue.read { db in try EvidenceDocument.filter(Column("kind") == kind.rawValue).order(Column("id")).fetchOne(db)?.id }
    }

    func transactionId(description: String) throws -> Int64 {
        guard let id = try dbQueue.read({ db in
            try Transaction.filter(Column("rawDescription") == description).order(Column("date").desc).fetchOne(db)?.id
        }) else { throw SnapshotMissing("“\(description)”") }
        return id
    }

    func taxYear(_ personName: String, _ startYear: Int) -> TaxYearsViewModel.Selection? {
        guard let personId = try? dbQueue.read({ db in try Person.filter(Column("name") == personName).fetchOne(db)?.id }) else { return nil }
        return TaxYearsViewModel.Selection(personId: personId, startYear: startYear)
    }

    /// The first property's page model, loaded.
    func propertyModel() async -> PropertyViewModel {
        let model = PropertyViewModel(dbQueue: dbQueue, library: library)
        model.propertyId = try? propertyId()
        model.start()
        await settle(0.6)
        return model
    }

    /// Person A's 2025/26 page, loaded.
    func taxModel(tab: TaxYearsViewModel.Tab = .accounts) async -> TaxYearsViewModel {
        let model = TaxYearsViewModel(dbQueue: dbQueue, library: library)
        model.selection = taxYear("Person A", 2025)
        model.tab = tab
        model.start()
        await settle(0.8)
        return model
    }

    /// The 2025/26 checklist, loaded.
    func missingEvidenceModel() async -> MissingEvidenceViewModel {
        let model = MissingEvidenceViewModel(dbQueue: dbQueue, library: library)
        model.periodChoice = .taxYear(2025)
        model.start()
        await settle(0.8)
        return model
    }

    /// What importing the portal's receipts export would do: every receipt the demo has, as the
    /// file lists them, plus next month's for the latest tenancy (previewed in a savepoint that
    /// is rolled back: nothing is written).
    func receiptsImportPreview() async throws -> ReceiptsImportPreview {
        let propertyId = try propertyId()
        let utc: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()
        return try await dbQueue.write { db in
            var rows: [RentReceiptsExport.Row] = []
            let tenancies = try Tenancy.filter(Column("propertyId") == propertyId).order(Column("startDate")).fetchAll(db)
            for tenancy in tenancies {
                func row(_ receipt: RentReceipt) -> RentReceiptsExport.Row {
                    RentReceiptsExport.Row(rowNumber: rows.count + 2, reference: tenancy.referenceLabel, contractNumber: tenancy.contractNumber ?? "",
                                           receiptNumber: receipt.receiptNumber, tenant: tenancy.tenantName, periodStart: receipt.periodStart,
                                           periodEnd: receipt.periodEnd, receiptDate: receipt.receiptDate, amountMinorUnits: receipt.amountMinorUnits,
                                           withholdingMinorUnits: receipt.withholdingMinorUnits, amountReceivedMinorUnits: receipt.amountReceivedMinorUnits,
                                           status: receipt.status)
                }
                let receipts = try RentReceipt.filter(Column("tenancyId") == tenancy.id!).order(Column("periodStart")).fetchAll(db)
                rows += receipts.map(row)
                // The latest tenancy's next receipt: new in this file.
                if tenancy.id == tenancies.last?.id, var next = receipts.last {
                    let parts = next.receiptNumber.split(separator: "-")
                    if let last = parts.last, let number = Int(last) {
                        next.receiptNumber = (parts.dropLast() + [Substring(String(format: "%03d", number + 1))]).joined(separator: "-")
                    }
                    next.periodStart = next.periodEnd.addingTimeInterval(86_400)
                    next.periodEnd = utc.date(byAdding: DateComponents(month: 1, day: -1), to: next.periodStart)!
                    next.receiptDate = next.periodStart
                    next.amountReceivedMinorUnits = next.amountMinorUnits - next.withholdingMinorUnits
                    rows.append(row(next))
                }
            }
            let report = try RentReceiptImport.preview(db: db, propertyId: propertyId, rows: rows)
            return ReceiptsImportPreview(fileName: "ListaRecibos.xlsx", rows: rows, report: report)
        }
    }

    /// A source folder's review as a scan would leave it, made up from the demo's transactions
    /// (no folder is read; the folder isn't registered): three new files — one matched
    /// confidently (ticked), one with two candidates, a photo with none — a changed contract,
    /// a missing file, and counts of the rest.
    func folderReviewModel() async throws -> FolderReviewModel {
        let ids = try ["EXAMPLE WATER DD", "CONDOMINIO EDIFICIO EXEMPLO", "EXAMPLE GAS DD"].map(transactionId(description:))
        let transactions = try await dbQueue.read { db in try ids.map { id in try Transaction.fetchOne(db, key: id) } }.compactMap { $0 }
        guard transactions.count == 3 else { throw SnapshotMissing("the utility transactions") }
        let (water, condominio, gas) = (transactions[0], transactions[1], transactions[2])
        let contractId = documentId(kind: .rentContract)
        let folder = SourceFolder(id: -1, path: "/Volumes/Demo/Property A papers", bookmark: nil, name: "Property A papers", lastScanAt: AppClock.now)
        let root = URL(fileURLWithPath: folder.path)
        func file(_ path: String, size: Int64 = 182_000, analysis: EvidenceAnalysis? = nil, suggestions: [EvidenceMatcher.Suggestion] = [],
                  documentId: Int64? = nil, previousDocumentId: Int64? = nil, changed: Date? = nil) -> SourceFolderScanner.ScannedFile {
            SourceFolderScanner.ScannedFile(relativePath: path, url: root.appendingPathComponent(path), size: size, modifiedAt: AppClock.now,
                                            sha256: String(repeating: "0", count: 64), documentId: documentId, previousDocumentId: previousDocumentId,
                                            changeDetectedAt: changed, analysis: analysis, suggestions: suggestions)
        }
        func invoice(_ kind: DocumentKind, _ transaction: Transaction, status: DocumentTextStatus = .text) -> EvidenceAnalysis {
            EvidenceAnalysis(metadata: EvidenceMetadata(kind: kind, docDate: transaction.date.addingTimeInterval(-3 * 86_400),
                                                        amountMinorUnits: abs(transaction.amountMinorUnits), currency: .eur, textStatus: status),
                             textStatus: status, extractedText: nil)
        }
        let new = [
            file("Utilities/Water \(DocumentFormat.day(water.date)).pdf", analysis: invoice(.utilityInvoice, water),
                 suggestions: [EvidenceMatcher.Suggestion(transactionId: water.id!, score: 190,
                                                          reasons: ["Amount \(Money.format(abs(water.amountMinorUnits), currency: .eur))", "3 days after",
                                                                    "Description mentions water"],
                                                          amountMatched: true, dateInWindow: true)]),
            file("Condominio/Quota receipt.pdf", analysis: invoice(.condominioReceipt, condominio),
                 suggestions: [EvidenceMatcher.Suggestion(transactionId: condominio.id!, score: 120, reasons: ["Amount \(Money.format(abs(condominio.amountMinorUnits), currency: .eur))"],
                                                          amountMatched: true),
                               EvidenceMatcher.Suggestion(transactionId: gas.id!, score: 60, reasons: ["9 days after"], dateInWindow: true)]),
            file("Scans/IMG_0412.jpg", size: 2_400_000,
                 analysis: EvidenceAnalysis(metadata: EvidenceMetadata(textStatus: .image), textStatus: .image, extractedText: nil))
        ]
        let changed = contractId.map { [file("Contracts/Tenancy contract.pdf", documentId: nil, previousDocumentId: $0,
                                             changed: AppClock.now.addingTimeInterval(-2 * 86_400))] } ?? []
        let missing = [SourceFile(folderId: -1, relativePath: "Old/Insurance 2024.pdf", size: 90_000, modifiedAt: AppClock.now, sha256: "",
                                  lastSeenAt: AppClock.now.addingTimeInterval(-40 * 86_400))]
        let inLibrary = (1...38).map { file("Library/\($0).pdf", documentId: Int64($0)) }
        let result = SourceFolderScanner.ScanResult(folder: folder, scannedAt: AppClock.now, new: new, changed: changed, missing: missing,
                                                    inLibrary: inLibrary, notDownloaded: ["Archive/2023 statements.pdf"])
        let model = FolderReviewModel(folder: folder, scanner: SourceFolderScanner(library: library), dbQueue: dbQueue)
        model.showForSnapshot(result, catalog: try? await TransactionCatalog.load(dbQueue))
        return model
    }

    /// The statement sheet for Tenancy 2's latest statement in `status`.
    func statementSheet(status: RechargeStatementStatus) async throws -> AnyView {
        let propertyId = try propertyId()
        let found = try await dbQueue.read { db -> (Tenancy, RechargeStatement)? in
            guard let tenancy = try Tenancy.filter(Column("propertyId") == propertyId && Column("referenceLabel") == "Tenancy 2").fetchOne(db),
                  let statement = try RechargeStatement.filter(Column("tenancyId") == tenancy.id! && Column("status") == status.rawValue)
                    .order(Column("month").desc).fetchOne(db) else { return nil }
            return (tenancy, statement)
        }
        guard let (tenancy, statement) = found else { throw SnapshotMissing("a \(status.rawValue) statement") }
        let model = RechargeStatementModel(dbQueue: dbQueue, library: library, propertyId: propertyId, tenancy: tenancy, currency: .eur,
                                           target: RechargeStatementTarget(month: statement.month, statementId: statement.id))
        return AnyView(RechargeStatementSheet(model: model))
    }
}
#endif
