import SwiftUI
import BudgetCore

/// This month on the iPad (step 10, Task 10), the Property group's first screen: "<tenancy> · <Month>" with how far the
/// four steps are, each step a card (state, what it found, its actions), and a side column with what else is on this
/// month (rent receipt, condomínio), the tax year's evidence and the downloads waiting. Every state and figure is
/// `ThisMonthChecklist`'s; the tenancy is named by its label, never the tenant. Beside the cards at 700 pt and more,
/// below them otherwise.
struct PadThisMonthView: View {
    @ObservedObject var model: PadThisMonthModel
    @ObservedObject var property: PadPropertyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Opens another screen of the iPad.
    let go: (PadDestination) -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser
    @State private var checking: TrayItem?

    /// The side column sits beside the steps from this width.
    static let sideBySideWidth: CGFloat = 700

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        content(wide: proxy.size.width >= Self.sideBySideWidth)
                    }
                    .padding(20)
                }
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("This month")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                // The built-in browser and its Downloads tray (hidden with demo data).
                if let browser {
                    ToolbarItem(placement: .primaryAction) {
                        Button { browser.present() } label: {
                            Label("Sites & downloads", systemImage: RowAction.openSite.systemImage)
                        }
                    }
                }
            }
        }
        .sheet(item: $checking) { item in
            if let browser, let source = browser.checkSource {
                CheckAndLinkHost(item: item, tray: browser.tray, source: source) {
                    checking = nil
                    Task {
                        await browser.refreshTray()
                        await model.reload()
                    }
                }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await property.reload()
            await write.refresh()
            await browser?.reload()
            await model.reload()
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        if let snapshot = model.snapshot {
            let checklist = snapshot.checklist
            header(checklist)
            if checklist.isHidden {
                EmptyState(symbol: "lock", title: "Property isn't shared with you", message: "Ask the household's admin for access.")
                    .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                PadWriteNotices(write: write)
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        steps(snapshot).frame(maxWidth: .infinity)
                        side(snapshot).frame(width: 300)
                    }
                } else {
                    steps(snapshot)
                    side(snapshot)
                }
            }
        } else if property.tenancies.isEmpty {
            EmptyState(symbol: "person.2", title: "No tenancy yet", message: "This month's checklist appears once the Mac has shared a tenancy.")
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func header(_ checklist: ThisMonthChecklist) -> some View {
        let done = Self.doneCount(checklist)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(checklist.tenancyName) · \(ThisMonthCopy.month(checklist.month))")
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if model.tenancies.count > 1 {
                    Menu {
                        ForEach(model.tenancies) { tenancy in
                            Button { Task { await model.select(tenancy.id ?? 0) } } label: {
                                if tenancy.id == checklist.tenancyId { Label(tenancy.referenceLabel, systemImage: "checkmark") }
                                else { Text(tenancy.referenceLabel) }
                            }
                        }
                    } label: {
                        Label("Tenancy", systemImage: "chevron.up.chevron.down").labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Choose tenancy")
                }
            }
            if !checklist.isHidden {
                ProgressView(value: Double(done), total: Double(max(checklist.steps.count, 1)))
                    .tint(theme.accent)
                    .accessibilityHidden(true)
                Text(Self.progressText(checklist)).figureText().font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Steps that are done, or have nothing to do this month.
    static func doneCount(_ checklist: ThisMonthChecklist) -> Int {
        checklist.steps.filter { $0.state == .done || $0.state == .notApplicable }.count
    }

    /// "2 of 4 done".
    static func progressText(_ checklist: ThisMonthChecklist) -> String { "\(doneCount(checklist)) of \(checklist.steps.count) done" }

    private func steps(_ snapshot: PadThisMonthModel.Snapshot) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(snapshot.checklist.steps.enumerated()), id: \.element.id) { index, step in
                stepCard(step, number: index + 1, snapshot: snapshot)
            }
        }
    }

    // MARK: Step cards

    private func stepCard(_ step: ThisMonthChecklist.Step, number: Int, snapshot: PadThisMonthModel.Snapshot) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                marker(step.state, number: number)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(step.headline.figuresUnbroken).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        pill(step)
                    }
                    detail(step, snapshot: snapshot)
                    if step.id == .billsIn { providers(step, snapshot: snapshot) }
                    stepActions(step, snapshot: snapshot)
                    if let message = write.message(for: PadThisMonthModel.confirmRow), step.id == .lastRechargePaid {
                        PadRefusalBanner(message: message)
                    }
                }
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
    }

    private func marker(_ state: ThisMonthChecklist.StepState, number: Int) -> some View {
        ZStack {
            Circle().fill(state == .done ? theme.income : Color.clear)
            Circle().strokeBorder(state == .done ? theme.income : (state == .needsYou ? theme.accent : Color.secondary.opacity(0.5)), lineWidth: 2)
            switch state {
            case .done: Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
            case .notApplicable: Image(systemName: "minus").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            default: Text("\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(state == .needsYou ? theme.accent : .secondary)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    static func pillText(_ step: ThisMonthChecklist.Step) -> String {
        switch step.state {
        case .done: "Done"
        case .needsYou: "To do"
        case .waiting: step.isWaitingForMac ? "Waiting for the Mac" : "Waiting"
        case .notApplicable: "Not needed"
        }
    }

    private func pill(_ step: ThisMonthChecklist.Step) -> some View {
        let tint: Color = switch step.state {
        case .done: theme.income
        case .needsYou: theme.accent
        case .waiting: theme.pending
        case .notApplicable: .secondary
        }
        return Text(Self.pillText(step))
            .font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }

    @ViewBuilder
    private func detail(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot) -> some View {
        if step.id == .chargesInGrid, step.state != .notApplicable {
            let text = PadThisMonthModel.chargesText(step, soFarMinorUnits: snapshot.rechargeSoFarMinorUnits, currency: snapshot.currency)
            Text(text.figuresUnbroken)
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("See the grid") { go(.billsAndRecharges) }.buttonStyle(.pad(.textLink, size: .small))
        } else if let text = step.detail {
            Text(text.figuresUnbroken).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 2: providers

    private func providers(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(step.providers) { provider in
                Divider()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(Self.stateText(provider.state)).font(.caption).foregroundStyle(Self.stateTint(provider.state, theme))
                    }
                    Spacer(minLength: 4)
                    if let amount = snapshot.amounts[provider.id], provider.state == .checked {
                        MoneyText(minorUnits: amount, currency: snapshot.currency, role: .neutral, font: .subheadline)
                    }
                    providerButton(provider)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
            }
        }
    }

    static func stateText(_ state: ThisMonthChecklist.ProviderBill.State) -> String {
        switch state {
        case .checked: "Checked"
        case .fetched: "Downloaded, to check"
        case .missing: "To fetch"
        }
    }

    static func stateTint(_ state: ThisMonthChecklist.ProviderBill.State, _ theme: PhoneTheme) -> Color {
        switch state {
        case .checked: theme.income
        case .fetched: theme.accent
        case .missing: theme.pending
        }
    }

    /// Open site for a bill still to fetch, Check for one downloaded.
    @ViewBuilder
    private func providerButton(_ provider: ThisMonthChecklist.ProviderBill) -> some View {
        switch provider.state {
        case .missing:
            if let id = provider.providerId, browser != nil {
                RowIconButton(.openSite, item: provider.name, size: .small) { perform(.openSite(providerId: id)) }
            }
        case .fetched:
            if let item = provider.trayItemIds.first, model.offers(.check(trayItemId: item), checkAllowed: browser?.canCheck ?? true) {
                RowIconButton(.check, item: provider.name, size: .small) { perform(.check(trayItemId: item)) }
            }
        case .checked:
            EmptyView()
        }
    }

    // MARK: Step actions

    @ViewBuilder
    private func stepActions(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot) -> some View {
        switch step.id {
        case .lastRechargePaid:
            ForEach(step.actions, id: \.self) { action in
                switch action {
                case .confirmMatch where model.offers(action):
                    HStack(spacing: 12) {
                        Button("Confirm match") { perform(action) }.buttonStyle(.pad(.primary, size: .small))
                        Text(ThisMonthCopy.notExact).font(.caption).foregroundStyle(.secondary)
                    }
                case .markReceived where model.offers(action):
                    Button("Mark received") { perform(action) }.buttonStyle(.pad(.secondary, size: .small))
                case .fetchStatement(let kind) where browser != nil:
                    HStack(spacing: 4) {
                        RowIconButton(.openSite, item: kind == .bank ? "bank statement" : kind.title, size: .small) { perform(action) }
                        Text("Open the bank's site").font(.caption).foregroundStyle(.secondary)
                    }
                case .prepareEmail where model.offers(action):
                    Button("Prepare statement") { perform(action) }.buttonStyle(.pad(.secondary, size: .small))
                default:
                    EmptyView()
                }
            }
        case .emailTenant:
            if step.state != .done, step.state != .notApplicable {
                let action = step.actions.first { if case .prepareEmail = $0 { true } else { false } }
                Button("Prepare statement") { if let action { perform(action) } }
                    .buttonStyle(.pad(.primary))
                    .disabled(action == nil || !model.offers(action!))
            }
        case .billsIn, .chargesInGrid:
            EmptyView()
        }
    }

    // MARK: Side column

    private func side(_ snapshot: PadThisMonthModel.Snapshot) -> some View {
        let checklist = snapshot.checklist
        return VStack(spacing: 12) {
            if !checklist.side.isEmpty {
                sideCard("Also this month") {
                    ForEach(Array(checklist.side.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        sideRow(item, currency: snapshot.currency)
                    }
                }
            }
            sideCard("Evidence for the tax year") {
                Text(checklist.evidenceCount == 0 ? "Nothing missing" : "\(checklist.evidenceCount) missing")
                    .figureText().font(.subheadline)
                Button("Open Evidence") { go(.evidence) }.buttonStyle(.pad(.textLink, size: .small))
            }
            downloads(checklist)
        }
    }

    private func sideCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sideRow(_ item: ThisMonthChecklist.SideItem, currency: Currency) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.state == .done ? "checkmark.circle.fill" : (item.kind == .rentReceipt ? "doc.text" : "building.2"))
                .foregroundStyle(item.state == .done ? theme.income : theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline.figuresUnbroken).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let amount = item.amountMinorUnits, let currency = item.currency {
                    MoneyText(minorUnits: amount, currency: currency, role: .neutral, font: .caption)
                }
            }
            Spacer(minLength: 4)
            if browser != nil {
                ForEach(item.actions, id: \.self) { action in
                    RowIconButton(.openSite, item: "Portal das Finanças", size: .small) { perform(action) }
                }
            }
        }
    }

    private func downloads(_ checklist: ThisMonthChecklist) -> some View {
        sideCard("Downloads waiting") {
            Text(checklist.downloadsWaiting == 0 ? "Nothing waiting" : "\(checklist.downloadsWaiting) to check")
                .figureText().font(.subheadline)
            if let browser {
                ForEach(browser.downloadedItems) { item in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext").foregroundStyle(theme.accent).accessibilityHidden(true)
                        Text(item.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.offers(.check(trayItemId: item.id), checkAllowed: browser.canCheck) {
                            RowIconButton(.check, item: item.fileName, size: .small) { perform(.check(trayItemId: item.id)) }
                        }
                    }
                }
                Button("Sites & downloads") { browser.present() }.buttonStyle(.pad(.textLink, size: .small))
            }
        }
    }

    // MARK: Routing

    private func perform(_ action: ThisMonthChecklist.ChecklistAction) {
        if case .confirmMatch(let id) = action {
            Task { await model.confirmMatch(transactionId: id) }
            return
        }
        guard let destination = model.destination(for: action) else { return }
        switch destination {
        case .site(let kind, let name):
            guard let browser else { return }
            browser.present(PadThisMonthModel.site(in: browser.sites, kind: kind, name: name))
        case .check(let id):
            guard let browser, let item = browser.downloadedItems.first(where: { $0.id == id }) ?? browser.tray.items().first(where: { $0.id == id })
            else { return }
            if browser.checkSource != nil { checking = item } else { browser.present() }
        case .billsAndRecharges, .recharges, .evidence:
            go(destination)
        }
    }
}
