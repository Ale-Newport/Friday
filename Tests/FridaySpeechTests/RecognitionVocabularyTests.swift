import Foundation
import Testing
import FridayCore
@testable import FridaySpeech

@Suite struct RecognitionVocabularyTests {
    @Test func snapsSpellingsThatSoundLikeAnEntry() {
        let vocabulary = RecognitionVocabulary(["Zylora", "Quorvix", "Vexlar", "Marc", "Jon"])
        #expect(vocabulary.apply(to: "Open Xylora.") == "Open Zylora.")
        #expect(vocabulary.apply(to: "Open Corvix and search for flights.") == "Open Quorvix and search for flights.")
        #expect(vocabulary.apply(to: "Play some music by Wexler.") == "Play some music by Vexlar.")
        #expect(vocabulary.apply(to: "Play some music by Vexler.") == "Play some music by Vexlar.")
        #expect(vocabulary.apply(to: "Call Mark tomorrow.") == "Call Marc tomorrow.")
        #expect(vocabulary.apply(to: "Send it to John.") == "Send it to Jon.")
    }

    @Test func leavesUnrelatedWordsAlone() {
        let vocabulary = RecognitionVocabulary(["Chrome", "Notes", "Queen", "Zylora"])
        #expect(vocabulary.apply(to: "a crow sat on the notice board") == "a crow sat on the notice board")
        #expect(vocabulary.apply(to: "what's the weather tomorrow") == "what's the weather tomorrow")
        #expect(vocabulary.apply(to: "recuérdame comprar leche mañana a las ocho") == "recuérdame comprar leche mañana a las ocho")
        #expect(vocabulary.apply(to: "") == "")
        #expect(RecognitionVocabulary([]).apply(to: "Open Xylora.") == "Open Xylora.")
    }

    @Test func fixesCasingOfAnEntryHeardRight() {
        let vocabulary = RecognitionVocabulary(["Chrome", "Notes"])
        #expect(vocabulary.apply(to: "open chrome and notes") == "open Chrome and Notes")
        #expect(vocabulary.apply(to: "open Chrome") == "open Chrome")
    }

    @Test func matchesRunsOfWordsAgainstMultiWordEntries() {
        let vocabulary = RecognitionVocabulary(["Thandiwe Okonkwo", "Weekly Meeting"])
        // A two-word name heard as two other words, and one heard as a single word.
        #expect(vocabulary.apply(to: "send a message to Tandiwe Okonkvo") == "send a message to Thandiwe Okonkwo")
        #expect(vocabulary.apply(to: "open the weeklymeeting note") == "open the Weekly Meeting note")
        #expect(vocabulary.apply(to: "open the weekly meeting note") == "open the Weekly Meeting note")
    }

    @Test func neverTouchesVeryShortWordsOrEntries() {
        let vocabulary = RecognitionVocabulary(["Jo", "AI", "Siri"])
        #expect(vocabulary.entries.map(\.text) == ["Siri"], "entries under three letters are dropped")
        #expect(vocabulary.apply(to: "so I said yes") == "so I said yes")
        #expect(vocabulary.apply(to: "ask siri") == "ask Siri")
    }

    @Test func foldingAndDistance() {
        #expect(RecognitionVocabulary.raw("Ñandú-Café 3!") == "nanducafe3")
        #expect(RecognitionVocabulary.soft("xylora") == RecognitionVocabulary.soft("zylora"))
        #expect(RecognitionVocabulary.soft("quorvix") == RecognitionVocabulary.soft("corvix"))
        #expect(RecognitionVocabulary.soft("marc") == RecognitionVocabulary.soft("mark"))
        #expect(RecognitionVocabulary.soft("philip") == RecognitionVocabulary.soft("filip"))
        #expect(RecognitionVocabulary.soft("vexlar") == "bekslar")
        #expect(RecognitionVocabulary.editDistance("kitten", "sitting") == 3)
        #expect(RecognitionVocabulary.editDistance("abcd", "abdc") == 1, "a transposition is one edit")
        #expect(RecognitionVocabulary.editDistance("", "abc") == 3)
        #expect(RecognitionVocabulary.similarity("same", "same") == 1)
        #expect(RecognitionVocabulary.similarity("", "") == 1)
    }
}

@Suite struct ContextualStringsTests {
    @Test func cleansDeduplicatesAndCapsTheVocabulary() {
        let words = AppleSpeechRecognizer.contextualStrings(from: ["  Chrome ", "", "chrome", "Notes", "\n", "Jarvis", "Notes", String(repeating: "x", count: 61)])
        #expect(words == ["Chrome", "Notes", "Jarvis"])
        let many = (0..<250).map { "Word\($0)" }
        let capped = AppleSpeechRecognizer.contextualStrings(from: many)
        #expect(capped.count == AppleSpeechRecognizer.maxVocabularyEntries)
        #expect(capped.first == "Word0", "the first entries (the user's own list) win")
        #expect(AppleSpeechRecognizer.contextualStrings(from: []).isEmpty)
    }

    @Test func availabilityMessagesExistInBothLanguages() {
        let availability = EngineAvailability.needsSetup(LocalizedText(en: "Install it.", es: "Instálalo."))
        #expect(availability.detail(in: .en) == "Install it.")
        #expect(availability.detail(in: .es) == "Instálalo.")
        #expect(!availability.isAvailable)
        #expect(EngineAvailability.available.detail(in: .es) == nil)
        #expect(AppleSpeechRecognizer.names(of: [.en, .es], in: .en) == "English and Spanish")
        #expect(AppleSpeechRecognizer.names(of: [.en, .es], in: .es) == "inglés y español")
    }

    @Test func appleAvailabilityIsHonestAboutTheModels() async {
        // On a Mac with the models installed this is available; without them it says so in both languages rather
        // than claiming to be ready. Either way the answer is a definite one.
        let availability = await AppleSpeechRecognizer().availability()
        switch availability {
        case .available: break
        case .needsSetup(let text), .unavailable(let text):
            #expect(!text.en.isEmpty && !text.es.isEmpty && text.en != text.es)
        }
    }
}
