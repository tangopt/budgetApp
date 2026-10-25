// App/Property/PropertySheets.swift
import SwiftUI
import BudgetCore

// MARK: - Property

/// New property / Edit property's fields.
struct PropertyDraft: Identifiable {
    let id = UUID()
    let existing: Property?
    var name = ""
    var country = "PT"
    var currency = Currency.eur
    var matrixArticle = ""
    var priceText = ""
    var hasPurchaseDate = false
    var purchaseDate: Date? = nil
    var notes = ""

    init(_ property: Property?) {
        existing = property
        guard let property else { return }
        name = property.name
        country = property.country
        currency = property.currency
        matrixArticle = property.matrixArticle ?? ""
        priceText = property.purchasePriceMinorUnits.map(Money.formatInput) ?? ""
        hasPurchaseDate = property.purchaseDate != nil
        purchaseDate = property.purchaseDate
        notes = property.notes ?? ""
    }
}

struct PropertyFormSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @State var draft: PropertyDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()

    var body: some View { form.filedYearGate(gate) }

    @ViewBuilder private var form: some View {
        SheetScaffold(title: draft.existing == nil ? "New property" : "Edit property", error: error, width: SheetMetrics.compactWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction(draft.existing == nil ? "Add property" : "Save",
                                           isEnabled: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $draft.name, prompt: Text("e.g. Lisbon flat")) }
                LabeledContent("Country") {
                    TextField("Country", text: $draft.country, prompt: Text("PT")).frame(width: 60)
                        .sheetFieldNote("Two letters, e.g. PT")
                }
                LabeledContent("Currency") {
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .pickerStyle(.segmented).prominentTint().fixedSize()
                }
                LabeledContent("Matrix article") { TextField("Matrix article", text: $draft.matrixArticle, prompt: Text("Artigo matricial")) }
                LabeledContent("Purchase price") { MoneyField("Purchase price", text: $draft.priceText, currency: draft.currency, width: 140) }
                LabeledContent("Purchase date") {
                    HStack(spacing: 10) {
                        // Named beside the tick: a SheetForm row hides its controls' own labels.
                        NamedCheckbox(title: "Known", isOn: $draft.hasPurchaseDate)
                        if draft.hasPurchaseDate {
                            DatePicker("Purchase date", selection: utcOptionalDay($draft.purchaseDate, default: PropertyDays.utcToday(AppClock.now)),
                                       displayedComponents: .date)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                LabeledContent("Notes") { TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4) }
            }
        }
    }

    private func save() {
        let priceText = draft.priceText.trimmingCharacters(in: .whitespaces)
        let price = priceText.isEmpty ? nil : Money.parseMinorUnits(priceText)
        if !priceText.isEmpty, price == nil { error = MoneyField.invalidAmountMessage(priceText); return }
        var property = draft.existing ?? Property(name: "", country: "")
        property.name = draft.name
        property.country = draft.country
        property.currency = draft.currency
        property.matrixArticle = draft.matrixArticle
        property.purchasePriceMinorUnits = price
        property.purchaseDate = draft.hasPurchaseDate ? (draft.purchaseDate ?? PropertyDays.utcToday(AppClock.now)) : nil
        property.notes = draft.notes
        viewModel.saveProperty(property, gate: gate) { result in
            switch result {
            case .success(let id):
                viewModel.onPropertiesChanged?(id)
                dismiss()
            case .failure(let failure):
                error = PropertyMessages.text(for: failure)
            }
        }
    }
}

// MARK: - Owners

