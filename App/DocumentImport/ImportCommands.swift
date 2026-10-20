// App/DocumentImport/ImportCommands.swift
import SwiftUI
import AppKit
import BudgetCore

/// Hands files to the window's document importer (`ImportCenterModel`): `start` reads them
/// straight away, `pickFiles` asks for them first (files and folders, any type). Published
/// per window by ContentView, as a focused value (File ▸ Import…) and in the environment
/// (screens' own import shortcuts).
struct DocumentImportAction {
    let start: (_ urls: [URL], _ intent: ImportIntent, _ entryPoint: String) -> Void
    let pickFiles: (_ intent: ImportIntent, _ entryPoint: String) -> Void

    /// The action for `center`: picking opens a multi-select open panel.
    @MainActor
    static func forCenter(_ center: ImportCenterModel) -> DocumentImportAction {
        DocumentImportAction(
            start: { urls, intent, entryPoint in center.start(urls, intent: intent, entryPoint: entryPoint) },
            pickFiles: { intent, entryPoint in
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Import"
                panel.message = "Choose the documents or folders to import. Nothing is saved until you confirm the import."
                guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
                center.start(panel.urls, intent: intent, entryPoint: entryPoint)
            })
    }
}

extension FocusedValues {
    /// The focused window's importer (`focusedSceneValue`, ContentView).
    @Entry var documentImport: DocumentImportAction?
}

extension EnvironmentValues {
    /// The window's importer, for a screen's own import shortcut.
    @Entry var documentImport: DocumentImportAction?
}

/// File ▸ Import… (⇧⌘I): picks files and folders for the focused window's importer. Off while
/// that window shows a sheet or alert.
struct ImportCommands: Commands {
    @FocusedValue(\.documentImport) private var documentImport
    @ObservedObject private var keyWindow = KeyWindowSheetState.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") { documentImport?.pickFiles(.none, "Menu") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(documentImport == nil || keyWindow.isSheetKey)
        }
    }
}
