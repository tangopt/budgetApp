import WidgetKit
import SwiftUI

@main
struct MangoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        MonthSpendWidget()
        PropertyMonthWidget()
        PaydayWidget()
    }
}