/// Edit owners…: every ownership row (person, share, from, to), saved together so the shares
/// are checked as a whole (`Properties.setOwners`). New person… adds someone to choose.
struct OwnersSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id = UUID()
        var personId: Int64?
        var shareText = "100"
        var from: Date?
        var to: Date?
    }

    @State private var rows: [Row] = []
    @State private var error: String?
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()
    @State private var addingPerson = false

    init(viewModel: PropertyViewModel) {
        self.viewModel = viewModel
    }

    #if SNAPSHOTS
    /// Rows as entered and Save's error (the snapshot harness: a sheet showing an error).
    init(viewModel: PropertyViewModel, rows: [Row], error: String) {
        self.viewModel = viewModel
        _rows = State(initialValue: rows)
        _error = State(initialValue: error)
    }
    #endif

    var body: some View { form.filedYearGate(gate) }

    @ViewBuilder private var form: some View {
        SheetScaffold(title: "Owners", subtitle: "On any day someone owns the property, the shares must add up to 100%.",
                      error: error, width: SheetMetrics.listWidth, onCancel: { dismiss() }, primary: SheetAction("Save", action: save)) {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty {
                    SheetEmptyState(systemImage: "person.2", title: "No owners", message: "Add each owner with their share.", minHeight: 110)
                } else {
                    DataTable(columns: columns, rows: rows, zebra: false)
                }
                HStack(spacing: 8) {
                    Button { rows.append(Row()) } label: { Label("Add owner", systemImage: "plus") }
                    Button("New person…") { addingPerson = true }
                        .help("Add someone to choose as an owner")
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            guard rows.isEmpty else { return }
            rows = viewModel.snapshot.owners.map {
                Row(personId: $0.personId, shareText: PropertyFormat.percent($0.shareBasisPoints).replacingOccurrences(of: "%", with: ""),
                    from: $0.fromDate, to: $0.toDate)
            }
            if rows.isEmpty { rows = [Row()] }
        }
        .sheet(isPresented: $addingPerson) { PersonFormSheet(viewModel: viewModel, person: nil) }
    }

    /// The owners as a table (the Profile tab's columns): person, share, from and to, and a
    /// remove icon. Cells find their row by id, so removing a row can't leave a field pointing
    /// at the wrong owner.
    private var columns: [DataTableColumn<Row>] {
        [
            DataTableColumn("Person", width: .fill(min: 160)) { row, _ in
                Picker("Person", selection: binding(row.id, \.personId, fallback: nil)) {
                    Text("Choose…").tag(Int64?.none)
                    ForEach(viewModel.snapshot.people) { person in Text(person.name).tag(person.id) }
                }
                .labelsHidden()
                .fixedSize()
            },
            DataTableColumn("Share", alignment: .trailing) { row, _ in
                HStack(spacing: 4) {
                    TextField("Share", text: binding(row.id, \.shareText, fallback: ""))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 60)
                        .accessibilityLabel("Share percent")
                    Text("%").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            },
            DataTableColumn("From") { row, _ in
                optionalDay(binding(row.id, \.from, fallback: nil), label: "From", unset: "Since purchase")
            },
            DataTableColumn("To") { row, _ in
                optionalDay(binding(row.id, \.to, fallback: nil), label: "To", unset: "Ongoing")
            },
            .actions { row in
                [DataTableAction("Remove \(personName(row.personId))", systemImage: "minus.circle", inline: true) { rows.removeAll { $0.id == row.id } }]
            }
        ]
    }

    /// The row's person by name, for its remove icon ("this owner" until one is chosen).
    private func personName(_ id: Int64?) -> String {
        viewModel.snapshot.people.first { $0.id == id && id != nil }?.name ?? "this owner"
    }

    /// A field of the row `id` as a binding, by id (`fallback` once the row is gone; a write
    /// to a row that's gone does nothing).
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Row, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { rows.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                    rows[index][keyPath: keyPath] = value
                })
    }

    /// A tick for "has a date", then the day — or, unticked, what no date means ("Since
    /// purchase", "Ongoing"; clicking it ticks the box).
    private func optionalDay(_ day: Binding<Date?>, label: String, unset: String) -> some View {
        let isSet = Binding(get: { day.wrappedValue != nil },
                            set: { day.wrappedValue = $0 ? PropertyDays.utcToday(AppClock.now) : nil })
        let toggle = Toggle(label, isOn: isSet)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(label) date")
            .help(isSet.wrappedValue ? "Untick for no \(label.lowercased()) date (\(unset.lowercased()))" : "Tick to enter a \(label.lowercased()) date")
        return HStack(spacing: 6) {
            if isSet.wrappedValue {
                toggle
            } else {
                // Unticked, the box says what no date means (the text beside it is hidden).
                toggle.accessibilityValue(unset)
            }
            if day.wrappedValue != nil {
                DatePicker(label, selection: utcOptionalDay(day, default: PropertyDays.utcToday(AppClock.now)), displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
            } else {
                Text(unset)
                    .foregroundStyle(.secondary)
                    .onTapGesture { isSet.wrappedValue = true }
                    .accessibilityHidden(true)
            }
        }
    }

    private func save() {
        guard let propertyId = viewModel.propertyId else { return }
        var owners: [PropertyOwner] = []
        for row in rows {
            guard let personId = row.personId else { error = "Choose a person on every row (or remove it)."; return }
            guard let share = Decimal(string: row.shareText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else {
                error = "“\(row.shareText)” isn't a percentage."; return
            }
            let basisPoints = NSDecimalNumber(decimal: share * 100).rounding(accordingToBehavior: nil).intValue
            owners.append(PropertyOwner(propertyId: propertyId, personId: personId, shareBasisPoints: basisPoints, fromDate: row.from, toDate: row.to))
        }
        viewModel.setOwners(owners, gate: gate) { failure in
            if let failure { error = failure } else { dismiss() }
        }
    }
}

/// New person / Edit person: name, short name and tax identifiers (kept on this device).
struct PersonFormSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    let person: Person?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var shortName = ""
    @State private var utr = ""
    @State private var nino = ""
    @State private var nif = ""
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: person == nil ? "New person" : "Edit person", error: error, width: SheetMetrics.compactWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction(person == nil ? "Add person" : "Save", isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                                           action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $name) }
                LabeledContent("Short name") { TextField("Short name", text: $shortName, prompt: Text("Optional, where space is short")) }
                Text("Tax identifiers")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                LabeledContent("UK UTR") { TextField("UK UTR", text: $utr, prompt: Text("Optional, 10 digits")) }
                LabeledContent("UK NI number") { TextField("UK NI number", text: $nino, prompt: Text("Optional, e.g. QQ 12 34 56 C")) }
                LabeledContent("PT NIF") { TextField("PT NIF", text: $nif, prompt: Text("Optional, 9 digits")) }
                SheetFormNote("Tax identifiers stay in this Mac's database.")
            }
        }
        .onAppear {
            guard let person else { return }
            name = person.name; shortName = person.shortName ?? ""; utr = person.ukUtr ?? ""; nino = person.ukNino ?? ""; nif = person.ptNif ?? ""
        }
    }

    private func save() {
        var edited = person ?? Person(name: "")
        edited.name = name; edited.shortName = shortName; edited.ukUtr = utr; edited.ukNino = nino; edited.ptNif = nif
        switch viewModel.savePerson(edited) {
        case .success: dismiss()
        case .failure(let failure): error = PropertyMessages.text(for: failure)
        }
    }
}

