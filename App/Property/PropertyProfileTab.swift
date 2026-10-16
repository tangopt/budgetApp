// App/Property/PropertyProfileTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The Profile tab (spec 2026-10-16 §1): the property's details, owners and shares by date
/// range, linked accounts with their roles, category groups, and documents (deeds, licences).
struct PropertyProfileTab: View {
    @ObservedObject var viewModel: PropertyViewModel

    @State private var editingProperty: PropertyDraft?
    @State private var editingOwners = false
    @State private var linkingAccount = false
    @State private var pickingDocument = false
    @State private var confirmingDelete = false
    @State private var newGroupId: Int64?
    @State private var editingPerson: Person?

    var body: some View {
        let snapshot = viewModel.snapshot
        VStack(alignment: .leading, spacing: 12) {
            if let property = snapshot.property {
                PropertySection("Details", accessory: {
                    HStack(spacing: 8) {
                        Button("Edit…") { editingProperty = PropertyDraft(property) }
                        Button("Delete…", role: .destructive) { confirmingDelete = true }
                    }
                    .buttonStyle(.borderless)
                }) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        row("Name", property.name)
                        row("Country", property.country)
                        row("Currency", property.currency.rawValue.uppercased())
                        row("Matrix article", property.matrixArticle ?? "—")
                        GridRow {
                            Text("Purchase").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            HStack(spacing: 4) {
                                if let price = property.purchasePriceMinorUnits {
                                    PropertyMoney(minorUnits: price, currency: property.currency, neutral: true)
                                } else {
                                    Text("—")
                                }
                                if let date = property.purchaseDate { Text("on \(DocumentFormat.day(date))").foregroundStyle(.secondary) }
                            }
                        }
                        if let notes = property.notes { row("Notes", notes) }
                    }
                }
            }
            PropertySection("Owners", accessory: {
                Button("Edit owners…") { editingOwners = true }.buttonStyle(.borderless)
            }) {
                if snapshot.owners.isEmpty {
                    Text("No owners recorded. Shares drive each person's part of the rental income and costs.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(snapshot.owners) { owner in
                            GridRow {
                                Text(viewModel.personName(owner.personId))
                                Text(PropertyFormat.percent(owner.shareBasisPoints)).monospacedDigit().gridColumnAlignment(.trailing)
                                Text(ownerRange(owner)).foregroundStyle(.secondary)
                                Button("Edit person…") { editingPerson = snapshot.people.first { $0.id == owner.personId } }
                                    .buttonStyle(.borderless)
                                    .help("Name and tax identifiers (UTR, NI number, NIF)")
                                    .accessibilityLabel("Edit \(viewModel.personName(owner.personId))")
                            }
                        }
                    }
                }
            }
            PropertySection("Accounts", accessory: {
                Button("Link account…") { linkingAccount = true }.buttonStyle(.borderless)
            }) {
                if snapshot.propertyAccounts.isEmpty {
                    Text("Link the account rent arrives in (current), the mortgage and the deposit account.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.propertyAccounts) { link in
                        HStack {
                            Text(viewModel.accountName(link.accountId))
                            Picker("Role", selection: Binding(get: { link.role }, set: { viewModel.errorMessage = viewModel.setAccount(link.accountId, role: $0) })) {
                                ForEach(PropertyAccountRole.allCases, id: \.self) { Text(PropertyFormat.role($0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("Role of \(viewModel.accountName(link.accountId))")
                            Spacer()
                            Button("Unlink") { viewModel.removeAccount(link.accountId) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            PropertySection("Category groups") {
                VStack(alignment: .leading, spacing: 6) {
                    if snapshot.groupIds.isEmpty {
                        Text("Add the category group holding the property's income and costs.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.groupIds, id: \.self) { id in
                        HStack {
                            Text(viewModel.groupName(id))
                            Spacer()
                            Button("Remove") { viewModel.removeGroup(id) }.buttonStyle(.borderless)
                        }
                    }
                    let available = snapshot.groups.filter { !snapshot.groupIds.contains($0.id) }
                    if !available.isEmpty {
                        Picker("Add group", selection: $newGroupId) {
                            Text("Add a group…").tag(Int64?.none)
                            ForEach(available) { Text($0.name).tag(Int64?.some($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Add a category group")
                        .onChange(of: newGroupId) { _, id in
                            if let id { viewModel.addGroup(id); newGroupId = nil }
                        }
                    }
                }
            }
            PropertySection("Documents", accessory: {
                Button("Add document…") { pickingDocument = true }.buttonStyle(.borderless)
            }) {
                if snapshot.documents.isEmpty {
                    Text("Deeds, licences, energy certificates, the mortgage contract…").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.documents) { document in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(document.displayName).lineLimit(1)
                            Text(document.kind.displayName).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Open") { viewModel.open(document) }.buttonStyle(.borderless)
                            Button("Unlink") {
                                if let id = viewModel.propertyId { viewModel.unlinkDocument(document, from: .property(id)) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
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
        .confirmationDialog("Delete \(snapshot.property?.name ?? "the property")?", isPresented: $confirmingDelete) {
            Button("Delete property", role: .destructive) { viewModel.errorMessage = viewModel.deleteProperty() }
        } message: {
            Text("Its owners, account and group links, tenancies, rents, receipts and their credit links go. Transactions and documents stay.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ownerRange(_ owner: PropertyOwner) -> String {
        switch (owner.fromDate, owner.toDate) {
        case let (from?, to?): return "\(DocumentFormat.day(from)) – \(DocumentFormat.day(to))"
        case let (from?, nil): return "From \(DocumentFormat.day(from))"
        case let (nil, to?): return "Until \(DocumentFormat.day(to))"
        default: return "Always"
        }
    }
}
