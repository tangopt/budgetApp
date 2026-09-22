import SwiftUI
import BudgetCore

struct ContentView: View {
    var body: some View {
        Text("Budget — v\(BudgetCore.version) — Import screen wired in Task 14")
            .padding()
        // NOTE: full navigation shell (sidebar linking Import / Review / Budget grid /
        // Forecast / Net worth) is built in Task 24. For now this task's manual
        // verification launches ImportView directly (see Step 6).
    }
}
