import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Quick sort (step 7b): this pay month's uncategorised transactions, one card at a time. Each category button saves
/// at once and shows an Undo toast for six seconds; Done closes it. The suggestion, when the card has one, comes first.
public struct QuickSortView: View {
    @ObservedObject var model: QuickEditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme

    public init(model: QuickEditModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            QuickSortContent(model: model)
                .mangoNavigationTitle("Sort uncategorised")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .task { await model.load() }
        .onDisappear { model.refusal = nil }
    }
}

/// Quick sort's body (also what the snapshot route renders).
struct QuickSortContent: View {
    @ObservedObject var model: QuickEditModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PadRefusalBanner(message: model.refusal)
                if let card = model.queue.first {
                    Text("\(model.queue.count) left to sort")
                        .mangoFont(.subheadline)
                        .foregroundStyle(.secondary)
                    QuickSortCardView(card: card)
                    QuickSortButtons(card: card, model: model)
                } else {
                    EmptyState(symbol: "checkmark.circle", title: "All sorted", message: "Nothing left to categorise in this pay month.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(theme.background)
        .safeAreaInset(edge: .bottom) {
            if let toast = model.toast {
                UndoToastView(toast: toast) { Task { await model.undo() } }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
    }
}

/// The transaction being sorted: amount, description, account and date.
private struct QuickSortCardView: View {
    let card: PhoneQuickEdits.QuickSortCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let amount = AccountDetailModel.amount(card.amountMinorUnits, category: nil)
        Card {
            MoneyText(minorUnits: amount.minorUnits, currency: card.currency, role: amount.role,
                      fit: .shrink(), font: .largeTitle.weight(.semibold))
            Text(card.description)
                .mangoFont(.title3, weight: .semibold)
                .lineLimit(3)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            // Side by side, or stacked where the name would be cut to nothing.
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text(card.accountName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                DateText(card.date, font: .subheadline)
            }
            .mangoFont(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("quick-sort-card")
    }
}

/// The category buttons: the suggestion and the most-used categories in a grid, then "More…" for the rest.
private struct QuickSortButtons: View {
    let card: PhoneQuickEdits.QuickSortCard
    @ObservedObject var model: QuickEditModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let choices = QuickSortChoices(card: card, lists: model.lists)
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 300 : 150), spacing: 10)], spacing: 10) {
                ForEach(choices.top) { category in
                    let suggested = category.id == card.suggestedCategoryId
                    Button {
                        pick(category)
                    } label: {
                        Label {
                            Text(category.name)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } icon: {
                            if suggested { Image(systemName: "sparkles") }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    // Chips sit on the surface with primary text (well over 4.5:1); the suggestion is tinted with the accent.
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(suggested ? theme.accent.opacity(0.16) : theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(suggested ? theme.accent : Color.primary.opacity(0.15), lineWidth: suggested ? 1.5 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHint(suggested ? "Suggested category" : "Categorises and saves")
                }
            }
            if !choices.more.isEmpty {
                Menu {
                    ForEach(choices.more) { group in
                        Section(group.title ?? "") {
                            ForEach(group.categories) { category in
                                Button(category.name) { pick(category) }
                            }
                        }
                    }
                } label: {
                    Text("More…")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pick(_ category: Category) {
        guard let id = category.id else { return }
        Task { await model.pick(card: card, categoryId: id) }
    }
}

/// Month's "Sort N uncategorised" row: shown only when editing is on and the queue isn't empty.
struct QuickSortEntryRow: View {
    @ObservedObject var model: QuickEditModel

    var body: some View {
        if model.isAvailable, !model.queue.isEmpty {
            Card {
                Button {
                    model.showsQuickSort = true
                } label: {
                    HStack(spacing: 12) {
                        Label("Sort \(model.queue.count) uncategorised", systemImage: "tag")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .mangoFont(.footnote, weight: .semibold)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sort-uncategorised")
            }
        }
    }
}

/// Presents Quick sort from the model's state, where editing is on.
struct QuickSortSheet: ViewModifier {
    let model: QuickEditModel?

    func body(content: Content) -> some View {
        if let model {
            content.modifier(Host(model: model))
        } else {
            content
        }
    }

    private struct Host: ViewModifier {
        @ObservedObject var model: QuickEditModel

        func body(content: Content) -> some View {
            content.sheet(isPresented: $model.showsQuickSort) { QuickSortView(model: model) }
        }
    }
}
