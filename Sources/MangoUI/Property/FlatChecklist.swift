import SwiftUI
import BudgetCore

/// The Flat tab's view of This month's checklist (design review §4, §3.4): how far along it is and each step's state in
/// words, read-only (the iPad does the work). A step shows a status pill, never an action button, so the step-card rule
/// holds trivially here.
struct FlatChecklistPresentation: Equatable {
    struct Step: Equatable, Identifiable {
        let id: ThisMonthChecklist.StepID
        let number: Int
        let marker: StepMarkerState
        let title: String
        let statusLine: String?
        let pillText: String
        let pillStatus: StatusPill.Status
    }

    let done: Int
    let total: Int
    let steps: [Step]
    /// "2 of 4 done".
    var progressText: String { "\(done) of \(total) done" }
    /// What VoiceOver reads for the bar.
    var spokenProgress: String { "\(done) of \(total) steps done" }

    init(_ checklist: ThisMonthChecklist) {
        done = PadThisMonthView.doneCount(checklist)
        total = checklist.steps.count
        let current = PadThisMonthView.currentStep(checklist)
        steps = checklist.steps.enumerated().map { index, step in
            let marker: StepMarkerState = switch step.state {
            case .done: .done
            case .notApplicable: .notApplicable
            case .needsYou, .waiting: step.id == current ? .current : .later
            }
            return Step(id: step.id, number: index + 1, marker: marker, title: step.headline,
                        statusLine: step.id == current ? step.detail : nil,
                        pillText: PadThisMonthView.pillText(step), pillStatus: PadThisMonthView.pillStatus(step))
        }
    }

    /// Segment `index` of the progress bar is filled (steps done count from the left).
    func isFilled(_ index: Int) -> Bool { index < done }
}

/// This month on the Flat tab: the count and a segment per step, then the steps (the current one with its detail).
struct FlatChecklistCard: View {
    let checklist: ThisMonthChecklist
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let shown = FlatChecklistPresentation(checklist)
        VStack(alignment: .leading, spacing: MangoSpacing.tile) {
            VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This month").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: MangoSpacing.xs)
                    Text(shown.progressText).figureText().mangoFont(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(0..<shown.total, id: \.self) { index in
                        Capsule().fill(shown.isFilled(index) ? theme.income : theme.surface2).frame(height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Progress")
                .accessibilityValue(shown.spokenProgress)
            }
            ForEach(shown.steps) { step in
                StepCard(number: step.number, marker: step.marker, title: step.title, statusLine: step.statusLine,
                         accessory: .status(text: step.pillText, step.pillStatus))
            }
        }
    }
}
