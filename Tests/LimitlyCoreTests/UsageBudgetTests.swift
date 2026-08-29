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

    func testWeeklyBudgetPercentageIsDistinctFromDailyBudgetPercentage() throws {
        let weeklyUsage = UsageTotals(totalTokens: 40_000, totalCost: 121.69)
        let dailyBudget = UsageBudget(unit: .dollars, amount: 20)
        let weeklyBudget = UsageBudget(unit: .dollars, amount: 140)

        XCTAssertEqual(try XCTUnwrap(dailyBudget.percentage(for: weeklyUsage)), 608.45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(weeklyBudget.percentage(for: weeklyUsage)), 86.9214285714, accuracy: 0.001)
    }

    func testZeroBudgetHasNoPercentage() {
        let usage = UsageTotals(totalTokens: 2_500, totalCost: 7.50)
        XCTAssertNil(UsageBudget(unit: .tokens, amount: 0).percentage(for: usage))
        XCTAssertNil(UsageBudget(unit: .dollars, amount: 0).percentage(for: usage))
    }
}
