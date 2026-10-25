// App/Property/PropertyProfileTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The Profile tab (spec 2026-10-16 §1, UI polish §4.2): the property's details beside its
/// owners and shares by date range; the linked accounts with their roles beside the category
/// groups; then documents (deeds, licences). Panels with aligned label/value rows and tables;
/// row actions as icons, each panel's own action in its corner.
struct PropertyProfileTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.documentKinds) private var kinds

    @State private var editingProperty: PropertyDraft?
    @State private var editingOwners = false
    @State private var linkingAccount = false
    @State private var confirmingDelete = false
    @State private var editingPerson: Person?
    @State private var editingMortgageTerms = false

    var body: some View {
        let snapshot = viewModel.snapshot
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            TwoUpRow {
                detailsPanel(snapshot.property)
            } second: {
                ownersPanel(snapshot)
            }
            TwoUpRow {
                accountsPanel(snapshot)
            } second: {
                groupsPanel(snapshot)
            }
            TwoUpRow {
                mortgagePanel(snapshot)
            } second: {
                documentsPanel(snapshot)
            }
        }
        .sheet(item: $editingProperty) { PropertyFormSheet(viewModel: viewModel, draft: $0) }
        .sheet(isPresented: $editingOwners) { OwnersSheet(viewModel: viewModel) }
        .sheet(item: $editingPerson) { PersonFormSheet(viewModel: viewModel, person: $0) }
        .sheet(isPresented: $linkingAccount) { LinkAccountSheet(viewModel: viewModel) }
        .sheet(isPresented: $editingMortgageTerms) { MortgageTermsSheet(viewModel: viewModel) }
        .confirmationDialog(snapshot.property.map { "Delete “\($0.name)”?" } ?? "Delete the property?", isPresented: $confirmingDelete) {
            Button("Delete property", role: .destructive) { viewModel.deleteProperty() }
        } message: {
            Text("Its owners, account and group links, tenancies, rents, receipts and their credit links go. Transactions and documents stay. This can't be undone.")
        }
    }

    // MARK: Details

    private func detailsPanel(_ property: Property?) -> some View {
        Panel("Details", fillsHeight: true) {
            if let property {
                HStack(spacing: 10) {
                    Button { editingProperty = PropertyDraft(property) } label: { Image(systemName: "pencil") }
                        .help("Edit the property's details")
                        .accessibilityLabel("Edit details")
                    Menu {
                        Button("Edit…") { editingProperty = PropertyDraft(property) }
                        Divider()
                        Button("Delete property…", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions for the property")
                }
                .buttonStyle(.borderless)
            }
        } content: {
            if let property {
                PropertyFacts {
                    PropertyFact("Name") { Text(property.name) }
                    PropertyFact("Country") { Text(property.country) }
                    PropertyFact("Currency") { Text(property.currency.rawValue.uppercased()) }
                    PropertyFact("Matrix article") { Text(property.matrixArticle ?? "—") }
                    PropertyFact("Purchase price") {
                        if let price = property.purchasePriceMinorUnits {
                            MoneyText(minorUnits: price, currency: property.currency, role: .neutral)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    PropertyFact("Purchased on") { DateText(date: property.purchaseDate) }
                    if let notes = property.notes, !notes.isEmpty {
                        PropertyFact("Notes") { Text(notes).lineLimit(2).help(notes) }
                    }
                }
            }
        }
    }

    // MARK: Owners

    private func ownersPanel(_ snapshot: PropertyViewModel.Snapshot) -> some View {
        Panel("Owners", subtitle: "Shares drive each person's part of the rental income and costs", fillsHeight: true) {
            Button("Edit owners…") { editingOwners = true }
                .controlSize(.small)
        } content: {
            if snapshot.owners.isEmpty {
                Text("No owners yet: add them with Edit owners….").font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: [
                    .text("Person", { viewModel.personName($0.personId) }),
                    DataTableColumn("Share", alignment: .trailing, width: .min(56),
                                    accessibilityValue: { PropertyFormat.percent($0.shareBasisPoints) }) { owner, _ in
                        Text(PropertyFormat.percent(owner.shareBasisPoints)).monospacedDigit().figureText()
                    },
                    DataTableColumn("From", accessibilityValue: { $0.fromDate.map(DocumentFormat.day) ?? "since purchase" }) { owner, _ in
                        if owner.fromDate == nil { Text("Since purchase").foregroundStyle(.secondary) } else { DateText(date: owner.fromDate) }
                    },
                    // Empty while the person still owns their share.
                    DataTableColumn("To", accessibilityValue: { $0.toDate.map(DocumentFormat.day) }) { owner, _ in
                        if owner.toDate != nil { DateText(date: owner.toDate) }
                    },
                    .actions { owner in
                        [DataTableAction("Edit \(viewModel.personName(owner.personId)): name and tax identifiers", systemImage: "pencil",
                                         inline: true) {
                            editingPerson = snapshot.people.first { $0.id == owner.personId }
                        }]
                    }
                ], rows: snapshot.owners, zebra: false)
            }
        }
    }

    // MARK: Accounts

    private func accountsPanel(_ snapshot: PropertyViewModel.Snapshot) -> some View {
        Panel("Accounts", subtitle: "Where rent arrives, the mortgage and the deposit held", fillsHeight: true) {
            Button("Link account…") { linkingAccount = true }
                .controlSize(.small)
        } content: {
            if snapshot.propertyAccounts.isEmpty {
                Text("Link the account rent arrives in (current), the mortgage and the deposit account.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DataTable(columns: [
                    .text("Account", { viewModel.accountName($0.accountId) }, detail: { link in
                        viewModel.account(link.accountId).map { "\($0.currency.rawValue.uppercased()) · \(AccountsFormat.kind($0.kind))" }
                    }),
                    // No accessibility value: the picker stays its own element, so VoiceOver reaches it.
                    DataTableColumn("Role") { link, _ in
                        Picker("Role", selection: Binding(get: { link.role },
                                                          set: { viewModel.setAccount(link.accountId, role: $0) })) {
                            ForEach(PropertyAccountRole.allCases, id: \.self) { Text(PropertyFormat.role($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Role of \(viewModel.accountName(link.accountId))")
                    },
                    .actions { link in
                        [DataTableAction("Unlink \(viewModel.accountName(link.accountId))", systemImage: "xmark.circle", inline: true) {
                            viewModel.removeAccount(link.accountId)
                        }]
                    }
                ], rows: snapshot.propertyAccounts, zebra: false)
            }
        }
    }

    // MARK: Mortgage

    /// The mortgage: the rate its rules give now (the index fixing plus the spread, or the
    /// fixed rate, or the rate given for the period), the next revision and instalment, and the
    /// loan's instalments and balloon.
    private func mortgagePanel(_ snapshot: PropertyViewModel.Snapshot) -> some View {
        let terms = snapshot.mortgageTerms ?? PropertyMortgageTerms(propertyId: viewModel.propertyId ?? 0)
        let status = snapshot.rateStatus
        let currency = viewModel.currency
        return Panel("Mortgage", subtitle: "The rate from the loan's rules, for the calendar and the loan chart", fillsHeight: true) {
            Button { editingMortgageTerms = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit the mortgage terms: index, spread, revisions, instalments, balloon")
                .accessibilityLabel("Edit mortgage terms")
        } content: {
            PropertyFacts {
                PropertyFact("Rate") {
                    if let current = status?.current {
                        Text(current.explanation)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    } else if terms.hasRateRules {
                        Text("No \(terms.rateIndex?.displayName ?? "index") fixing stored for this period yet")
                            .foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Add the loan's rules with the pencil (index and spread)")
                            .foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PropertyFact("Next revision") {
                    if let next = status?.nextRevision {
                        HStack(spacing: 4) {
                            DateText(date: next)
                            Text(MortgageTerms.scheduleText(terms.revisionMonths).unbroken)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                .help(MortgageTerms.scheduleText(terms.revisionMonths).capitalizedFirst)
                        }
                    } else {
                        Text(MortgageTerms.scheduleText(terms.revisionMonths).capitalizedFirst).lineLimit(1)
                    }
                }
                PropertyFact("Next instalment") {
                    if let amount = status?.nextInstalmentMinorUnits, let due = status?.nextDue {
                        HStack(spacing: 4) {
                            MoneyText(minorUnits: amount, currency: currency, role: .neutral)
                            Text("due").foregroundStyle(.secondary)
                            DateText(date: due)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                PropertyFact("Instalments") {
                    if let total = terms.totalInstalments {
                        HStack(spacing: 4) {
                            Text("\(total) in all").monospacedDigit().figureText()
                            if let left = status?.remainingInstalments {
                                Text("· \(left) left").monospacedDigit().foregroundStyle(.secondary).figureText()
                            }
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                PropertyFact("Final instalment") {
                    if let final = terms.effectiveFinalInstalmentDate { DateText(date: final) } else { Text("—").foregroundStyle(.secondary) }
                }
                PropertyFact("Balloon") {
                    if let balloon = terms.balloonMinorUnits {
                        MoneyText(minorUnits: balloon, currency: currency, role: .neutral)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Category groups

    private struct GroupRow: Identifiable {
        let id: Int64
        let name: String
    }

    private func groupsPanel(_ snapshot: PropertyViewModel.Snapshot) -> some View {
        let available = snapshot.groups.filter { !snapshot.groupIds.contains($0.id) }
        return Panel("Category groups", subtitle: "Where the property's income and costs are filed", fillsHeight: true) {
            if !available.isEmpty {
                Menu("Add group") {
                    ForEach(available) { group in
                        Button(group.name) { viewModel.addGroup(group.id) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .help("Add a category group holding the property's income or costs")
            }
        } content: {
            if snapshot.groupIds.isEmpty {
                Text("Add the category group holding the property's income and costs.").font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: [
                    .text("Group", { $0.name }),
                    .actions { group in
                        [DataTableAction("Remove \(group.name)", systemImage: "xmark.circle", inline: true) { viewModel.removeGroup(group.id) }]
                    }
                ], rows: snapshot.groupIds.map { GroupRow(id: $0, name: viewModel.groupName($0)) }, zebra: false)
            }
        }
    }

    // MARK: Documents

    private func documentsPanel(_ snapshot: PropertyViewModel.Snapshot) -> some View {
        Panel("Documents", subtitle: "Deeds, licences, energy certificates, the mortgage contract") {
            if let id = viewModel.propertyId {
                ImportShortcutButton("Add document…", shortcut: .attach(.property(id), role: nil, from: .property))
                    .controlSize(.small)
            }
        } content: {
            if snapshot.documents.isEmpty {
                Text("No documents yet: add the deeds and certificates with Add document….").font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: [
                    DataTableColumn("Name", width: .fill(min: 160), accessibilityValue: { $0.displayName }) { document, _ in
                        HStack(spacing: 6) {
                            Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                            Text(document.displayName).lineLimit(1).truncationMode(.middle)
                        }
                        .help(document.displayName)
                    },
                    .status("Kind") { StatusPill(kinds.displayName(of: $0)) },
                    .date("Date") { $0.docDate },
                    .actions { document in
                        [DataTableAction("Open \(document.displayName)", systemImage: "arrow.up.forward.square", inline: true) {
                            viewModel.open(document)
                         },
                         DataTableAction("Unlink \(document.displayName) (it stays in the library)", systemImage: "xmark.circle", inline: true) {
                            if let id = viewModel.propertyId { viewModel.unlinkDocument(document, from: .property(id)) }
                         }]
                    }
                ], rows: snapshot.documents, zebra: false)
            }
        }
    }
}

private extension String {
    /// "Every 3 months…" from "every 3 months…".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
