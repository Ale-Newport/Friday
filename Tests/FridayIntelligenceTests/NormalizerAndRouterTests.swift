import Foundation
import Testing
@testable import FridayIntelligence

@Suite struct DemonstrativeAndWakeWordTests {
    @Test(arguments: ["copia esto", "cierra este documento", "eventos de este mes", "guarda esto en notas", "qué es esto"])
    func spanishDemonstrativesAreKept(text: String) {
        #expect(UtteranceNormalizer.normalize(text).text == text, Comment(rawValue: text))
    }

    @Test func pausedHesitationsAreStillDropped() {
        #expect(UtteranceNormalizer.normalize("este, abre Notas").text == "abre Notas")
        #expect(UtteranceNormalizer.normalize("esto… pon música").text == "pon música")
        #expect(UtteranceNormalizer.normalize("o sea, abre Notas").text == "abre Notas")
        #expect(UtteranceNormalizer.normalize("you know, open Notes").text == "open Notes")
        #expect(UtteranceNormalizer.normalize("I like, um, jazz").text == "I jazz")
    }

    @Test func theWeekdayFridayIsNotWakeWordResidue() {
        let remind = UtteranceNormalizer.normalize("Friday at 9 remind me to call Ana", wakeWord: "Friday")
        #expect(remind.text == "Friday at 9 remind me to call Ana")
        #expect(!remind.strippedWakeWord)
        #expect(UtteranceNormalizer.normalize("Friday morning schedule a dentist appointment", wakeWord: "Friday").text == "Friday morning schedule a dentist appointment")
        #expect(UtteranceNormalizer.normalize("Friday 9am call the bank", wakeWord: "Friday").strippedWakeWord == false)
    }

    @Test func theWakeWordFridayIsStripped() {
        #expect(UtteranceNormalizer.normalize("Friday, open Notes", wakeWord: "Friday").text == "open Notes")
        #expect(UtteranceNormalizer.normalize("Friday open Notes", wakeWord: "Friday").text == "open Notes")
        #expect(UtteranceNormalizer.normalize("hey Friday what time is it", wakeWord: "Friday").text == "what time is it")
        #expect(UtteranceNormalizer.normalize("Oye Friday, pon música", wakeWord: "Friday").text == "pon música")
        #expect(UtteranceNormalizer.normalize("Friday", wakeWord: "Friday").strippedWakeWord)
        // With another configured name, "friday" is a plain word.
        #expect(UtteranceNormalizer.normalize("Friday at 9 remind me", wakeWord: "Jarvis").text == "Friday at 9 remind me")
    }
}

@Suite struct KeywordBoundaryTests {
    @Test func keywordsMatchAtWordStartsOnly() {
        #expect(KeywordRouter.route("open gmail") == .system)  // "mail" inside "gmail" is not communication
        #expect(KeywordRouter.route("display the context") == nil)  // "play " inside "display", "text " inside "context"
        #expect(KeywordRouter.route("send a text to Ana") == .communication)
        #expect(KeywordRouter.route("¿qué es un agujero negro?") == .information)
        #expect(KeywordRouter.route("set my reminders for tomorrow") == .reminders)
        #expect(KeywordRouter.route("unlock the clock app") == nil)  // "lock" inside "unlock"/"clock" is not system
    }
}
