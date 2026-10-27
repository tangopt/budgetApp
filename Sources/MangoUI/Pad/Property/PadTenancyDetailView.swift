import SwiftUI
import BudgetCore

/// The selected tenancy's details on the iPad (step 10, Task 13), as the agreed mockup has them: the reference and contract with
/// Edit and a menu, four tiles (Tenant, Rent, Deposit, Dates), then its rent history and contract side by side (stacked when
/// narrow). This is the one screen, besides the recharge email, where the tenant's own name is shown; everywhere else the
/// tenancy goes by its reference.
struct PadTenancyDetailView: View {
    @ObservedObject var model: PadTenanciesModel
    @ObservedObject var write: PadWriteModel
    let tenancy: Tenancy
    let run: (PadTenanciesAction) -> Void
    @Environment(\.phoneTheme) private var theme

    private var currency: Currency { model.currency }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PadRefusalBanner(message: write.message(for: PadTenanciesModel.tenancyRow(tenancy.id)))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], spacing: 12) {
                tenantTile
                rentTile
                depositTile
                datesTile
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    rentHistory
                    contract
                }
                VStack(alignment: .leading, spacing: 12) {
                    rentHistory
                    contract
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tenancy.referenceLabel).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if let number = tenancy.contractNumber, !number.isEmpty {
                    Text("Contract \(number)".figuresUnbroken).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            let actions = model.tenancyActions()
            if actions.contains(.editTenancy) {
                Button { run(.editTenancy) } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Edit \(tenancy.referenceLabel)")
            }
            if !actions.filter({ $0 != .editTenancy }).isEmpty {
                Menu {
                    ForEach(actions.filter { $0 != .editTenancy && $0 != .deleteTenancy }, id: \.self) { action in
                        Button(action.title + (action == .contractDocuments || action == .addContract ? "…" : "")) { run(action) }
                    }
                    if actions.contains(.deleteTenancy) {
                        Divider()
                        Button("Delete tenancy…", role: .destructive) { run(.deleteTenancy) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(tenancy.referenceLabel)")
            }
        }
    }

    // MARK: Tiles

    private var tenantTile: some View {
        tile("Tenant") {
            Text(tenancy.tenantName.flatMap { $0.isEmpty ? nil : $0 } ?? "—").font(.title3.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
        } caption: {
            if let email = tenancy.tenantEmail, !email.isEmpty { Text(email).lineLimit(1).truncationMode(.middle) }
        }
    }

    private var rentTile: some View {
        tile("Rent") {
            if let rent = model.rentInForce {
                MoneyText(minorUnits: rent.monthlyAmountMinorUnits, currency: currency, role: .neutral, fit: .shrink(), font: .title3.weight(.semibold))
            } else {
                Text("—").font(.title3.weight(.semibold))
            }
        } caption: {
            if let rent = model.rentInForce {
                Text("A month, since \(PhoneDateFormat.day(rent.fromDate))".figuresUnbroken)
            } else {
                Text("No rent history")
            }
        }
    }

    private var depositTile: some View {
        tile("Deposit") {
            Text(Self.months(tenancy.depositMonths)).font(.title3.weight(.semibold)).lineLimit(1)
        } caption: {
            Text("+ \(Self.months(tenancy.advanceRentMonths)) advance rent")
        }
    }

    private var datesTile: some View {
        tile("From") {
            Text(PhoneDateFormat.day(tenancy.startDate).unbroken).font(.title3.weight(.semibold)).lineLimit(1)
        } caption: {
            if let end = tenancy.endDate { Text("Until \(PhoneDateFormat.day(end))".figuresUnbroken) } else { Text("Ongoing") }
        }
    }

    private func tile<Value: View, Caption: View>(_ title: String, @ViewBuilder value: () -> Value, @ViewBuilder caption: () -> Caption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            value()
            caption().font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .accessibilityElement(children: .combine)
    }

    static func months(_ count: Int) -> String { "\(count) month\(count == 1 ? "" : "s")" }

    // MARK: Rent history and contract

    private var rentHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rent history").font(.subheadline.weight(.semibold))
            if model.detail.rents.isEmpty {
                Text("No rent history yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.detail.rents.reversed()) { rent in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(PhoneDateFormat.day(rent.fromDate).unbroken).font(.subheadline).lineLimit(1)
                        if rent.id == model.rentInForce?.id { PadStatusPill(text: "In force", tone: .accent) }
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: rent.monthlyAmountMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
    }

    private var contract: some View {
        let count = model.detail.contractDocumentIds.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Contract").font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Number").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(tenancy.contractNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "—").lineLimit(1).truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Number").foregroundStyle(.secondary)
                    Text(tenancy.contractNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                }
            }
            .font(.subheadline)
            HStack(alignment: .center, spacing: 8) {
                if count == 0 {
                    PadStatusPill(text: "None yet", tone: .warning)
                    Spacer(minLength: 4)
                    if write.canEdit { RowIconButton(.linkDocument, item: "contract of \(tenancy.referenceLabel)", size: .small) { run(.addContract) } }
                } else {
                    Button { run(.contractDocuments) } label: {
                        Label(count == 1 ? "1 document" : "\(count) documents", systemImage: "paperclip")
                    }
                    .buttonStyle(.pad(.textLink, size: .small))
                    Spacer(minLength: 0)
                }
            }
            if let notes = tenancy.notes, !notes.isEmpty {
                Text(notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
    }
}
