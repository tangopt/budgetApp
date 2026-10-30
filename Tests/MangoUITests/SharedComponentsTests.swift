import XCTest
import SwiftUI
@testable import BudgetCore
@testable import MangoUI

/// Step 3 of the redesign: the shared components' rules (design review 2026-10-28 §3.4): a step shows a pill or an
/// action, never both; a status pill always has its word and keeps its contrast in every set; list rows keep their
/// figures whole; page headers hold one primary action and a short context line.
final class SharedComponentsTests: XCTestCase {
    // MARK: Step card

    private func action(current: Bool = true) -> StepAction { StepAction("Prepare statement", isCurrent: current) {} }

    func testAStepThatNeedsYouAndHasAnActionShowsTheActionAndNoPill() {
        let accessory = StepCardRule.accessory(needsAction: true, action: action(), pillText: "To do", status: .todo)
        XCTAssertTrue(StepCardRule.showsAction(accessory))
        XCTAssertFalse(StepCardRule.showsPill(accessory))
    }

    func testAStepWithNothingToDoShowsAPillEvenWhenItHasAnAction() {
        let accessory = StepCardRule.accessory(needsAction: false, action: action(), pillText: "Waiting for tenant", status: .waiting)
        XCTAssertTrue(StepCardRule.showsPill(accessory))
        guard case let .status(text, status) = accessory else { return XCTFail("expected a pill") }
        XCTAssertEqual(text, "Waiting for tenant")
        XCTAssertEqual(status, .waiting)
    }

    func testAStepThatNeedsYouButOffersNoActionShowsAPill() {
        let accessory = StepCardRule.accessory(needsAction: true, action: nil, pillText: "To do", status: .todo)
        XCTAssertTrue(StepCardRule.showsPill(accessory))
        XCTAssertFalse(StepCardRule.showsAction(accessory))
    }

    func testOnlyTheCurrentStepsActionIsFilled() {
        XCTAssertTrue(action(current: true).isCurrent)
        XCTAssertFalse(action(current: false).isCurrent)
    }

    // MARK: Status pill

    func testEveryStatusHasAWord() {
        for status in StatusPill.Status.allCases { XCTAssertFalse(status.defaultWord.isEmpty) }
        // Different statuses never share a word, so colour is never the only difference.
        XCTAssertEqual(Set(StatusPill.Status.allCases.map(\.defaultWord)).count, StatusPill.Status.allCases.count)
    }

    func testAPillWithNoTextFallsBackToItsStatusWord() {
        XCTAssertEqual(StatusPill("", .done).text, "Done")
        XCTAssertEqual(StatusPill("Part paid", .waiting).text, "Part paid")
    }

    func testStatusWordsReadOnTheirTintInEverySet() {
        for set in ThemeSet.all {
            for (variant, roles) in [("light", set.light), ("dark", set.dark)] {
                for status in StatusPill.Status.allCases {
                    let pair = status.roles
                    let ratio = ColorMath.contrastRatio(roles[keyPath: pair.text], roles[keyPath: pair.fill])
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(set.name) \(variant) \(status)")
                }
            }
        }
    }

    // MARK: List row

    func testARowIsAtLeast56PointsAndNeverShowsMoreThanTwoActions() {
        XCTAssertEqual(ListRowLayout.minHeight, 56)
        let actions = [RowAction.openSite, .linkDocument, .check].map { ListRowAction($0) {} }
        XCTAssertEqual(ListRowLayout.visibleActions(actions).map(\.action), [.openSite, .linkDocument])
        XCTAssertEqual(ListRowLayout.visibleActions([]).count, 0)
    }

    func testTheFigureIsPlacedBeforeTheTextSoTheTextGivesWay() {
        XCTAssertGreaterThan(ListRowLayout.figurePriority, ListRowLayout.textPriority)
        XCTAssertEqual(ListRowLayout.titleLineLimit, 1)
    }

    func testTheFigureGoesUnderTheTextAtAccessibilitySizes() {
        XCTAssertFalse(ListRowLayout.stacksFigure(at: .large))
        XCTAssertFalse(ListRowLayout.stacksFigure(at: .xxxLarge))
        XCTAssertTrue(ListRowLayout.stacksFigure(at: .accessibility1))
        XCTAssertTrue(ListRowLayout.stacksFigure(at: .accessibility5))
    }