// MARK: - Accounts

struct LinkAccountSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: Int64?
    @State private var role = PropertyAccountRole.current
    @State private var error: String?
    /// Saves through the filed-year check; its question shows on this sheet.
    @StateObject private var gate = FiledYearGate()

    var body: some View { form.filedYearGate(gate) }

    @ViewBuilder private var form: some View {
        let linked = Set(viewModel.snapshot.propertyAccounts.map(\.accountId))
        let available = viewModel.snapshot.accounts.filter { !linked.contains($0.id ?? -1) }
        SheetScaffold(title: "Link account", subtitle: viewModel.snapshot.property?.name, error: error, width: SheetMetrics.compactWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction("Link", isEnabled: accountId != nil, action: save)) {
            SheetForm {
                LabeledContent("Account") {
                    Picker("Account", selection: $accountId) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(available) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .fixedSize()
                    .disabled(available.isEmpty)
                    .sheetFieldNote(available.isEmpty ? "Every account is linked already." : nil)
                }
                LabeledContent("Role") {
                    Picker("Role", selection: $role) {
                        ForEach(PropertyAccountRole.allCases, id: \.self) { Text(PropertyFormat.role($0)).tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func save() {
        guard let accountId else { return }
        viewModel.setAccount(accountId, role: role, gate: gate) { failure in
            if let failure { error = failure } else { dismiss() }
        }
    }
}

// MARK: - Tenancy

struct TenancyDraft: Identifiable {
    let id = UUID()
    let existing: Tenancy?
    let propertyId: Int64
    var reference = ""
    var contract = ""
    var tenant = ""
    var email = ""
    var start = PropertyDays.utcToday(AppClock.now)
    var end: Date? = nil
    var advanceMonths = 0
    var depositMonths = 0
    var notes = ""
    var rents: [RentRow] = []

    struct RentRow: Identifiable {
        let id = UUID()
        var from: Date
        var amountText: String
    }

    init(_ tenancy: Tenancy?, rents: [TenancyRent], propertyId: Int64) {
        existing = tenancy
        self.propertyId = propertyId
        guard let tenancy else { return }
        reference = tenancy.referenceLabel
        contract = tenancy.contractNumber ?? ""
        tenant = tenancy.tenantName ?? ""
        email = tenancy.tenantEmail ?? ""
        start = tenancy.startDate
        end = tenancy.endDate
        advanceMonths = tenancy.advanceRentMonths
        depositMonths = tenancy.depositMonths
        notes = tenancy.notes ?? ""
        self.rents = rents.map { RentRow(from: $0.fromDate, amountText: Money.formatInput($0.monthlyAmountMinorUnits)) }
    }
}

struct TenancyFormSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @State var draft: TenancyDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: draft.existing == nil ? "New tenancy" : "Edit tenancy", subtitle: viewModel.snapshot.property?.name, error: error,
                      width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction(draft.existing == nil ? "Add tenancy" : "Save",
                                           isEnabled: !draft.reference.trimmingCharacters(in: .whitespaces).isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Reference") { TextField("Reference", text: $draft.reference, prompt: Text("The portal's Referência")) }
                LabeledContent("Contract no.") { TextField("Contract no.", text: $draft.contract, prompt: Text("Optional")) }
                LabeledContent("Tenant") { TextField("Tenant", text: $draft.tenant, prompt: Text("Optional")) }
                LabeledContent("Email") {
                    TextField("Email", text: $draft.email, prompt: Text("Optional"))
                        .sheetFieldNote("For the monthly utilities statement. Separate several with commas.")
                }
                LabeledContent("Start") {
                    DatePicker("Start", selection: utcDay($draft.start), displayedComponents: .date).labelsHidden().fixedSize()
                }
                LabeledContent("End") {
                    HStack(spacing: 10) {
                        // Named beside the tick: a SheetForm row hides its controls' own labels.
                        NamedCheckbox(title: "Ended", isOn: Binding(get: { draft.end != nil },
                                                                    set: { draft.end = $0 ? PropertyDays.utcToday(AppClock.now) : nil }))
                        if draft.end != nil {
                            DatePicker("End", selection: utcOptionalDay($draft.end, default: draft.start), displayedComponents: .date)
                                .labelsHidden().fixedSize()
                        }
                    }
                }
                LabeledContent("Advance rent") {
                    ValueStepper("Advance rent", value: $draft.advanceMonths, in: 0...24, text: ValueStepper.months)
                }
                LabeledContent("Deposit") {
                    ValueStepper("Deposit", value: $draft.depositMonths, in: 0...24, text: ValueStepper.months)
                }
                LabeledContent("Rent") { rentEditor }
                LabeledContent("Notes") { TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4) }
            }
        }
    }

    /// The rent history as a small table: the day each rent starts, the monthly amount and a
    /// remove icon per row, then Add rent.
    private var rentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.rents.isEmpty {
                Text("No rent yet: add the monthly rent and the day it starts.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("From")
                        Text("Monthly rent").gridColumnAlignment(.trailing)
                        Text(verbatim: "")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    ForEach($draft.rents) { $rent in
                        GridRow {
                            DatePicker("From", selection: utcDay($rent.from), displayedComponents: .date).labelsHidden().fixedSize()
                            MoneyField("Monthly rent", text: $rent.amountText, currency: viewModel.currency, width: 110)
                            Button { draft.rents.removeAll { $0.id == rent.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this rent")
                                .accessibilityLabel("Remove the rent from \(DocumentFormat.day(rent.from))")
                        }
                    }
                }
            }
            Button {
                draft.rents.append(.init(from: draft.rents.last.map { _ in PropertyDays.utcToday(AppClock.now) } ?? draft.start, amountText: ""))
            } label: {
                Label("Add rent", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func save() {
        var rents: [TenancyRent] = []
        for row in draft.rents {
            guard let amount = Money.parseMinorUnits(row.amountText) else { error = MoneyField.invalidAmountMessage(row.amountText); return }
            rents.append(TenancyRent(tenancyId: draft.existing?.id ?? 0, fromDate: row.from, monthlyAmountMinorUnits: amount))
        }
        var tenancy = draft.existing ?? Tenancy(propertyId: draft.propertyId, referenceLabel: "", startDate: draft.start)
        tenancy.referenceLabel = draft.reference
        tenancy.contractNumber = draft.contract
        tenancy.tenantName = draft.tenant
        tenancy.tenantEmail = draft.email
        tenancy.startDate = draft.start
        tenancy.endDate = draft.end
        tenancy.advanceRentMonths = draft.advanceMonths
        tenancy.depositMonths = draft.depositMonths
        tenancy.notes = draft.notes
        if let failure = viewModel.saveTenancy(tenancy, rents: rents) { error = failure } else { dismiss() }
    }
}
