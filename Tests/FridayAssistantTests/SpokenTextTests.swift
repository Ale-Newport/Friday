import Testing
@testable import FridayAssistant

@Suite struct SpokenTextTests {
    @Test func stripsMarkdownLinksAndCode() {
        let text = "Found it: [Flight](https://example.com/x) for **€45**.\n```json\n{}\n```\nSee https://example.com too."
        let spoken = SpokenText.clean(text)
        #expect(!spoken.contains("http"))
        #expect(!spoken.contains("**"))
        #expect(spoken.contains("Flight"))
        #expect(spoken.contains("€45"))
    }

    @Test func dropsVerificationNotes() {
        #expect(SpokenText.clean("Created the reminder. (verified: read back by id)") == "Created the reminder.")
    }

    @Test func shortensAtSentenceBoundary() {
        let long = String(repeating: "This is a sentence. ", count: 100)
        let spoken = SpokenText.clean(long, maxCharacters: 200)
        #expect(spoken.count <= 200)
        #expect(spoken.hasSuffix("."))
    }
}
