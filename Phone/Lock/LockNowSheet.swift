import SwiftUI

/// What Home's avatar opens until Task 12's Settings sheet replaces it: "Lock now" (auth spec §10, on demand) and
/// Done. Presented inside the lock cover.
struct LockNowSheet: View {
    let lock: PhoneLockModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                    lock.lock()
                } label: {
                    Label("Lock now", systemImage: "lock")
                        .frame(minHeight: 44)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
