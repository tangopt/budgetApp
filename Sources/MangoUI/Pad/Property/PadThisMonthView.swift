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
                    VStack(alignment: .leading, spacing: MangoSpacing.section) {
                        content(wide: proxy.size.width >= Self.sideBySideWidth)
                    }
                    .padPageContent()
                }
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("This month", subtitle: model.snapshot.map { ThisMonthCopy.month($0.checklist.month) },
                     contexts: tenancyContext) {
                // The built-in browser and its Downloads tray (hidden with demo data).
                if let browser {
                    RowIconButton(.openSite, item: "sites and downloads") { browser.present() }
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

    /// The tenancy this month is about (the reference label, never the tenant), switchable when there are several.
    private var tenancyContext: [ContextPicker] {
        guard let checklist = model.snapshot?.checklist else { return [] }
        return [ContextPicker("Tenancy", items: model.tenancies, selected: String(checklist.tenancyId), fallback: checklist.tenancyName,
                              id: { String($0.id ?? 0) }, title: { $0.referenceLabel },
                              choose: { tenancy in Task { await model.select(tenancy.id ?? 0) } })]
    }

    private func header(_ checklist: ThisMonthChecklist) -> some View {
        let done = Self.doneCount(checklist)
        return VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            if !checklist.isHidden {
                ProgressView(value: Double(done), total: Double(max(checklist.steps.count, 1)))
                    .tint(theme.accent)
                    .accessibilityHidden(true)
                Text(Self.progressText(checklist)).figureText().mangoFont(.subheadline).foregroundStyle(.secondary)
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
        let current = Self.currentStep(snapshot.checklist)
        return VStack(spacing: MangoSpacing.tile) {
            ForEach(Array(snapshot.checklist.steps.enumerated()), id: \.element.id) { index, step in
                stepCard(step, number: index + 1, isCurrent: step.id == current, snapshot: snapshot)
            }
        }
    }

    /// The step the person is on: the first that needs them, else the first still waiting. Its action is the filled
    /// one; later steps' actions are plain.
    static func currentStep(_ checklist: ThisMonthChecklist) -> ThisMonthChecklist.StepID? {
        (checklist.steps.first { $0.state == .needsYou } ?? checklist.steps.first { $0.state == .waiting })?.id
    }

    // MARK: Step cards

    private func stepCard(_ step: ThisMonthChecklist.Step, number: Int, isCurrent: Bool, snapshot: PadThisMonthModel.Snapshot) -> some View {
        let marker: StepMarkerState = switch step.state {
        case .done: .done
        case .notApplicable: .notApplicable
        case .needsYou, .waiting: isCurrent ? .current : .later
        }
        // A pill when nothing is needed from the person, one button when they must act; never both.
        let accessory = StepCardRule.accessory(needsAction: step.state == .needsYou, action: primaryAction(step, isCurrent: isCurrent),
                                               pillText: Self.pillText(step), status: Self.pillStatus(step))
        return StepCard(number: number, marker: marker, title: step.headline, statusLine: statusLine(step, snapshot: snapshot),
                        accessory: accessory) {
            stepBody(step, snapshot: snapshot, accessory: accessory)
        }
    }

    /// The one line under the title: what the step found.
    private func statusLine(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot) -> String? {
        if step.id == .chargesInGrid, step.state != .notApplicable {
            return PadThisMonthModel.chargesText(step, soFarMinorUnits: snapshot.rechargeSoFarMinorUnits, currency: snapshot.currency)
        }
        return step.detail
    }

    /// The step's one action when the person must act: the first offered of its actions that names a job.
    private func primaryAction(_ step: ThisMonthChecklist.Step, isCurrent: Bool) -> StepAction? {
        for action in step.actions where model.offers(action) {
            switch action {
            case .confirmMatch: return StepAction("Confirm match", isCurrent: isCurrent) { perform(action) }
            case .prepareEmail: return StepAction("Prepare statement", isCurrent: isCurrent) { perform(action) }
            case .markReceived: return StepAction("Mark received", isCurrent: isCurrent) { perform(action) }
            default: continue
            }
        }
        return nil
    }

    @ViewBuilder
    private func stepBody(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot, accessory: StepAccessory) -> some View {
        if step.id == .chargesInGrid, step.state != .notApplicable {
            Button("See the grid") { go(.billsAndRecharges) }.buttonStyle(.pad(.secondary, size: .small))
        }
        if step.id == .billsIn { providers(step, snapshot: snapshot) }
        if step.id == .lastRechargePaid {
            if step.actions.contains(where: { if case .confirmMatch = $0 { true } else { false } }), StepCardRule.showsAction(accessory) {
                Text(ThisMonthCopy.notExact).mangoFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(step.actions, id: \.self) { action in
                if case .fetchStatement(let kind) = action, browser != nil {
                    HStack(spacing: 4) {
                        RowIconButton(.openSite, item: kind == .bank ? "bank statement" : kind.title, size: .small) { perform(action) }
                        Text("Open the bank's site").mangoFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = write.message(for: PadThisMonthModel.confirmRow) {
                PadRefusalBanner(message: message)
            }
        }
    }

    static func pillText(_ step: ThisMonthChecklist.Step) -> String {
        switch step.state {
        case .done: "Done"
        case .needsYou: "To do"
        case .waiting: step.isWaitingForMac ? "Waiting for the Mac" : "Waiting"
        case .notApplicable: "Not needed"
        }
    }

    /// The pill's colours: done, waiting, to do (when the step needs the person but offers no button), not needed.
    static func pillStatus(_ step: ThisMonthChecklist.Step) -> StatusPill.Status {
        switch step.state {
        case .done: .done
        case .needsYou: .todo
        case .waiting: .waiting
        case .notApplicable: .neutral
        }
    }

    // MARK: Step 2: providers

    private func providers(_ step: ThisMonthChecklist.Step, snapshot: PadThisMonthModel.Snapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(step.providers) { provider in
                MangoDivider()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).mangoFont(.subheadline, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                        Text(Self.stateText(provider.state)).mangoFont(.caption).foregroundStyle(Self.stateTint(provider.state, theme))
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

    // MARK: Side column

    private func side(_ snapshot: PadThisMonthModel.Snapshot) -> some View {
        let checklist = snapshot.checklist
        return VStack(spacing: 12) {
            if !checklist.side.isEmpty {
                sideCard("Also this month") {
                    ForEach(Array(checklist.side.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { MangoDivider() }
                        sideRow(item, currency: snapshot.currency)
                    }
                }
            }
            sideCard("Evidence for the tax year") {
                Text(checklist.evidenceCount == 0 ? "Nothing missing" : "\(checklist.evidenceCount) missing")
                    .figureText().mangoFont(.subheadline)
                Button("Open Evidence") { go(.evidence) }.buttonStyle(.pad(.secondary, size: .small))
            }
            downloads(checklist)
        }
    }

    private func sideCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).mangoFont(.headline)
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
                Text(item.headline.figuresUnbroken).mangoFont(.subheadline).fixedSize(horizontal: false, vertical: true)
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
                .figureText().mangoFont(.subheadline)
            if let browser {
                ForEach(browser.downloadedItems) { item in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext").foregroundStyle(theme.accent).accessibilityHidden(true)
                        Text(item.fileName).mangoFont(.caption).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.offers(.check(trayItemId: item.id), checkAllowed: browser.canCheck) {
                            RowIconButton(.check, item: item.fileName, size: .small) { perform(.check(trayItemId: item.id)) }
                        }
                    }
                }
                Button("Sites & downloads") { browser.present() }.buttonStyle(.pad(.secondary, size: .small))
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
            guard let browser else { return }
            Task {
                // The tray read again off the main actor, not from the view.
                if !browser.downloadedItems.contains(where: { $0.id == id }) { await browser.refreshTray() }
                guard let item = browser.downloadedItems.first(where: { $0.id == id }) else { return }
                if browser.checkSource != nil { checking = item } else { browser.present() }
            }
        case .billsAndRecharges, .recharges, .prepareEmail, .evidence:
            go(destination)
        }
    }
}
