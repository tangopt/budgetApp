// App/Dashboard/DashboardWidgetsMenu.swift
import SwiftUI
import BudgetCore

/// The toolbar's flat "Widgets" button: a popover listing every Dashboard widget by section with an on/off switch, and
/// "Reset layout" at the bottom (arrangement and hidden widgets back to the default).
struct DashboardWidgetsButton: View {
    /// The widgets that have something to show now (the others are listed, dimmed and disabled).
    let available: Set<DashboardCardVisibility.Card>
    @Binding var hiddenCards: String
    @Binding var storedLayout: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                Text("Widgets")
            }
        }
        .buttonStyle(.borderless)
        .help("Choose which widgets the Dashboard shows")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            DashboardWidgetsList(available: available, hiddenCards: $hiddenCards, storedLayout: $storedLayout)
        }
    }
}

/// The popover's content: every widget by section with its switch, then "Reset layout".
struct DashboardWidgetsList: View {
    let available: Set<DashboardCardVisibility.Card>
    @Binding var hiddenCards: String
    @Binding var storedLayout: String

    private func isOn(_ card: DashboardCardVisibility.Card) -> Binding<Bool> {
        Binding(
            get: { DashboardCardVisibility(storedString: hiddenCards).shows(card) },
            set: { on in
                var visibility = DashboardCardVisibility(storedString: hiddenCards)
                if on { visibility.hidden.remove(card) } else { visibility.hidden.insert(card) }
                hiddenCards = visibility.storedString
            })
    }

    private var isDefault: Bool { hiddenCards.isEmpty && DashboardLayout(storedString: storedLayout).isDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(DashboardLayout.Section.allCases, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(DashboardCardVisibility.Card.cards(in: section), id: \.self) { card in
                            let has = available.contains(card)
                            HStack(spacing: 8) {
                                Text(card.title).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(has ? Color.primary : Color.secondary)
                                Spacer(minLength: 8)
                                Toggle(card.title, isOn: isOn(card))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            .help(has ? "Show or hide \(card.title)" : "\(card.title) has nothing to show yet; you can still show or hide it")
                        }
                    }
                }
            }
            .padding(14)
            Divider()
            Button("Reset layout") {
                storedLayout = ""
                hiddenCards = ""
            }
            .buttonStyle(.borderless)
            .disabled(isDefault)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .help("Put every widget back where it was and show them all")
        }
        .frame(width: 280)
    }
}
