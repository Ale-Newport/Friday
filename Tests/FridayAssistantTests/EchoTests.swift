import Foundation
import Testing
@testable import FridayAssistant

@Suite struct EchoTests {
    @Test func aCaptureThatRepeatsTheReplyIsAnEcho() {
        let spoken = "Thursday, November 5, 2026 at 11:18 PM"
        #expect(Assistant.isEcho("Thursday November 5 2026 at 11 18 PM", of: spoken))
        #expect(Assistant.isEcho("november 5 2026 at 11", of: spoken))
    }

    @Test func aNewRequestIsNotAnEcho() {
        let spoken = "I've opened Notes."
        #expect(!Assistant.isEcho("and now play some music", of: spoken))
        #expect(!Assistant.isEcho("abre Calculadora", of: spoken))
        #expect(!Assistant.isEcho("yes", of: spoken))  // too short to judge; never dropped
        #expect(!Assistant.isEcho("open notes again please", of: ""))
    }
}
