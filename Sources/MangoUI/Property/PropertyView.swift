import SwiftUI
import BudgetCore

/// Property (iPhone spec §3.7). With one property it shows that property directly: its name, "Let since <date> ·
/// contract to <date>", this month, the mortgage and what's coming up. With several it's a list, each row pushing its
/// property. Every figure is `PropertyGlance`'s. Read-only: "Split it" comes in step 6. Pull to refresh asks for
/// changes (`onRefresh`) and reads again; a new sync (`syncStatus`'s last-sync time) reads again too.
///
/// `model` belongs to whoever shows Property, above the lock cover, so a relock keeps the pushed property
/// (`model.path`).
public struct PropertyView: View {
    @ObservedObject var model: PropertyViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme

    public init(model: PropertyViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void = {}) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(theme.background)
            .refreshable {
                await onRefresh()
                await model.load()
            }
            .offlineBannerSlot()
            .navigationTitle(model.state.page?.single?.property.name ?? "Property")
            .navigationDestination(for: PropertyDestination.self) { destination in
                PropertyDetailScreen(model: model, destination: destination, onRefresh: onRefresh)
                    .demoBannerSlot()
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: PropertyViewModel.reloadKey(syncStatus))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .empty:
            EmptyState(symbol: "house", title: PropertyCopy.emptyTitle, message: PropertyCopy.emptyMessage)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Property couldn't load", message: message)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .loaded(let page):
            if let error = model.errorMessage {
                InlineBanner(tone: .amber, text: error)
            }
            if let glance = page.single {
                PropertyDetailContent(glance: glance)
            } else {
                list(page)
            }
        }
    }

    /// Several properties: each its name over its tenancy line, pushing the property.
    private func list(_ page: PropertyPage) -> some View {
        Card {
            ForEach(Array(page.glances.enumerated()), id: \.element.property.id) { index, glance in
                if index > 0 { Divider() }
                if let id = glance.property.id {
                    NavigationLink(value: PropertyDestination(propertyId: id)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(glance.property.name)
                                Text(PropertyCopy.tenancyLine(glance).figuresUnbroken)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(glance.property.name)
                        .accessibilityValue(PropertyCopy.tenancyLine(glance))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows this month, the mortgage and what's coming up")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One property's cards: the tenancy line, this month, the mortgage (when there is one) and coming up.
struct PropertyDetailContent: View {
    let glance: PropertyGlance

    var body: some View {
        Text(PropertyCopy.tenancyLine(glance).figuresUnbroken)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ThisMonthCard(glance: glance)
        if let mortgage = glance.mortgage {
            MortgageCard(mortgage: mortgage, currency: glance.property.currency)
        }
        ComingUpList(obligations: glance.comingUp, currency: glance.property.currency)
    }
}

/// A property pushed from the list: its glance as the page holds it, so a sync refreshes it in place.
struct PropertyDetailScreen: View {
    @ObservedObject var model: PropertyViewModel
    let destination: PropertyDestination
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let glance = model.glance(for: destination)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let glance {
                    PropertyDetailContent(glance: glance)
                } else {
                    EmptyState(symbol: "house", title: "Property not found",
                               message: "This property is no longer on the Mac.")
                        .padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(theme.background)
        .refreshable {
            await onRefresh()
            await model.load()
        }
        .navigationTitle(glance?.property.name ?? "Property")
    }
}
