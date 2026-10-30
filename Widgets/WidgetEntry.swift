import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

/// One moment of a widget: the stored snapshot (nil: none yet) and the day it counts from.
struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// The timeline all three widgets share: an entry now and one at the next midnight (the payday count moves by itself),
/// then a new timeline after it. The snapshot is only read, from the App Group; the app writes it.
struct SnapshotProvider: TimelineProvider {
    private var store: FileWidgetSnapshotStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PhoneAppGroup.identifier)
            .map { FileWidgetSnapshotStore(directory: $0) }
    }

    private static let sample = WidgetSnapshot(generatedAt: Date(), netWorthMinorUnits: 1_234_500, leftToSpendMinorUnits: 45_600,
                                               paydayDate: Date().addingTimeInterval(12 * 86_400), showFiguresOnLockScreen: true,
                                               monthSpend: MonthSpendFigures(start: Date().addingTimeInterval(-9 * 86_400), spentMinorUnits: 91_200, budgetMinorUnits: 240_000,
                                                                             dayOfMonth: 10, daysInMonth: 30, cumulativeSpent: [8_000, 15_000, 22_000, 31_000, 40_000, 52_000, 61_000, 72_000, 80_000, 91_200],
                                                                             overBudget: [.init(name: "Eating out", spentMinorUnits: 21_000, budgetMinorUnits: 15_000)]),
                                               propertyMonths: [RechargePipelineFigures(tenancyName: "Tenancy 1", month: Date(), utilities: [.init(name: "Power", kind: "electricity", isIn: true),
                                                                                                                                              .init(name: "Water", kind: "water", isIn: false)],
                                                                                         statementSent: false, paidByTenant: false, outstandingMinorUnits: 12_000, currencyCode: "EUR")])

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: Date(), snapshot: context.isPreview ? Self.sample : store?.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = store?.read()
        let midnight = MonthRange.calendar.startOfDay(for: MonthRange.calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        completion(Timeline(entries: [WidgetEntry(date: now, snapshot: snapshot), WidgetEntry(date: midnight, snapshot: snapshot)],
                            policy: .after(midnight)))
    }
}

/// A figure that hides while the device is locked, unless it is on the lock screen and the setting allows figures.
struct FigureModifier: ViewModifier {
    let redacted: Bool

    func body(content: Content) -> some View {
        if redacted { content.privacySensitive() } else { content }
    }
}

extension View {
    func figureSensitivity(_ redacted: Bool) -> some View {
        modifier(FigureModifier(redacted: redacted))
    }
}

/// The widget's words when there is no snapshot.
struct EmptyWidgetView: View {
    var body: some View {
        Text(WidgetPresentation.emptyText)
            .mangoFont(.footnote)
            .multilineTextAlignment(.center)
    }
}
