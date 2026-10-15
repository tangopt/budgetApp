// App/Budget/AccountFilterPanel.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The Budget grid's account filter (spec §7): a slim, collapsible column to the left of the
/// grid — "All accounts" then each account with its transaction count, ticked to show only
/// those accounts' actuals. The selection and the open/closed state live in the view model,
/// so they're kept while the app runs. Accounts are dragged to reorder them (the shared
/// `AccountOrdering`); "All accounts" stays first and isn't draggable — dropping on it moves
/// the account to the top.
struct AccountFilterPanel: View {
    @ObservedObject var viewModel: BudgetGridViewModel
    /// The account row a drag is over; `isDropTargetingAll` for "All accounts".
    @State private var dropTargetId: Int64?
    @State private var isDropTargetingAll = false

    var body: some View {
        if viewModel.isAccountPanelOpen {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("ACCOUNTS")
                        .font(.caption).bold()
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.isAccountPanelOpen = false
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide accounts")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        row("All accounts", count: viewModel.transactions.count, ticked: !viewModel.isAccountFiltered) {
                            viewModel.showAllAccounts()
                        }
                        .overlay { dropIndicator(isDropTargetingAll) }
                        .dropDestination(for: DraggedAccount.self) { items, _ in
                            drop(items, onto: nil)
                        } isTargeted: { isDropTargetingAll = $0 }
                        ForEach(viewModel.accounts) { account in
                            if let id = account.id {
                                row(account.displayName, count: viewModel.transactionCountByAccount[id] ?? 0, ticked: viewModel.accountFilter.contains(id)) {
                                    viewModel.toggleAccountFilter(id)
                                }
                                .draggable(DraggedAccount(id: id)) {
                                    Text(account.displayName).padding(.horizontal, 8).padding(.vertical, 4)
                                }
                                .overlay { dropIndicator(dropTargetId == id) }
                                .dropDestination(for: DraggedAccount.self) { items, _ in
                                    drop(items, onto: id)
                                } isTargeted: { targeted in
                                    if targeted { dropTargetId = id } else if dropTargetId == id { dropTargetId = nil }
                                }
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                forecastRow
            }
            .padding(.vertical, 6)
            .frame(width: 190, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Button {
                    viewModel.isAccountPanelOpen = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Show accounts")
                if viewModel.isAccountFiltered {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("Filtered to some accounts")
                }
                Spacer()
                Button {
                    viewModel.showForecast.toggle()
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(viewModel.showForecast ? Color.pending : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(viewModel.showForecast ? "Hide forecast" : "Show forecast")
                .accessibilityLabel("Show forecast")
                .accessibilityValue(viewModel.showForecast ? "On" : "Off")
            }
            .padding(.vertical, 6)
            .frame(width: 28)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Show forecast (spec 2026-10-15 §1), pinned under the accounts list. Off: actuals
    /// only, and net worth stops at today.
    private var forecastRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(viewModel.showForecast ? Color.pending : Color.secondary)
                .frame(width: 16)
            Text("Show forecast").lineLimit(1)
            Spacer(minLength: 4)
            Toggle("Show forecast", isOn: $viewModel.showForecast)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.showForecast.toggle() }
        .help("Show planned and expected amounts, and the net worth forecast")
    }

    // MARK: Reordering

    /// Dropping on an account puts the dragged one in its place (before it when moving up,
    /// after it when moving down); on "All accounts" (`target` nil), first.
    private func drop(_ items: [DraggedAccount], onto target: Int64?) -> Bool {
        dropTargetId = nil
        isDropTargetingAll = false
        let ids = viewModel.accounts.compactMap(\.id)
        guard let dragged = items.first?.id, let from = ids.firstIndex(of: dragged) else { return false }
        let to: Int
        if let target {
            guard let targetIndex = ids.firstIndex(of: target) else { return false }
            to = targetIndex > from ? targetIndex + 1 : targetIndex
        } else {
            to = 0
        }
        guard to != from, to != from + 1 else { return true }
        viewModel.moveAccounts(fromOffsets: IndexSet(integer: from), toOffset: to)
        return true
    }

    /// Outlines the row a drag is over (the dragged account takes its place).
    @ViewBuilder
    private func dropIndicator(_ visible: Bool) -> some View {
        if visible {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false)
        }
    }

    /// A tickable line: the name, then its transaction count. A plain view with a tap
    /// gesture rather than a `Button` (a button tracks the mouse, so `.draggable` on it may
    /// never start a drag); exposed to accessibility as a button.
    private func row(_ name: String, count: Int, ticked: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ticked ? Color.accentColor : Color.secondary)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(ticked ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(ticked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
        .help(name)
    }
}

/// The Budget panel's drag payload: an app-private type, so dropping an account row into a
/// text field pastes nothing.
struct DraggedAccount: Codable, Transferable {
    let id: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .budgetAccount)
    }
}

extension UTType {
    /// Private to the app (no other app reads it); only used for in-app drags.
    static let budgetAccount = UTType(exportedAs: "com.personal.budget.account-reference")
}