    // MARK: Edges

    func testEdgeStylesDecideDividersAndBorders() {
        XCTAssertTrue(MangoEdgeRules.drawsDividers(.standard))
        XCTAssertTrue(MangoEdgeRules.drawsDividers(.bordered))
        XCTAssertFalse(MangoEdgeRules.drawsDividers(.flat))
        XCTAssertTrue(MangoEdgeRules.drawsBorders(.bordered))
        XCTAssertFalse(MangoEdgeRules.drawsBorders(.standard))
        XCTAssertFalse(MangoEdgeRules.drawsBorders(.flat))
    }

    func testTheSetsUseTheEdgeStylesTheDesignNames() {
        XCTAssertEqual(ThemeSet.all.first { $0.id == "flat" }?.edges, .flat)
        XCTAssertEqual(ThemeSet.all.first { $0.id == "clear" }?.edges, .bordered)
    }

    // MARK: Page header and context picker

    private func picker(_ name: String) -> ContextPicker {
        ContextPicker(label: name, accessibilityName: name, options: [.init(id: "a", title: "A"), .init(id: "b", title: "B")],
                      selectedId: "a") { _ in }
    }

    func testAHeaderKeepsAtMostTwoContextPickers() {
        XCTAssertEqual(PageHeaderRules.maxContexts, 2)
        XCTAssertEqual(PageHeaderRules.contexts([picker("Tenancy"), picker("Year"), picker("Extra")]).map(\.label), ["Tenancy", "Year"])
    }

    func testTheContextLineShowsOnlyWhenItHasSomething() {
        XCTAssertFalse(PageHeaderRules.hasContextLine(contexts: 0, subtitle: nil))
        XCTAssertFalse(PageHeaderRules.hasContextLine(contexts: 0, subtitle: ""))
        XCTAssertTrue(PageHeaderRules.hasContextLine(contexts: 1, subtitle: nil))
        XCTAssertTrue(PageHeaderRules.hasContextLine(contexts: 0, subtitle: "October 2026"))
    }

    func testAPickerWithOneChoiceIsALabel() {
        XCTAssertFalse(ContextPicker.isInteractive(optionCount: 0))
        XCTAssertFalse(ContextPicker.isInteractive(optionCount: 1))
        XCTAssertTrue(ContextPicker.isInteractive(optionCount: 2))
    }

    func testAPickerOverItemsSaysTheShortTitleAndMenusTheFullOne() {
        struct Tenancy { let id: Int; let label: String; let days: String }
        let items = [Tenancy(id: 1, label: "Tenancy 1", days: "2023"), Tenancy(id: 2, label: "Tenancy 2", days: "2024 – ongoing")]
        var chosen: Int?
        let picker = ContextPicker("Tenancy", items: items, selected: "2", fallback: "Tenancy", id: { String($0.id) },
                                   title: { "\($0.label) · \($0.days)" }, shortTitle: { $0.label }, choose: { chosen = $0.id })
        XCTAssertEqual(picker.label, "Tenancy 2")
        XCTAssertEqual(picker.options.map(\.title), ["Tenancy 1 · 2023", "Tenancy 2 · 2024 – ongoing"])
        picker.choose("1")
        XCTAssertEqual(chosen, 1)
        picker.choose("nope")
        XCTAssertEqual(chosen, 1)
        let none = ContextPicker("Tenancy", items: items, selected: nil, fallback: "Tenancy", id: { String($0.id) },
                                 title: { $0.label }, choose: { _ in })
        XCTAssertEqual(none.label, "Tenancy")
    }

    // MARK: Upcoming list

    func testAnUpcomingItemBecomesADueFigureOrWords() {
        func item(_ amount: Int?) -> HomeSummary.UpcomingItem {
            HomeSummary.UpcomingItem(id: "bill/1", date: Date(timeIntervalSince1970: 1_800_000_000), title: "Insurance",
                                     amountMinorUnits: amount, currency: .gbp, source: .bill, isEstimate: false)
        }
        XCTAssertEqual(UpcomingEntry(item(1_000)).figure, .due(minorUnits: 1_000, currency: .gbp))
        XCTAssertEqual(UpcomingEntry(item(nil)).figure, .words("Amount not known"))
        XCTAssertEqual(UpcomingEntry(item(1_000)).title, "Insurance")
    }
}
