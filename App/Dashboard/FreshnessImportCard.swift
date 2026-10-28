// App/Dashboard/FreshnessImportCard.swift
import SwiftUI
import BudgetCore

struct FreshnessImportCard: View {
    let freshness: DataFreshness
    /// Each account's latest imported transaction date, shown for the picked account.
    let importedThrough: [Int64: Date]
    /// The stored EUR→GBP rate, for a non-GBP account's note (`NonGBPImportCaption`).
    let eurToGbpRate: Double
    /// The window's importer: an import under way is shown here, with a link to the Imports screen.
    @ObservedObject var importCenter: ImportCenterModel
    let accounts: [Account]
    @Binding var selectedAccountId: Int64?
    let navigate: (AppScreen) -> Void

    private var tint: Color {
        switch freshness.status {
        case .behind: return .orange
        case .upToDate: return .green
        case .noData: return .gray
        }
    }

    private var title: String {
        switch freshness.status {
        case .noData: return "Nothing imported yet"
        case .upToDate: return "Up to date"
        case .behind(let months, let days):
            return months >= 1
                ? "Data is \(months) month\(months == 1 ? "" : "s") behind"
                : "Data is \(days) day\(days == 1 ? "" : "s") behind"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let at = freshness.lastImportAt {
            parts.append("Last import \(DashboardFormat.day(at).unbroken)")
        }
        if let through = freshness.dataThrough { parts.append("transactions through \(DashboardFormat.day(through).unbroken)") }
        return parts.joined(separator: " · ")
    }

    private var selectedAccount: Account? { accounts.first { $0.id == selectedAccountId } }

    private var statusIcon: String {
        switch freshness.status {
        case .upToDate: return "checkmark.circle.fill"
        case .noData: return "tray"
        case .behind: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        if accounts.isEmpty {
            card {
                HStack {
                    Text("Add an account to import into").font(.callout).foregroundStyle(.secondary)
                    Button("Accounts ›") { navigate(.accounts) }.buttonStyle(.link).fixedSize()
                }
            }
        } else {
            card { importControls }
        }
    }

    /// Label block and controls on one line when they fit; otherwise the controls sit under
    /// the label so neither is squeezed.
    private func card<Controls: View>(@ViewBuilder _ makeControls: () -> Controls) -> some View {
        let controls = makeControls()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                labelBlock
                Spacer(minLength: 12)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                labelBlock
                controls
            }
        }
        .padding(14)
        // Fill the pane and lead-align in every layout: the stacked variant is only as wide as
        // its content, which would otherwise shrink and centre the tinted card.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: statusIcon)
                .font(.headline)
                .foregroundStyle(tint)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(freshness.lastImportFileName.map { "Last import: \($0)" } ?? "")
            }
        }
    }

    private func accountPicker() -> some View {
        Picker("Import into", selection: $selectedAccountId) {
            ForEach(accounts) { account in
                Text("\(account.displayName) (\(account.currency.rawValue.uppercased()))").tag(account.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    /// Account picker plus the two import buttons: shortcuts into the one importer with the
    /// picked account (the review is on the Imports screen; files picked while a review is open
    /// join it). An import under way shows below, with a link to it.
    private var importControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                accountPicker()
                if let account = selectedAccount, let id = account.id {
                    // Never truncated ("Import CS…"): the layout above gives them room instead.
                    ImportShortcutButton("Import CSV…", shortcut: .statement(accountId: id, format: .csv, from: .dashboard))
                        .fixedSize()
                    ImportShortcutButton("Import PDF…", shortcut: .statement(accountId: id, format: .pdf, from: .dashboard))
                        .fixedSize()
                    // On the controls' line, so it adds no height to the card.
                    Text(importedThrough[id].map { "Imported up to \(DashboardFormat.day($0))" } ?? "Not imported yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .figureText()
                        .layoutPriority(-1)
                }
            }
            importStatus
            // Capped so a long caption wraps instead of widening the controls (which would
            // tip the card into its stacked layout earlier than the buttons need).
            NonGBPImportCaption(account: selectedAccount, eurToGbpRate: eurToGbpRate)
                .frame(maxWidth: 320, alignment: .leading)
        }
    }

    /// The importer's progress (`ImportCenterModel.phase`): reading, or a review waiting.
    @ViewBuilder
    private var importStatus: some View {
        switch importCenter.phase {
        case .reading, .applying:
            HStack {
                ProgressView().controlSize(.small)
                Text("Import in progress…").font(.callout)
                Button("View progress ›") { navigate(.imports) }.buttonStyle(.link).fixedSize()
            }
        case .review:
            HStack {
                // Nothing in a review is saved before Confirm import.
                Text("Import in review, not saved yet").font(.callout)
                Button("Resume review ›") { navigate(.imports) }.buttonStyle(.link).fixedSize()
            }
        case .idle, .finished, .failed:
            EmptyView()
        }
    }
}
