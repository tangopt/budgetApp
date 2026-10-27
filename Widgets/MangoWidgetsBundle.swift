import WidgetKit
import SwiftUI

@main
struct MangoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        LeftThisMonthWidget()
        PaydayWidget()
    }
}
