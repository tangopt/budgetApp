import SwiftUI
import BudgetCore

/// Step 13's snapshot routes: the salary simulator on iPhone (default size, `.xxxLarge`, `.accessibility3`) and on the
/// iPad (inside the sidebar, at the four window sizes). A £52,000 offer against £40,000 with a Plan 2 loan, a 5%
/// pension and a 10% bonus paid in March on the offer, so the strip shows a real difference and the results show their
/// loan, pension and bonus month lines.
public enum SalaryRoutes {
    @MainActor
    static func demoModel(today: Date) -> SalaryComparisonViewModel {
        let current = SalaryInputs.typicalCurrent(today: today)
        var offer = current
        offer.grossAnnual = 5_200_000
        offer.studentLoan = .plan2
        offer.pension = .percentOfGross(basisPoints: 500)
        offer.pensionMethod = .salarySacrifice
        offer.bonusPercentBP = 1_000
        return SalaryComparisonViewModel(current: current, offer: offer)
    }

    static let all: [DemoRoute] = [
        // The strip (3) and one column (3 take-home, tax, NI, loan, pension, allowance, 2 rates): 13 on the offer.
        DemoRoute(name: "salary", minimumFigures: 4) { context in
            AnyView(NavigationStack { SalarySimulatorScreen(viewModel: demoModel(today: context.today), startingOn: .inputs) })
        },
        // Results: the headline, the take-home, the deductions and the flow's differences.
        DemoRoute(name: "salary-results", minimumFigures: 13) { context in
            AnyView(NavigationStack { SalarySimulatorScreen(viewModel: demoModel(today: context.today), startingOn: .results) })
        },
        // Landscape shows inputs and results side by side; in the narrower portrait detail the iPhone's tabs show (6).
        // Accessibility 3 too: rows stack there and no figure is cut off.
        DemoRoute(name: "salary", sizes: DemoRoute.padSizes + [.accessibility3], minimumFigures: 4, pad: true) { context in
            let tabs = PadRoutes.tabs(context)
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .salary,
                                       salary: demoModel(today: context.today), columns: .doubleColumn))
        },
    ]
}
