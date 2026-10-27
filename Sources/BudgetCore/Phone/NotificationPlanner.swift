import Foundation
import GRDB

/// One reminder the iPhone should have scheduled: a stable id (the same event keeps its id, so it is never sent twice),
/// when it fires, and its words.
public struct PlannedNotification: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: NotificationKind
    public var fireDate: Date
    public var title: String
    public var body: String
    public var link: PhoneTabLink

    /// The words as the notification center holds them (`NotificationCenterClient.pendingContent`): a pending
    /// reminder whose words differ from the plan's is replaced.
    public var content: String { Self.content(title: title, body: body) }

    public static func content(title: String, body: String) -> String { title + "\n" + body }
}

/// The reminders for the device's viewer (step 7b spec §2.4), read from Home's and Property's own models, none
/// recomputed: rent not seen once the property screen calls it late (10 days after it was due), a bill 3 days before, a tax payment 7 days before and, for the
/// admin, no statement for 14 days. Only for areas the viewer can see; no amount unless the lock-screen setting is on.
public enum NotificationPlanner {
    static let billLeadDays = 3
    static let taxLeadDays = 7
    static let noImportDays = 14
    /// A reminder discovered late fires this long after `now`.
    static let minimumDelay: TimeInterval = 60
    static let fireHour = 9

    public static func plan(db: Database, viewer: PhoneViewer, today: Date, now: Date, settings: PhoneOutputSettings,
                            calendar: Calendar = .current) throws -> [PlannedNotification] {
        guard let actor = try DeviceWriter.actor(viewer, db: db) else { return [] }
        let model = MonthRange.calendar
        let day = model.startOfDay(for: today)
        let figures = settings.showFiguresOnLockScreen

        func canView(_ area: AccessArea) throws -> Bool { try AccessPolicy.level(actor, area, db: db) >= .view }
        let propertyVisible = try canView(.property)
        let forecastVisible = try canView(.forecast)
        var taxVisible = false
        for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person ORDER BY id") where !taxVisible {
            taxVisible = try canView(try AccessArea.tax(ofPerson: personId, db: db))
        }

        /// 09:00 on `trigger`'s day in `calendar`, never sooner than a minute from now.
        func fireDate(trigger: Date) -> Date {
            let parts = model.dateComponents([.year, .month, .day], from: trigger)
            let nine = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: fireHour)) ?? trigger
            return max(nine, now.addingTimeInterval(minimumDelay))
        }
        func dayText(_ date: Date) -> String {
            let parts = model.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func money(_ minorUnits: Int?, _ currency: Currency) -> String? { minorUnits.map { Money.format($0, currency: currency) } }

        var planned: [PlannedNotification] = []

        if propertyVisible, settings.notifications.contains(.rentLate) {
            for glance in try PropertyGlance.all(db: db, today: day) {
                guard case .late(let due) = glance.rent, let propertyId = glance.property.id else { continue }
                let trigger = model.date(byAdding: .day, value: RentReceiptMatching.Options().windowDays, to: model.startOfDay(for: due))!
                let words = NotificationCopy.rentLate(property: glance.property.name, showFigures: figures,
                                                      amount: money(glance.rentMinorUnits, glance.property.currency))
                planned.append(PlannedNotification(id: "rent/\(propertyId)/\(dayText(due))", kind: .rentLate, fireDate: fireDate(trigger: trigger),
                                                   title: words.title, body: words.body, link: .home))
            }
        }

        let wantsBills = settings.notifications.contains(.billDue)
        let wantsTax = settings.notifications.contains(.taxDue)
        let wantsImport = settings.notifications.contains(.noImport) && actor.isAdmin
        if wantsBills || wantsTax || wantsImport {
            let input = try DashboardInput.load(db: db, today: day, actuals: try viewer.actuals(db: db, today: day))
            if !input.isEmpty {
                let home = try HomeSummary.make(input, db: db)
                for item in home.upcoming where model.startOfDay(for: item.date) >= day {
                    let isTax = item.obligationKind == .ukSelfAssessmentJanuary || item.obligationKind == .ukSelfAssessmentJuly
                    let visible = item.source == .bill ? forecastVisible : (isTax ? propertyVisible && taxVisible : propertyVisible)
                    guard visible, isTax ? wantsTax : wantsBills else { continue }
                    let due = model.startOfDay(for: item.date)
                    let trigger = model.date(byAdding: .day, value: -(isTax ? taxLeadDays : billLeadDays), to: due)!
                    let amount = money(item.amountMinorUnits, item.currency)
                    let words = isTax ? NotificationCopy.taxDue(name: item.title, date: due, showFigures: figures, amount: amount)
                                      : NotificationCopy.billDue(name: item.title, date: due, showFigures: figures, amount: amount)
                    planned.append(PlannedNotification(id: item.id, kind: isTax ? .taxDue : .billDue, fireDate: fireDate(trigger: trigger),
                                                       title: words.title, body: words.body, link: .home))
                }
                if wantsImport, let age = home.dataAgeDays, age >= noImportDays, let last = home.freshness.dataThrough {
                    let words = NotificationCopy.noImport()
                    planned.append(PlannedNotification(id: "import/\(dayText(last))", kind: .noImport, fireDate: now.addingTimeInterval(minimumDelay),
                                                       title: words.title, body: words.body, link: .home))
                }
            }
        }
        return planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }
}

/// What to change in the notification center so it holds exactly the plan.
public struct NotificationReconciliation: Equatable, Sendable {
    public var add: [PlannedNotification]
    public var remove: [String]
}

public enum NotificationReconciler {
    /// `remove`: pending ids no longer planned (the rent arrived, the bill was paid, the setting went off). `add`:
    /// planned reminders neither pending nor in the `ledger` (every id the app has ever handed to the notification
    /// center), so a reminder that already fired is never sent again. A pending reminder whose words (`pending`, id →
    /// `PlannedNotification.content`) differ from the plan's (the lock-screen figures went off) is in both: it never
    /// fired, so the ledger does not hold it back.
    public static func reconcile(planned: [PlannedNotification], pending: [String: String], ledger: Set<String>) -> NotificationReconciliation {
        let plannedIds = Set(planned.map(\.id))
        let changed = planned.filter { note in pending[note.id].map { $0 != note.content } ?? false }
        let changedIds = Set(changed.map(\.id))
        return NotificationReconciliation(add: planned.filter { changedIds.contains($0.id) || (pending[$0.id] == nil && !ledger.contains($0.id)) },
                                          remove: Set(pending.keys).subtracting(plannedIds).union(changedIds).sorted())
    }
}
