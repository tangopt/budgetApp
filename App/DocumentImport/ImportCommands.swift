// App/DocumentImport/ImportCommands.swift
import SwiftUI
import AppKit
import BudgetCore
import GRDB

/// Hands files to the window's document importer (`ImportCenterModel`): `start` reads them
/// straight away, `pickFiles` asks for them first (files and folders, any type). Published
/// per window by ContentView, as a focused value (File ▸ Import…) and in the environment
/// (screens' own import shortcuts).
struct DocumentImportAction {
    let start: (_ urls: [URL], _ intent: ImportIntent, _ entryPoint: String) -> Void
    let pickFiles: (_ intent: ImportIntent, _ entryPoint: String) -> Void
    /// A screen's import shortcut: picks with the shortcut's open panel / reads dropped files.
    let pickShortcut: (_ shortcut: ImportShortcut) -> Void
    let startShortcut: (_ urls: [URL], _ shortcut: ImportShortcut) -> Void
    /// `pickShortcut` saying whether files were chosen (false: the panel was cancelled).
    var pickShortcutChosen: (_ shortcut: ImportShortcut) -> Bool = { _ in false }
    /// A source folder's scanned new and changed files (`ImportCenterModel.start(folder:inputs:)`).
    var startFolder: (_ folder: SourceFolder, _ inputs: [SourceFolderImport.Input]) -> Void = { _, _ in }
    /// A library shortcut's "From library" (`ImportCenterModel.startFromLibrary`): false when there was nothing.
    var startFromLibrary: (_ shortcut: ImportShortcut) -> Bool = { _ in false }
    /// Shows the Imports screen (the history and its Undo when nothing is being imported).
    var showHistory: () -> Void = {}
    /// The counts its "From library (N)" shows (nil: no importer behind it, e.g. the gallery).
    var libraryCounts: ImportLibraryCounts?

    /// The action for `center`: picking opens a multi-select open panel.
    @MainActor
    static func forCenter(_ center: ImportCenterModel) -> DocumentImportAction {
        DocumentImportAction(
            start: { urls, intent, entryPoint in center.start(urls, intent: intent, entryPoint: entryPoint) },
            pickFiles: { intent, entryPoint in
                guard let urls = ImportCenterModel.chooseURLs(
                    multiple: true, folders: true,
                    message: "Choose the documents or folders to import. Nothing is saved until you confirm the import.") else { return }
                center.start(urls, intent: intent, entryPoint: entryPoint)
            },
            pickShortcut: { center.pickFiles(for: $0) },
            startShortcut: { urls, shortcut in center.start(urls, shortcut: shortcut) },
            pickShortcutChosen: { center.pickFiles(for: $0) },
            startFolder: { folder, inputs in center.start(folder: folder, inputs: inputs) },
            startFromLibrary: { center.startFromLibrary($0) },
            showHistory: { center.onShow?() },
            libraryCounts: center.libraryCounts)
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

/// File ▸ Import… (⇧⌘I): picks files and folders for the focused window's importer; File ▸
/// Import History… shows the Imports screen (its row is in the sidebar only during an import). Off while
/// that window shows a sheet or alert.
struct ImportCommands: Commands {
    @FocusedValue(\.documentImport) private var documentImport
    @ObservedObject private var keyWindow = KeyWindowSheetState.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") { documentImport?.pickFiles(.none, "Menu") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(documentImport == nil || keyWindow.isSheetKey)
            Button("Import History…") { documentImport?.showHistory() }
                .disabled(documentImport == nil || keyWindow.isSheetKey)
        }
    }
}
