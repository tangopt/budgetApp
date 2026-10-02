// App/Import/NonGBPImportCaption.swift
import SwiftUI
import BudgetCore

/// There is no currency conversion on import: a EUR statement's cents would be stored as GBP
/// pence. Until conversion exists, importing into a non-GBP account only gets this caption
/// (it never blocks). Shown under the import-account picker on the Import screen and on the
/// dashboard's import card.
struct NonGBPImportCaption: View {
    let account: Account?

    var body: some View {
        if let account, account.currency != .gbp {
            Text("Currency conversion isn't supported yet — amounts from this account would be imported as if they were GBP.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
