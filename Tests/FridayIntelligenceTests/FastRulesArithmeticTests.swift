import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

/// Digit grouping in spoken/typed arithmetic: "2,450" is a thousands-grouped number in English (it used to become
/// 2.45, so "what's 18% of 2,450?" answered 0.441), "2.450" is the Spanish spelling, and a lone comma stays a decimal.
@Suite struct FastRulesArithmeticTests {
    private let tools: [ToolDescriptor] = [
        ToolDescriptor(name: "utilities.calculate", integration: "utilities", title: "Calculate", summary: "Calculate", parameters: [.string("expression", "e", required: true)], safety: .readOnly),
    ]

    private func expression(_ text: String, _ language: Language) -> String? {
        guard let plan = FastRules.plan(for: text, language: language, tools: tools),
              plan.steps.first?.tool == "utilities.calculate",
              case .string(let value)? = plan.steps.first?.arguments["expression"] else { return nil }
        return value
    }

    @Test func englishThousandsSeparatorsAreGrouping() {
        #expect(expression("What's 18% of 2,450?", .en) == "18/100*2450")
        #expect(expression("what is 1,234,567 plus 1", .en) == "1234567+1")
        #expect(expression("what's 2,450.5 times 2", .en) == "2450.5*2")
    }

    @Test func spanishThousandsSeparatorsAreGrouping() {
        #expect(FastRules.arithmetic("cuanto es 18% de 2.450", language: .es) == "18/100*2450")
        #expect(FastRules.arithmetic("cuanto es 1.234.567,5 mas 1", language: .es) == "1234567.5+1")
    }

    @Test func aLoneCommaIsStillADecimalPoint() {
        #expect(FastRules.arithmetic("cuanto es 2,5 por 4", language: .es) == "2.5*4")
        #expect(FastRules.arithmetic("what's 2,5 times 4", language: .en) == "2.5*4")
        #expect(FastRules.arithmetic("what's 2.5 times 4", language: .en) == "2.5*4")
        #expect(FastRules.arithmetic("cuanto es 2.5 por 4", language: .es) == "2.5*4")
    }

    @Test func nonArithmeticIsLeftAlone() {
        #expect(FastRules.arithmetic("what's the weather tomorrow", language: .en) == nil)
        #expect(FastRules.arithmetic("what is 2,450", language: .en) == nil)
    }
}
