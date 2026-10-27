import SwiftUI
import BudgetCore

/// Property ▸ Recharges on the iPad: the selected tenancy's statements, latest first, each with its lines, total and
/// what is still owed. A draft offers "Mark sent"; a sent one "Record payment…"; a refusal shows under its statement.
struct PadRechargesView: View {
    @ObservedObject var model: PadRechargesModel
    @ObservedObject var property: PadPropertyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @State private var request: PadChoiceRequest?
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PadWriteNotices(write: write)
                    if model.statements.isEmpty {
                        EmptyState(symbol: "arrow.left.arrow.right", title: "No statements",
                                   message: "Recharge statements appear here once the Mac has shared a tenancy.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(model.statements) { statement in card(statement) }
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("Recharges")
        }
        .task(id: ReloadKey(trigger: SyncReloadTrigger(syncStatus), tenancy: property.selectedTenancyId)) {
            await write.refresh()
            await model.reload()
        }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
    }

    private struct ReloadKey: Equatable {
        var trigger: SyncReloadTrigger
        var tenancy: Int64?
    }

    private var currency: Currency { property.property?.currency ?? .gbp }

    private static func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month)
    }

    private static func statusTitle(_ status: RechargeStatementStatus) -> String {
        switch status {
        case .draft: "Draft"
        case .sent: "Sent"
        case .paid: "Paid"
        }
    }

    private func card(_ statement: PadRechargesModel.Statement) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.monthTitle(statement.statement.month).figuresUnbroken).font(.headline)
                        Text(Self.statusTitle(statement.statement.status)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    MoneyText(minorUnits: statement.statement.totalMinorUnits, currency: currency, role: .neutral, font: .headline)
                }
                ForEach(statement.lines, id: \.line.id) { detail in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.provider?.name ?? detail.line.lineDescription ?? "Line").font(.subheadline)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: detail.line.amountMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                    }
                }
                if statement.statement.status == .sent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Still owed").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: statement.row.outstandingMinorUnits, currency: currency, role: .neutral, font: .subheadline)
                    }
                }
                if let action = model.action(for: statement) {
                    Button(action.title) { Task { await run(action, statement) } }
                        .buttonStyle(.bordered)
                }
                PadRefusalBanner(message: write.message(for: statement.rowId))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func run(_ action: PadBillAction, _ statement: PadRechargesModel.Statement) async {
        switch action {
        case .markSent:
            await model.markSent(statement)
        case .recordPayment:
            let suggestions = statement.suggestions
            request = PadChoiceRequest(title: "Record payment", button: "Record", empty: "No tenant credit pays this statement yet.",
                                       currency: currency,
                                       choices: suggestions.map { PadChoice(id: $0.transaction.id ?? 0, title: $0.transaction.rawDescription,
                                                                            date: $0.transaction.date, amountMinorUnits: $0.amountMinorUnits) },
                                       choose: { id in
                                           if let suggestion = suggestions.first(where: { $0.transaction.id == id }) {
                                               await model.recordPayment(statement, suggestion)
                                           }
                                       })
        default:
            break
        }
    }
}
