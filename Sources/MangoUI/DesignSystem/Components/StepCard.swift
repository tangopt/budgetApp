import SwiftUI

/// The one thing a step card shows beside its title (design review §3.4, "pill or action, never both"): a status pill
/// when nothing is needed from the user (Done, Waiting for tenant, Not due yet), or a single button naming what to do
/// ("Check & link", "Prepare statement"). The two are cases of one enum, so a card cannot be given both.
enum StepAccessory {
    case status(text: String, StatusPill.Status)
    case action(StepAction)
}

/// The step's button. Only the current step's is the filled, prominent one; later steps use the plain secondary style.
struct StepAction {
    let title: String
    let systemImage: String?
    let isCurrent: Bool
    let isEnabled: Bool
    let perform: () -> Void

    init(_ title: String, systemImage: String? = nil, isCurrent: Bool, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isCurrent = isCurrent
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// How a step's state becomes its accessory.
enum StepCardRule {
    /// An action when the user must act and the step has one, else a pill carrying the state in words. `pillText`
    /// empty falls back to the status's own word.
    static func accessory(needsAction: Bool, action: StepAction?, pillText: String, status: StatusPill.Status) -> StepAccessory {
        if needsAction, let action { return .action(action) }
        return .status(text: pillText, status)
    }

    /// Whether a button shows (the opposite of a pill).
    static func showsAction(_ accessory: StepAccessory) -> Bool {
        if case .action = accessory { return true }
        return false
    }

    static func showsPill(_ accessory: StepAccessory) -> Bool { !showsAction(accessory) }
}

/// The number disc: done is a green tick, the current step the accent, later steps an outline, steps that don't apply
/// a dash.
enum StepMarkerState: Sendable {
    case done, current, later, notApplicable
}

/// A step on This month (design review §3.4): number disc, title, one status line, a pill or one action, and an
/// optional body (the current step's detail: providers, a note).
struct StepCard<Content: View>: View {
    let number: Int
    let marker: StepMarkerState
    let title: String
    let statusLine: String?
    let accessory: StepAccessory
    let content: Content
    @Environment(\.phoneTheme) private var theme

    init(number: Int, marker: StepMarkerState, title: String, statusLine: String? = nil, accessory: StepAccessory,
         @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.number = number
        self.marker = marker
        self.title = title
        self.statusLine = statusLine
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: MangoSpacing.s) {
                disc
                VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: MangoSpacing.xs) {
                        Text(title.figuresUnbroken).mangoFont(.headline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: MangoSpacing.xxs)
                        pillIfAny
                    }
                    if let statusLine, !statusLine.isEmpty {
                        Text(statusLine.figuresUnbroken)
                            .mangoFont(.subheadline).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                    actionIfAny
                }
            }
            .padding(MangoSpacing.cardPadding)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var pillIfAny: some View {
        if case let .status(text, status) = accessory { StatusPill(text, status) }
    }

    @ViewBuilder
    private var actionIfAny: some View {
        if case let .action(action) = accessory {
            Button(action: action.perform) {
                if let symbol = action.systemImage { Label(action.title, systemImage: symbol) } else { Text(action.title) }
            }
            .buttonStyle(.pad(action.isCurrent ? .primary : .secondary))
            .disabled(!action.isEnabled)
        }
    }

    private var disc: some View {
        let fill: Color = marker == .done ? theme.income : .clear
        let ring: Color = switch marker {
        case .done: theme.income
        case .current: theme.accent
        case .later, .notApplicable: theme.textTertiary
        }
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(ring, lineWidth: 2)
            switch marker {
            case .done: Image(systemName: "checkmark").mangoFont(.subheadline, weight: .bold).foregroundStyle(theme.surface)
            case .notApplicable: Image(systemName: "minus").mangoFont(.subheadline, weight: .bold).foregroundStyle(theme.textSecondary)
            case .current: Text("\(number)").mangoFont(.subheadline, weight: .semibold).foregroundStyle(theme.accent)
            case .later: Text("\(number)").mangoFont(.subheadline, weight: .semibold).foregroundStyle(theme.textSecondary)
            }
        }
        .frame(width: ListRowLayout.glyphSize, height: ListRowLayout.glyphSize)
        .accessibilityHidden(true)
    }
}
