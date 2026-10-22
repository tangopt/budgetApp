// App/DesignSystem/ImportShortcutButton.swift
import SwiftUI
import BudgetCore

/// A screen's import shortcut: opens the open panel for the shortcut's file types, then hands
/// the files to the window's one importer with the shortcut's intent and entry point (the
/// Imports screen shows the review; nothing is saved before Confirm import). Every import
/// button in the app is this, so they look and behave the same.
struct ImportShortcutButton: View {
    let title: String
    let systemImage: String?
    let shortcut: ImportShortcut
    let prominent: Bool
    /// The importer handed in by the parent, for content that may not inherit the environment
    /// (a context menu); nil: the environment's.
    let importer: DocumentImportAction?
    /// Called once files were chosen and handed to the importer (not when the panel is cancelled).
    let onStarted: (() -> Void)?
    @Environment(\.documentImport) private var environmentImporter

    init(_ title: String, systemImage: String? = nil, shortcut: ImportShortcut, prominent: Bool = false,
         importer: DocumentImportAction? = nil, onStarted: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.prominent = prominent
        self.importer = importer
        self.onStarted = onStarted
    }

    private var documentImport: DocumentImportAction? { importer ?? environmentImporter }

    /// Said in a sheet after its shortcut handed files over: the window's Imports screen shows
    /// their review, once the sheet is closed.
    static let opensWhenClosed = "Opens in Imports when you close this"

    var body: some View {
        if shortcut.offersLibrary, let counts = documentImport?.libraryCounts {
            // Utility invoices…: a small menu, "Choose files…" and "From library (N)" (hidden at 0).
            LibraryShortcutMenu(title: title, systemImage: systemImage, counts: counts, shortcut: shortcut, choose: choose) {
                if documentImport?.startFromLibrary(shortcut) == true { onStarted?() }
            }
            .disabled(documentImport == nil)
            .modifier(ProminentWhen(prominent: prominent))
        } else if prominent {
            button.buttonStyle(.borderedProminent).prominentTint()
        } else {
            button
        }
    }

    private func choose() {
        if let onStarted {
            if documentImport?.pickShortcutChosen(shortcut) == true { onStarted() }
        } else {
            documentImport?.pickShortcut(shortcut)
        }
    }

    private var button: some View {
        Button {
            choose()
        } label: {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .disabled(documentImport == nil)
    }
}

/// A library shortcut's button as a menu: "Choose files…" (the open panel) and, when the
/// library holds documents for it, "From library (N)". Observes the counts (Observation) so N stays current.
private struct LibraryShortcutMenu: View {
    let title: String
    let systemImage: String?
    let shortcut: ImportShortcut
    let counts: ImportLibraryCounts
    let choose: () -> Void
    let fromLibrary: () -> Void

    init(title: String, systemImage: String?, counts: ImportLibraryCounts, shortcut: ImportShortcut,
         choose: @escaping () -> Void, fromLibrary: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.counts = counts
        self.choose = choose
        self.fromLibrary = fromLibrary
    }

    var body: some View {
        let pending = counts.count(for: shortcut)
        Menu {
            Button("Choose files…", action: choose)
            if pending > 0 {
                Button("From library (\(pending))", action: fromLibrary)
                    .help("Documents already in the library that aren't recorded yet")
            }
        } label: {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
    }
}

/// `.borderedProminent` with the prominent tint when `prominent`.
private struct ProminentWhen: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent).prominentTint() } else { content }
    }
}

/// The accent outline of a targeted drop zone (the window drop's and the Documents screen's).
struct ImportDropOutline: ViewModifier {
    let isTargeted: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.accent, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ImportDropTarget: ViewModifier {
    /// Nil: no drop zone (as `isEnabled` false).
    let shortcut: ImportShortcut?
    let isEnabled: Bool
    let onStarted: (() -> Void)?
    @Environment(\.documentImport) private var documentImport
    @State private var targeted = false

    func body(content: Content) -> some View {
        if isEnabled, let shortcut {
            content
                .modifier(ImportDropOutline(isTargeted: targeted))
                // The innermost drop destination takes the drop, so this wins over the window's.
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty, let documentImport else { return false }
                    documentImport.startShortcut(files, shortcut)
                    onStarted?()
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            // Disabled: no destination here, so a drop falls through to the window's.
            content
        }
    }
}

extension View {
    /// Files dropped here go to the importer with `shortcut`'s intent; the accent outline shows
    /// while a drag is over it. `onStarted`: called after the files are handed over.
    func importDropTarget(_ shortcut: ImportShortcut, isEnabled: Bool = true, onStarted: (() -> Void)? = nil) -> some View {
        modifier(ImportDropTarget(shortcut: shortcut, isEnabled: isEnabled, onStarted: onStarted))
    }

    /// `importDropTarget` for a shortcut that may not exist yet (a record not saved): no drop zone without one.
    func importDropTarget(_ shortcut: ImportShortcut?, onStarted: (() -> Void)? = nil) -> some View {
        modifier(ImportDropTarget(shortcut: shortcut, isEnabled: shortcut != nil, onStarted: onStarted))
    }
}
