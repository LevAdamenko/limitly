import XCTest
@testable import LimitlyCore

final class UsageBudgetTests: XCTestCase {
    func testTokenPercentageAgainstBudget() {
        let usage = UsageTotals(totalTokens: 2_500, totalCost: 4)
        let budget = UsageBudget(unit: .tokens, amount: 10_000)
        XCTAssertEqual(budget.percentage(for: usage), 25)
    }

    func testDollarPercentageAgainstBudget() {
        let usage = UsageTotals(totalTokens: 2_500, totalCost: 7.50)
        let budget = UsageBudget(unit: .dollars, amount: 10)
        XCTAssertEqual(budget.percentage(for: usage), 75)
    }

    func testZeroBudgetHasNoPercentage() {
        let usage = UsageTotals(totalTokens: 2_500, totalCost: 7.50)
        XCTAssertNil(UsageBudget(unit: .tokens, amount: 0).percentage(for: usage))
        XCTAssertNil(UsageBudget(unit: .dollars, amount: 0).percentage(for: usage))
    }
}
