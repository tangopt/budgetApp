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

    @State private var editingProperty: PropertyDraft?
    @State private var editingOwners = false
    @State private var linkingAccount = false
    @State private var pickingDocument = false
    @State private var confirmingDelete = false
    @State private var editingPerson: Person?

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
            documentsPanel(snapshot)
        }
        .sheet(item: $editingProperty) { PropertyFormSheet(viewModel: viewModel, draft: $0) }
        .sheet(isPresented: $editingOwners) { OwnersSheet(viewModel: viewModel) }
        .sheet(item: $editingPerson) { PersonFormSheet(viewModel: viewModel, person: $0) }
        .sheet(isPresented: $linkingAccount) { LinkAccountSheet(viewModel: viewModel) }
        .fileImporter(isPresented: $pickingDocument, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            guard let id = viewModel.propertyId else { return }
            switch result {
            case .success(let urls): viewModel.addDocuments(urls, to: .property(id), role: nil)
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(snapshot.property.map { "Delete “\($0.name)”?" } ?? "Delete the property?", isPresented: $confirmingDelete) {
            Button("Delete property", role: .destructive) { viewModel.errorMessage = viewModel.deleteProperty() }
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
                        Text(PropertyFormat.percent(owner.shareBasisPoints)).monospacedDigit()
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
                                                          set: { viewModel.errorMessage = viewModel.setAccount(link.accountId, role: $0) })) {
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
            Button("Add document…") { pickingDocument = true }
                .controlSize(.small)
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
                    .status("Kind") { StatusPill($0.kind.displayName) },
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
