import SwiftUI
import BudgetCore

/// The browser's top strip (step 10, Task 5): the saved sites as chips, the open one highlighted, and "Add site" at
/// the end. The chips scroll sideways when there are more than fit; names truncate in the middle. Without Edit on the
/// sites (`canEdit`), "Add site" and "Remove site" are hidden.
struct SavedSitesStrip: View {
    let sites: [SavedSite]
    let currentId: UUID?
    var canEdit = true
    let onOpen: (SavedSite) -> Void
    let onRemove: (SavedSite) -> Void
    let onAdd: () -> Void
    @Environment(\.phoneTheme) private var theme

    static func symbol(_ kind: SavedSiteKind) -> String {
        switch kind {
        case .bank: "building.columns"
        case .utility: "bolt"
        case .tax: "building.2"
        case .condominium: "house"
        case .other: "globe"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sites) { site in
                        chip(site)
                    }
                }
                .padding(.leading, 16).padding(.vertical, 8)
            }
            // Always in reach, however many sites there are.
            if canEdit {
                Button(action: onAdd) {
                    Label("Add site", systemImage: "plus")
                }
                .buttonStyle(.pad(.secondary, size: .small))
                .padding(.trailing, 16)
            }
        }
    }

    private func chip(_ site: SavedSite) -> some View {
        let selected = site.id == currentId
        return Button { onOpen(site) } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(site.kind)).accessibilityHidden(true)
                Text(site.name).lineLimit(1).truncationMode(.middle)
            }
            .mangoFont(.subheadline, weight: .semibold)
            .padding(.horizontal, 12)
            .frame(minHeight: PadButtonSize.small.minimumTapTarget)
            .frame(maxWidth: 220)
            .foregroundStyle(selected ? Color.white : theme.accent)
            .background(selected ? theme.accent : Color.secondary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(RowAction.openSite.accessibilityLabel), \(site.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if canEdit {
                Button("Remove site", systemImage: "trash", role: .destructive) { onRemove(site) }
            }
        }
    }
}

/// "Add site": a name, the address (https only, checked on Save) and what it is for. Saves only on Save.
struct AddSiteSheet: View {
    let onSave: (String, String, SavedSiteKind) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var kind: SavedSiteKind = .utility
    @State private var error: String?
    @State private var saving = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Address", text: $address, prompt: Text("example.com"))
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Picker("Kind", selection: $kind) {
                        ForEach(SavedSiteKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Secure (https) addresses only. Mango keeps the address, never your password: sign in on the site itself.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(theme.expense) }
                }
            }
            .navigationTitle("Add site")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await onSave(name, address, kind)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "The site couldn't be saved."
            }
            saving = false
        }
    }
}
