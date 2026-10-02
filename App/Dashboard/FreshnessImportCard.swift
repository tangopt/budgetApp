// App/Dashboard/FreshnessImportCard.swift
import SwiftUI
import BudgetCore

struct FreshnessImportCard: View {
    let freshness: DataFreshness
    @ObservedObject var importViewModel: ImportViewModel
    let accounts: [Account]
    @Binding var selectedAccountId: Int64?
    let profileStore: ImportProfileStore
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
            let file = freshness.lastImportFileName.map { " (\($0))" } ?? ""
            parts.append("Last import \(DashboardFormat.day(at))\(file)")
        }
        if let through = freshness.dataThrough { parts.append("transactions through \(DashboardFormat.day(through))") }
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

    /// The idle import controls only exist for a saved account while nothing is staging or
    /// under review.
    private var idleImportAccount: Account? {
        guard !importViewModel.isStaging, !importViewModel.isReviewing, !accounts.isEmpty else { return nil }
        return selectedAccount
    }

    var body: some View {
        // The import host (file pickers and wizard sheets, with their @State) wraps the whole
        // card, outside the width-aware layout below: switching between the one-line and the
        // stacked layout on a window resize must not tear down an open picker or wizard.
        if let account = idleImportAccount {
            ImportFlowHost(viewModel: importViewModel, account: account, profileStore: profileStore, onStarted: { navigate(.importReview) }) { actions in
                card { idleControls(actions: actions) }
            }
        } else {
            card { otherControls }
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
            }
        }
    }

    private func accountPicker() -> some View {
        Picker("Import into", selection: $selectedAccountId) {
            ForEach(accounts) { account in
                Text(account.name).tag(account.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    /// Account picker plus the two import buttons. `actions` is nil when the selected id
    /// doesn't match a saved account (the picker alone is shown to correct it).
    private func idleControls(actions: ImportFlowActions?) -> some View {
        HStack {
            accountPicker()
            if let actions {
                // Never truncated ("Import CS…"): the layout above gives them room instead.
                Button("Import CSV…") { actions.startCSV() }.fixedSize()
                Button("Import PDF…") { actions.startPDF() }.fixedSize()
            }
        }
    }

    @ViewBuilder
    private var otherControls: some View {
        if importViewModel.isStaging {
            HStack {
                ProgressView().controlSize(.small)
                Text("Import in progress…").font(.callout)
                Button("View progress ›") { navigate(.importReview) }.buttonStyle(.link).fixedSize()
            }
        } else if importViewModel.isReviewing {
            HStack {
                Text("Import ready to review").font(.callout)
                Button("Resume review ›") { navigate(.importReview) }.buttonStyle(.link).fixedSize()
            }
        } else if accounts.isEmpty {
            HStack {
                Text("Add an account to import into").font(.callout).foregroundStyle(.secondary)
                Button("Accounts ›") { navigate(.accounts) }.buttonStyle(.link).fixedSize()
            }
        } else {
            idleControls(actions: nil)
        }
    }
}
