import SwiftUI
import MapKit
import BudgetCore
import struct BudgetCore.Property

/// Property ▸ Profile on the iPad (step 10, Task 16): cards for the property's details, its address and the map (Apple Maps
/// finds the address at the user's action; the pin can be placed or dragged by hand, saved only on Save location), the
/// owners and their shares, the mortgage (the rate its rules give now, the next revision and instalment, the instalments
/// and balloon, Edit terms), the linked accounts with their roles, the category groups and the documents. Every Mac edit is
/// here with Edit on Property (hidden otherwise); people are added and edited on the Mac. A refusal shows under its card.
struct PadProfileView: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Selects a library document on the Documents screen.
    let showDocument: (Int64) -> Void
    @State private var editingDetails: PadPropertyDraft?
    @State private var editingOwners: PadOwnersDraft?
    @State private var editingTerms: MortgageTermsEditing.Form?
    @State private var editingAddress: PropertyAddress?
    @State private var linkingAccount = false
    @State private var confirmingDelete = false
    @State private var request: PadChoiceRequest?
    @StateObject private var locator = PadPropertyLocator()
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PadSpacing.section) {
                    PadWriteNotices(write: write)
                    if let property = model.snapshot.property {
                        // Cards two (or more) to a row, each row's cards as tall as its tallest.
                        PadGrid(minimumColumnWidth: 380, balanced: false) {
                            detailsCard(property)
                            addressCard(property)
                            PadPropertyMapCard(model: model, locator: locator, property: property)
                            ownersCard
                            mortgageCard
                            accountsCard
                            groupsCard
                            documentsCard
                        }
                        .padEqualHeightCards()
                    } else {
                        EmptyState(symbol: "person.text.rectangle", title: "No property",
                                   message: "The property's profile appears here once the Mac has shared it.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Profile")
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await write.refresh()
            await model.property.reload()
            await model.reload()
        }
        .sheet(item: $editingDetails) { PadPropertyFormSheet(model: model, write: write, draft: $0) }
        .sheet(item: $editingOwners) { PadOwnersSheet(model: model, write: write, draft: $0) }
        .sheet(item: Binding(get: { editingTerms.map(TermsBox.init) }, set: { editingTerms = $0?.form })) { box in
            PadMortgageTermsSheet(model: model, write: write, form: box.form)
        }
        .sheet(item: Binding(get: { editingAddress.map(AddressBox.init) }, set: { editingAddress = $0?.address })) { box in
            PadAddressSheet(model: model, write: write, address: box.address) { text in
                Task { await locator.lookUp(text) { coordinate in await model.setLocation(coordinate, source: .lookedUp) } }
            }
        }
        .sheet(isPresented: $linkingAccount) { PadLinkAccountSheet(model: model, write: write) }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
        .confirmationDialog(model.snapshot.property.map { "Delete “\($0.name)”?" } ?? "Delete the property?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete property", role: .destructive) { Task { await model.deleteProperty() } }
        } message: {
            Text("Its owners, account and group links, tenancies, rents, receipts and their credit links go. Transactions and documents stay. This can't be undone.")
        }
    }

    private struct TermsBox: Identifiable {
        let id = UUID()
        let form: MortgageTermsEditing.Form
    }

    private struct AddressBox: Identifiable {
        let id = UUID()
        let address: PropertyAddress
    }

    private func offers(_ action: PadProfileAction, on card: PadProfileModel.Card) -> Bool { model.actions(for: card).contains(action) }

    // MARK: Details

    private func detailsCard(_ property: Property) -> some View {
        ProfileCard(title: "Details", message: model.message(for: .details)) {
            if offers(.editDetails, on: .details) {
                Button("Edit") { editingDetails = model.detailsDraft() }.buttonStyle(.pad(.secondary, size: .small))
            }
            if offers(.deleteProperty, on: .details) {
                Menu {
                    Button("Delete property…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").mangoFont(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More actions for the property")
            }
        } content: {
            ProfileFact("Name") { Text(property.name).lineLimit(1).truncationMode(.middle) }
            ProfileFact("Country") { Text(property.country) }
            ProfileFact("Currency") { Text(property.currency.rawValue.uppercased()) }
            ProfileFact("Matrix article") { Text(property.matrixArticle?.isEmpty == false ? property.matrixArticle! : "—") }
            ProfileFact("Purchase price") {
                if let price = property.purchasePriceMinorUnits {
                    MoneyText(minorUnits: price, currency: property.currency, role: .neutral, font: .subheadline)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            ProfileFact("Purchased on") { DateText(property.purchaseDate, font: .subheadline) }
            if let notes = property.notes, !notes.isEmpty {
                ProfileFact("Notes") { Text(notes).lineLimit(2) }
            }
        }
    }

    // MARK: Address

    private func addressCard(_ property: Property) -> some View {
        let address = property.postalAddress
        return ProfileCard(title: "Address", subtitle: "Found on the map with Apple Maps when you save it", message: model.message(for: .address)) {
            if offers(.editAddress, on: .address) {
                Button("Edit") { editingAddress = address }.buttonStyle(.pad(.secondary, size: .small))
            }
        } content: {
            if address.isEmpty {
                Text("No address yet: add it with Edit, and Apple Maps finds it on the map.")
                    .mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ProfileFact("Street") {
                    Text(address.streetLines.isEmpty ? "—" : address.streetLines.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                ProfileFact("Postcode") { Text(property.postcode ?? "—") }
                ProfileFact("City") { Text(property.city ?? "—") }
                ProfileFact("Country") { Text(property.country) }
            }
        }
    }

    // MARK: Owners

    private var ownersCard: some View {
        ProfileCard(title: "Owners", subtitle: "Shares drive each person's part of the rental income and costs",
                    message: model.message(for: .owners)) {
            if offers(.editOwners, on: .owners) {
                Button("Edit") { editingOwners = model.ownersDraft() }.buttonStyle(.pad(.secondary, size: .small))
            }
        } content: {
            if model.snapshot.owners.isEmpty {
                Text("No owners yet.").mangoFont(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.owners, id: \.id) { owner in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.personName(owner.personId)).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                        Text(Self.ownedFrom(owner).figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(PadProfileModel.percent(owner.shareBasisPoints)).figureText().mangoFont(.subheadline, figures: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func ownedFrom(_ owner: PropertyOwner) -> String {
        let from = owner.fromDate.map { "From \(PhoneDateFormat.day($0))" } ?? "Since purchase"
        return owner.toDate.map { "\(from) to \(PhoneDateFormat.day($0))" } ?? from
    }

    // MARK: Mortgage

    private var mortgageCard: some View {
        let facts = model.mortgage
        return ProfileCard(title: "Mortgage", subtitle: "The rate from the loan's rules, for the calendar and the loan chart",
                           message: model.message(for: .mortgage)) {
            if offers(.editMortgageTerms, on: .mortgage) {
                Button("Edit terms") { editingTerms = model.mortgageForm() }
                    .buttonStyle(.pad(.secondary, size: .small))
                    .accessibilityHint("The index, spread, revisions, instalments and balloon")
            }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rate").mangoFont(.subheadline).foregroundStyle(.secondary)
                Text(facts.rate).mangoFont(.subheadline, figures: true).foregroundStyle(facts.rateIsSet ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProfileFact("Next revision") { Text(facts.nextRevision.unbroken).monospacedDigit() }
            Text(facts.schedule).mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProfileFact("Next instalment") { Text((facts.nextInstalment ?? "—").figuresUnbroken).monospacedDigit() }
            ProfileFact("Instalments") { Text((facts.instalments ?? "—").figuresUnbroken).monospacedDigit() }
            ProfileFact("Final instalment") { Text((facts.finalInstalment ?? "—").unbroken).monospacedDigit() }
            ProfileFact("Balloon") {
                if let balloon = facts.balloonMinorUnits {
                    MoneyText(minorUnits: balloon, currency: model.currency, role: .neutral, font: .subheadline)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Accounts

    private var accountsCard: some View {
        ProfileCard(title: "Accounts", subtitle: "Where rent arrives, the mortgage and the deposit held", message: model.message(for: .accounts)) {
            if offers(.linkAccount, on: .accounts), !model.availableAccounts.isEmpty {
                Button("Link account") { linkingAccount = true }.buttonStyle(.pad(.secondary, size: .small))
            }
        } content: {
            if model.snapshot.propertyAccounts.isEmpty {
                Text("Link the account rent arrives in (current), the mortgage and the deposit account.")
                    .mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.snapshot.propertyAccounts, id: \.accountId) { link in
                let name = model.accountName(link.accountId)
                HStack(spacing: 8) {
                    Text(name).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if offers(.changeRole, on: .accounts) {
                        Picker("Role of \(name)", selection: Binding(get: { link.role }, set: { role in
                            Task { await model.setAccount(link.accountId, role: role) }
                        })) {
                            ForEach(PropertyAccountRole.allCases, id: \.self) { Text(PadProfileModel.role($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(PadProfileModel.role(link.role)).mangoFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if offers(.unlinkAccount, on: .accounts) {
                        RowIconButton(.unlink, item: name, size: .small) { Task { await model.unlinkAccount(link.accountId) } }
                    }
                }
            }
        }
    }

    // MARK: Groups

    private var groupsCard: some View {
        ProfileCard(title: "Category groups", subtitle: "Where the property's income and costs are filed", message: model.message(for: .groups)) {
            if offers(.addGroup, on: .groups), !model.availableGroups.isEmpty {
                Menu {
                    ForEach(model.availableGroups) { group in
                        Button(group.name) { Task { await model.addGroup(group.id) } }
                    }
                } label: {
                    Text("Add group")
                }
                .buttonStyle(.pad(.secondary, size: .small))
            }
        } content: {
            if model.snapshot.groupIds.isEmpty {
                Text("Add the category group holding the property's income and costs.").mangoFont(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.groupIds, id: \.self) { id in
                let name = model.groupName(id)
                HStack(spacing: 8) {
                    Text(name).mangoFont(.subheadline).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    if offers(.removeGroup, on: .groups) {
                        RowIconButton(.unlink, item: name, size: .small) { Task { await model.removeGroup(id) } }
                    }
                }
            }
        }
    }

    // MARK: Documents

    private var documentsCard: some View {
        ProfileCard(title: "Documents", subtitle: "Deeds, licences, energy certificates, the mortgage contract", message: model.message(for: .documents)) {
            if offers(.linkDocument, on: .documents) {
                RowIconButton(.linkDocument, item: "the property", size: .small) { Task { await chooseDocument() } }
            }
        } content: {
            if model.snapshot.documents.isEmpty {
                Text("No documents yet: link the deeds and certificates from the library.").mangoFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.snapshot.documents, id: \.id) { document in
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.displayName).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                        Text(([document.id.flatMap { model.snapshot.documentKinds[$0] }, document.docDate.map { PhoneDateFormat.day($0) }]
                            .compactMap { $0 }.joined(separator: " · ")).figuresUnbroken)
                            .mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let id = document.id {
                        RowIconButton(.view, item: document.displayName, size: .small) { showDocument(id) }
                        if offers(.unlinkDocument, on: .documents) {
                            RowIconButton(.unlink, item: document.displayName, size: .small) { Task { await model.unlinkDocument(id) } }
                        }
                    }
                }
            }
        }
    }

    private func chooseDocument() async {
        let candidates = await model.documentCandidates()
        request = PadChoiceRequest(
            title: "Link a document", button: "Link", empty: "Every document in the library is linked already.", currency: model.currency,
            choices: candidates.compactMap { document in
                document.id.map { PadChoice(id: $0, title: document.displayName, date: document.docDate, amountMinorUnits: nil) }
            },
            choose: { id in await model.linkDocument(id) })
    }
}

// MARK: - Card parts

/// A Profile card: its title (and what it is for), its own actions in the corner, the facts, then any refusal.
private struct ProfileCard<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    let message: String?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, message: String?, @ViewBuilder actions: @escaping () -> Actions,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.actions = actions
        self.content = content
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).mangoFont(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle).mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions()
                }
                content()
                PadRefusalBanner(message: message)
            }
        }
    }
}

/// A label and its value on one line, the value trailing.
private struct ProfileFact<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value

    init(_ label: String, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            value()
        }
        .mangoFont(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sheets

/// Edit details: name, country, currency, matrix article, purchase price and date, notes. Saved only with Save.
struct PadPropertyFormSheet: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    @State var draft: PadPropertyDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: model.message(for: .details)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Lisbon flat")).frame(minHeight: 44)
                    TextField("Country", text: $draft.country, prompt: Text("Two letters, e.g. PT")).frame(minHeight: 44)
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    TextField("Matrix article", text: $draft.matrixArticle, prompt: Text("Artigo matricial")).frame(minHeight: 44)
                }
                Section("Purchase") {
                    TextField("Purchase price", text: $draft.priceText, prompt: Text("Purchase price"))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .frame(minHeight: 44)
                    Toggle("Purchase date known", isOn: $draft.hasPurchaseDate).frame(minHeight: 44)
                    if draft.hasPurchaseDate {
                        DatePicker("Purchased on", selection: Binding(get: { draft.purchaseDate ?? model.utcToday },
                                                                      set: { draft.purchaseDate = MonthRange.calendar.startOfDay(for: $0) }),
                                   displayedComponents: .date)
                            .frame(minHeight: 44)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4)
                }
            }
            .environment(\.calendar, MonthRange.calendar)
            .environment(\.timeZone, MonthRange.calendar.timeZone)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Edit property")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let saved = await model.save(draft)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!draft.canSave || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }
}

/// Edit owners: every ownership row (person, share, from, to), saved together so the shares are checked as a whole.
/// People are chosen among those the household has (added on the Mac).
struct PadOwnersSheet: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    @State var draft: PadOwnersDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: model.message(for: .owners)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                ForEach($draft.rows) { $row in
                    Section {
                        Picker("Person", selection: $row.personId) {
                            Text("Choose…").tag(Int64?.none)
                            ForEach(model.snapshot.people) { person in Text(person.name).tag(person.id) }
                        }
                        .frame(minHeight: 44)
                        HStack(spacing: 8) {
                            Text("Share")
                            Spacer(minLength: 8)
                            TextField("Share", text: $row.shareText)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("%").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        optionalDay("From", unset: "Since purchase", day: $row.from)
                        optionalDay("To", unset: "Ongoing", day: $row.to)
                        Button("Remove this owner", role: .destructive) { draft.rows.removeAll { $0.id == row.id } }
                            .frame(minHeight: 44)
                    }
                }
                Section {
                    Button { draft.rows.append(.init()) } label: { Label("Add owner", systemImage: "plus") }.frame(minHeight: 44)
                } footer: {
                    Text("On any day someone owns the property, the shares must add up to 100%. People are added on the Mac.")
                }
            }
            .environment(\.calendar, MonthRange.calendar)
            .environment(\.timeZone, MonthRange.calendar.timeZone)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Owners")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let saved = await model.save(draft)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder
    private func optionalDay(_ label: String, unset: String, day: Binding<Date?>) -> some View {
        Toggle(isOn: Binding(get: { day.wrappedValue != nil }, set: { day.wrappedValue = $0 ? model.utcToday : nil })) {
            Text(day.wrappedValue == nil ? "\(label): \(unset.lowercased())" : label)
        }
        .frame(minHeight: 44)
        if day.wrappedValue != nil {
            DatePicker(label, selection: Binding(get: { day.wrappedValue ?? model.utcToday },
                                                 set: { day.wrappedValue = MonthRange.calendar.startOfDay(for: $0) }),
                       displayedComponents: .date)
                .frame(minHeight: 44)
        }
    }
}

/// Link account: an account not yet linked and its role.
struct PadLinkAccountSheet: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var accountId: Int64?
    @State private var role = PropertyAccountRole.current
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: model.message(for: .accounts)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    Picker("Account", selection: $accountId) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(model.availableAccounts) { account in Text(account.displayName).tag(account.id) }
                    }
                    .frame(minHeight: 44)
                    Picker("Role", selection: $role) {
                        ForEach(PropertyAccountRole.allCases, id: \.self) { Text(PadProfileModel.role($0)).tag($0) }
                    }
                    .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Link account")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") {
                        guard let accountId else { return }
                        saving = true
                        Task {
                            let saved = await model.setAccount(accountId, role: role)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(accountId == nil || saving)
                }
            }
        }
    }
}

/// Edit address: the street lines, postcode, city and country. Saved only on Save; a changed address is then looked up on
/// the map (`PropertyLocationPlan`), after asking when the pin was placed by hand.
struct PadAddressSheet: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    @State var address: PropertyAddress
    /// Called after the save with the text to look up, when the plan says to.
    let onLookUp: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var askingToReplace: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: model.message(for: .address)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    TextField("Street", text: $address.lines, prompt: Text("Street and number, floor, door"), axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Postcode", text: $address.postcode, prompt: Text("e.g. 1000-001")).frame(minHeight: 44)
                    TextField("City", text: $address.city, prompt: Text("e.g. Lisboa")).frame(minHeight: 44)
                    TextField("Country", text: $address.country, prompt: Text("Two letters, e.g. PT")).frame(minHeight: 44)
                } footer: {
                    Text("Saving a changed address finds it on the map with Apple Maps. Only the address text is sent, and only then.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Edit address")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(saving) }
            }
            .confirmationDialog("Find the new address on the map?", isPresented: Binding(get: { askingToReplace != nil },
                                                                                         set: { if !$0 { askingToReplace = nil } })) {
                Button("Find the new address") { commit(clearingLocation: false, lookUp: askingToReplace) }
                Button("Keep my pin") { commit(clearingLocation: false, lookUp: nil) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You placed the pin by hand. Finding the new address with Apple Maps replaces it.")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let current = model.snapshot.property
        switch PropertyLocationPlan.plan(old: current, newAddress: address) {
        case .keep: commit(clearingLocation: false, lookUp: nil)
        case .clearLookedUp: commit(clearingLocation: true, lookUp: nil)
        // A looked-up pin belongs to the old address: it goes, and the new one is looked up.
        case .lookUp(let text): commit(clearingLocation: current?.locationSource != .adjusted, lookUp: text)
        case .askBeforeReplacing(let text): askingToReplace = text
        }
    }

    private func commit(clearingLocation: Bool, lookUp: String?) {
        saving = true
        Task {
            let saved = await model.saveAddress(address, clearingLocation: clearingLocation)
            saving = false
            guard saved else { return }
            dismiss()
            if let lookUp { onLookUp(lookUp) }
        }
    }
}

// MARK: - Map

/// Finds an address with Apple Maps (only the address text is sent, at the user's action) and stores the one match,
/// offers several, or says it found nothing.
@MainActor
final class PadPropertyLocator: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let coordinate: PropertyCoordinate
    }

    enum State: Equatable {
        case idle, searching, notFound
        case choices([Candidate])
    }

    @Published private(set) var state: State = .idle

    /// Looks `text` up; with one match, `save` stores it.
    func lookUp(_ text: String, save: @escaping (PropertyCoordinate) async -> Bool) async {
        state = .searching
        let candidates = (try? await Self.geocode(text)) ?? []
        switch candidates.count {
        case 0: state = .notFound
        case 1:
            _ = await save(candidates[0].coordinate)
            state = .idle
        default: state = .choices(candidates)
        }
    }

    func reset() { state = .idle }

    private static func geocode(_ text: String) async throws -> [Candidate] {
        // The snapshot harness never uses the network.
        guard !WrapProbeRegistry.shared.isActive, let request = MKGeocodingRequest(addressString: text) else { return [] }
        let items = try await request.mapItems
        var seen = Set<String>()
        return items.compactMap { item in
            let point = item.location.coordinate
            let coordinate = PropertyCoordinate(latitude: point.latitude, longitude: point.longitude)
            guard coordinate.isValid, seen.insert(String(format: "%.5f,%.5f", point.latitude, point.longitude)).inserted else { return nil }
            let title = item.address?.fullAddress ?? item.name ?? text
            return Candidate(title: title.replacingOccurrences(of: "\n", with: ", "), coordinate: coordinate)
        }
    }
}

/// The map card: the pin as stored, Find on map (Apple Maps from the address text) and Adjust location (tap the map or drag
/// the pin, then Save location; Cancel leaves it). Lookup results and failures show above the map.
struct PadPropertyMapCard: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var locator: PadPropertyLocator
    let property: Property
    @State private var adjusting = false
    @State private var pending: PropertyCoordinate?

    var body: some View {
        ProfileCard(title: "Map", message: model.message(for: .map)) {
            accessory
        } content: {
            status
            PadPropertyMapView(coordinate: adjusting ? pending : property.location, isAdjusting: adjusting, country: property.country) {
                pending = $0
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if !adjusting, property.location == nil, locator.state != .searching {
                    Text(property.postalAddress.isEmpty ? "Add the address to find it on the map" : "No location yet")
                        .mangoFont(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            note
        }
    }

    @ViewBuilder private var accessory: some View {
        if adjusting {
            Button("Cancel") { adjusting = false; pending = nil }.buttonStyle(.pad(.secondary, size: .small))
            Button("Save location") { Task { await saveAdjusted() } }
                .buttonStyle(.pad(.primary, size: .small))
                .disabled(pending == nil || pending == property.location)
        } else {
            let actions = model.actions(for: .map)
            if actions.contains(.findOnMap), let text = property.postalAddress.searchText {
                Button { Task { await locator.lookUp(text) { await model.setLocation($0, source: .lookedUp) } } } label: {
                    Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
                }
                .buttonStyle(.pad(.secondary, size: .small))
                .disabled(locator.state == .searching)
                .accessibilityLabel("Find on map")
            }
            if actions.contains(.adjustLocation) {
                Button { pending = property.location; adjusting = true } label: {
                    Image(systemName: property.location == nil ? "mappin.and.ellipse" : "hand.point.up.left").frame(width: 36, height: 36)
                }
                .buttonStyle(.pad(.secondary, size: .small))
                .accessibilityLabel(property.location == nil ? "Place on map" : "Adjust location")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch locator.state {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 6) {
                ProgressView()
                Text("Finding the address with Apple Maps…").mangoFont(.callout).foregroundStyle(.secondary)
            }
        case .notFound:
            Label("Location not found — place it on the map", systemImage: "mappin.slash").mangoFont(.callout).foregroundStyle(.secondary)
        case .choices(let candidates):
            VStack(alignment: .leading, spacing: 4) {
                Text("Several places match the address: pick one").mangoFont(.callout).foregroundStyle(.secondary)
                ForEach(candidates.prefix(5)) { candidate in
                    Button {
                        Task {
                            if await model.setLocation(candidate.coordinate, source: .lookedUp) { locator.reset() }
                        }
                    } label: {
                        Label(candidate.title, systemImage: "mappin").lineLimit(1).truncationMode(.middle)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var note: some View {
        if adjusting {
            Text("Tap the map or drag the pin, then Save location.").mangoFont(.footnote).foregroundStyle(.secondary)
        } else if let location = property.location {
            HStack(spacing: 6) {
                Text(property.locationSource == .adjusted ? "Placed by hand" : "Found with Apple Maps").lineLimit(1)
                Text("·")
                Text(Self.coordinate(location)).monospacedDigit().figureText()
            }
            .mangoFont(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Apple Maps finds it from the address text only").mangoFont(.footnote).foregroundStyle(.secondary)
        }
    }

    private func saveAdjusted() async {
        guard let pending else { return }
        if await model.setLocation(pending, source: .adjusted) {
            locator.reset()
            adjusting = false
            self.pending = nil
        }
    }

    /// "38.7223° N, 9.1393° W".
    static func coordinate(_ coordinate: PropertyCoordinate) -> String {
        let lat = String(format: "%.4f° %@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.4f° %@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}

/// A MapKit map with the property's pin. Read-only unless `isAdjusting`: then it pans and zooms, a tap places the pin and
/// the pin drags. The snapshot harness draws a placeholder instead (no tiles, no network).
struct PadPropertyMapView: View {
    let coordinate: PropertyCoordinate?
    let isAdjusting: Bool
    let country: String
    var onPlace: (PropertyCoordinate) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var dragStart: CGPoint?
    private static let space = "padPropertyMap"

    var body: some View {
        if WrapProbeRegistry.shared.isActive {
            placeholder
        } else {
            map
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: isAdjusting ? .all : []) {
                if let coordinate {
                    let point = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    if isAdjusting {
                        Annotation("Property", coordinate: point, anchor: .bottom) {
                            Image(systemName: "mappin")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.red)
                                .shadow(radius: 1)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    DragGesture(coordinateSpace: .named(Self.space))
                                        .onChanged { value in
                                            if dragStart == nil { dragStart = proxy.convert(point, to: .named(Self.space)) }
                                            guard let start = dragStart else { return }
                                            let moved = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                                            if let place = proxy.convert(moved, from: .named(Self.space)) {
                                                onPlace(PropertyCoordinate(latitude: place.latitude, longitude: place.longitude))
                                            }
                                        }
                                        .onEnded { _ in dragStart = nil }
                                )
                                .accessibilityLabel("Property pin: drag to move it")
                        }
                    } else {
                        Marker("Property", systemImage: "house.fill", coordinate: point)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .coordinateSpace(.named(Self.space))
            .onTapGesture(coordinateSpace: .named(Self.space)) { point in
                guard isAdjusting, let placed = proxy.convert(point, from: .named(Self.space)) else { return }
                onPlace(PropertyCoordinate(latitude: placed.latitude, longitude: placed.longitude))
            }
        }
        .onAppear { position = Self.camera(for: coordinate, country: country) }
        .onChange(of: coordinate) { _, new in
            // Follows a stored location; while the pin is being placed the camera stays where the user put it.
            if !isAdjusting { position = Self.camera(for: new, country: country) }
        }
        .onChange(of: isAdjusting) { _, adjusting in
            if !adjusting { position = Self.camera(for: coordinate, country: country) }
        }
        .accessibilityLabel(coordinate.map { "Map: the property at \(PadPropertyMapCard.coordinate($0))" } ?? "Map: no location yet")
    }

    private static func camera(for coordinate: PropertyCoordinate?, country: String) -> MapCameraPosition {
        if let coordinate {
            return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                              latitudinalMeters: 900, longitudinalMeters: 900))
        }
        // No location yet: the country when it's Portugal (the usual case), else the world.
        if country.uppercased() == "PT" {
            return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.6, longitude: -8.0),
                                              span: MKCoordinateSpan(latitudeDelta: 6.5, longitudeDelta: 6.5)))
        }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
                                          span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)))
    }

    /// A drawn street grid with the pin, no tiles (the note below gives the coordinate).
    private var placeholder: some View {
        ZStack {
            Color.green.opacity(0.10)
            Canvas { context, size in
                var streets = Path()
                for step in stride(from: CGFloat(0.12), to: 1, by: 0.22) {
                    streets.move(to: CGPoint(x: 0, y: size.height * step))
                    streets.addLine(to: CGPoint(x: size.width, y: size.height * (step + 0.08)))
                    streets.move(to: CGPoint(x: size.width * step, y: 0))
                    streets.addLine(to: CGPoint(x: size.width * (step - 0.05), y: size.height))
                }
                context.stroke(streets, with: .color(.secondary.opacity(0.35)), lineWidth: 5)
            }
            if coordinate != nil {
                Image(systemName: "house.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .red)
            }
        }
        .accessibilityLabel("Map")
    }
}
