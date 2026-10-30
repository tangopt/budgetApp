import SwiftUI
import BudgetCore

/// The selected account on the iPad (step 11, Task 2): its balance, the actions (Edit, Update balance, Fetch statement,
/// each only where `PadAccountsModel.actions` offers it), the balance chart, the recent transactions (a row opens the
/// transaction sheet) and the account's details: bank, number masked, currency, kind, how its balance is kept, and its
/// sharing (level and owner). The figures are the iPhone detail's own cards.
struct PadAccountDetailView: View {
    @ObservedObject var model: PadAccountsModel
    @ObservedObject var detail: AccountDetailModel
    /// Edit's form (Task 3): the button shows only with a destination.
    var onEdit: ((Int64) -> Void)?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser
    @Environment(\.quickEdit) private var quickEdit
    @State private var actions: Set<PadAccountAction> = []
    @State private var sharingLine: String?
    /// Off for the other person's account below Everything, and while the viewer isn't named (`showsDetails`).
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            // Not lazy: twenty rows at most, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: 16) {
                if let row = detail.row { BalanceCard(row: row) }
                buttons
                content
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background)
        .task {
            if case .idle = detail.state { await detail.load() }
        }
        .task(id: ActionsKey(accountId: detail.accountId, hasBrowser: browser != nil, version: detail.state)) {
            model.offersBrowser = browser != nil
            actions = await model.actions(for: detail.accountId)
            sharingLine = await model.sharingLine(for: detail.accountId)
            showsDetails = await model.showsDetails(for: detail.accountId)
        }
        .modifier(UpdateBalancePresenter(model: quickEdit, detail: detail))
    }

    private struct ActionsKey: Equatable {
        var accountId: Int64
        var hasBrowser: Bool
        var version: AccountDetailModel.State
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        let shown = buttonList
        if !shown.isEmpty {
            // Icon buttons: a label like "Fetch statement" truncated in the narrow panel (labels live in the tooltip and VoiceOver).
            HStack(spacing: 8) { ForEach(shown, id: \.title) { button($0) } }
        }
    }

    private struct ActionButton {
        var title: String
        var systemImage: String
        var run: () -> Void
    }

    private var buttonList: [ActionButton] {
        var list: [ActionButton] = []
        if actions.contains(.updateBalance), let quickEdit {
            list.append(ActionButton(title: "Update balance", systemImage: "plusminus.circle") { quickEdit.balanceAccountId = detail.accountId })
        }
        if actions.contains(.fetchStatement), browser != nil {
            list.append(ActionButton(title: "Fetch statement", systemImage: "tray.and.arrow.down") { fetchStatement() })
        }
        if actions.contains(.editDetails), let onEdit {
            list.append(ActionButton(title: "Edit", systemImage: "pencil") { onEdit(detail.accountId) })
        }
        return list
    }

    private func button(_ action: ActionButton) -> some View {
        PadIconButton(systemImage: action.systemImage, label: action.title, action: action.run)
    }

    /// The account's bank site when the saved sites have one, else the sites strip. The PDF it downloads goes through the
    /// tray and Check and link, which hands bank statements to the Mac.
    private func fetchStatement() {
        guard let browser else { return }
        guard case .loaded(let loaded) = detail.state else { return browser.present() }
        browser.present(PadAccountsModel.bankSite(in: browser.sites, bankName: loaded.account.bankName))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch detail.state {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "This account couldn't load", message: message)
        case .loaded(let loaded):
            BalanceChartCard(history: loaded.history, currency: loaded.account.currency)
            RecentTransactionsCard(recent: loaded.recent) { row in Task { await model.open(row) } }
            if showsDetails { detailsCard(loaded.account) }
        }
    }

    private func detailsCard(_ account: Account) -> some View {
        var rows: [(String, String)] = []
        if let bank = account.bankName, !bank.isEmpty { rows.append(("Bank", bank)) }
        if let number = (account.accountNumber ?? account.iban), !number.isEmpty { rows.append(("Number", PadAccountsModel.masked(number))) }
        rows.append(("Currency", account.currency.rawValue.uppercased()))
        rows.append(("Kind", Self.kindTitle(account.kind)))
        rows.append(("Balance", account.trackingMode == .manual ? "Updated by hand" : "From statements"))
        if let sharingLine { rows.append(("Sharing", sharingLine)) }
        return Card(title: "Details") {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                PadAccountDetailLine(label: row.0, value: row.1)
            }
        }
    }

    static func kindTitle(_ kind: AccountKind) -> String {
        switch kind {
        case .cash: "Cash"
        case .credit: "Credit"
        case .investment: "Investment"
        }
    }
}

/// A label with its value: the value keeps one line (a long name truncates in the middle), and stacks under the label when
/// it doesn't fit beside it.
struct PadAccountDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                Text(value.figuresUnbroken).lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value.figuresUnbroken).lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
