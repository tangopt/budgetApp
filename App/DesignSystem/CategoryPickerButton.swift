// App/DesignSystem/CategoryPickerButton.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// A button showing the chosen category that opens a searchable, keyboard-driven popover
/// (spec §3): Suggested, Recent, then every assignable category under its group, filtered
/// by the transaction's sign until "Show all categories" is picked.
struct CategoryPickerButton: View {
    @Binding var selection: Int64?
    let categories: [Category]
    let groups: [CategoryGroup]
    let suggestedId: Int64?
    let recentIds: [Int64]
    /// Sign drives the type filter (out → expense/transfer, in → income/transfer); `nil`
    /// or zero shows every category.
    let amountMinorUnits: Int?
    /// Shown when nothing is selected — "Mixed" for a group whose rows differ.
    var placeholder: String = "Choose category"

    @State private var isPresented = false

    private var selectedName: String? {
        guard let selection else { return nil }
        return categories.first(where: { $0.id == selection })?.name
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selectedName ?? placeholder)
                    .foregroundStyle(selectedName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CategoryPickerPopover(
                selection: selection,
                categories: categories,
                groups: groups,
                suggestedId: suggestedId,
                recentIds: recentIds,
                amountMinorUnits: amountMinorUnits,
                onPick: { picked in
                    selection = picked
                    isPresented = false
                },
                onCancel: { isPresented = false }
            )
        }
    }
}

/// The picker's popover content, also used directly by bulk "Set category…" buttons,
/// which add the "Remember for <key>" toggle below the list.
struct CategoryPickerPopover: View {
    let selection: Int64?
    let categories: [Category]
    let groups: [CategoryGroup]
    let suggestedId: Int64?
    let recentIds: [Int64]
    let amountMinorUnits: Int?
    var remember: Binding<Bool>? = nil
    var rememberLabel: String = ""
    let onPick: (Int64?) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var showAll = false
    @State private var highlighted: Int = 0
    /// Set by the arrow keys (and on open) so rows scrolling under a still pointer don't
    /// steal the highlight; cleared only by real pointer movement over the list.
    @State private var isKeyboardNavigating = true
    @State private var lastPointer: CGPoint?
    @FocusState private var searchFocused: Bool

    private var sections: [CategoryPickerSection] {
        CategoryPickerSections.build(categories: categories, groups: groups, suggestedId: suggestedId, recentIds: recentIds,
                                     amountMinorUnits: amountMinorUnits, query: query, showAll: showAll)
    }

    private func resetHighlight() {
        highlighted = CategoryPickerSections.initialHighlight(entries: sections.flatMap(\.entries), selection: selection, query: query)
    }

    var body: some View {
        let sections = sections
        let entries = sections.flatMap(\.entries)
        let indexById = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        VStack(spacing: 0) {
            TextField("Search categories", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onKeyPress(.downArrow) {
                    isKeyboardNavigating = true
                    if !entries.isEmpty { highlighted = min(highlighted + 1, entries.count - 1) }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    isKeyboardNavigating = true
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                // Return may reach either handler depending on the field editor; both pick
                // the same highlighted entry, so a double delivery is harmless.
                .onKeyPress(.return) {
                    activateHighlighted(in: entries)
                    return .handled
                }
                .onSubmit { activateHighlighted(in: entries) }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .onExitCommand { onCancel() }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text("No matching categories")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            } else if section.id == "show-all" {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(section.entries) { entry in
                                row(entry, index: indexById[entry.id] ?? 0)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                // The scroll view itself doesn't move when its content scrolls, so a change
                // of pointer location here is genuine mouse movement.
                .onContinuousHover { phase in
                    guard case .active(let location) = phase else { return }
                    if let lastPointer, lastPointer != location { isKeyboardNavigating = false }
                    lastPointer = location
                }
                .onChange(of: highlighted) { _, newValue in
                    guard isKeyboardNavigating, entries.indices.contains(newValue) else { return }
                    proxy.scrollTo(entries[newValue].id)
                }
            }
            if let remember {
                Divider()
                Toggle(rememberLabel, isOn: remember)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(width: 280, height: remember == nil ? 360 : 392)
        .onAppear {
            resetHighlight()
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            isKeyboardNavigating = true
            resetHighlight()
        }
        .onChange(of: showAll) { _, _ in
            isKeyboardNavigating = true
            resetHighlight()
        }
    }

    private func activateHighlighted(in entries: [CategoryPickerEntry]) {
        guard entries.indices.contains(highlighted) else { return }
        activate(entries[highlighted])
    }

    private func activate(_ entry: CategoryPickerEntry) {
        switch entry.action {
        case .pick(let id): onPick(id)
        case .showAll: showAll = true
        }
    }

    private func row(_ entry: CategoryPickerEntry, index: Int) -> some View {
        let isHighlighted = index == highlighted
        let isSelected = entry.action == .pick(selection)
        let isShowAll = entry.action == .showAll
        return Button {
            activate(entry)
        } label: {
            HStack {
                Text(entry.title)
                    .foregroundStyle(isHighlighted ? Color.white : (isShowAll ? Color.accentColor : Color.primary))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering in
            if hovering && !isKeyboardNavigating { highlighted = index }
        }
    }
}
