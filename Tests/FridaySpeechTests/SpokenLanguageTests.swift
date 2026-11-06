import Foundation
import Testing
import FridayCore
@testable import FridaySpeech

@Suite struct SpokenLanguageTests {
    @Test func keepsTheConversationLanguageForTextInIt() {
        #expect(SpokenLanguage.forSynthesis("Hecho. He creado el recordatorio para mañana a las ocho.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Done. I created the reminder for tomorrow at eight.", declared: .en) == .en)
        #expect(SpokenLanguage.forSynthesis("Abriendo Chrome.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Opening Safari now.", declared: .en) == .en)
    }

    @Test func switchesWhenTheReplyIsClearlyInTheOtherLanguage() {
        #expect(SpokenLanguage.forSynthesis("I need you to finish that in the browser. Say done when you're ready.", declared: .es) == .en)
        #expect(SpokenLanguage.forSynthesis("Necesito que lo completes tú en el navegador. Dime listo cuando termines.", declared: .en) == .es)
        #expect(SpokenLanguage.forSynthesis("Opening Chrome.", declared: .es) == .en)
        #expect(SpokenLanguage.forSynthesis("Abriendo Chrome.", declared: .en) == .es)
    }

    @Test func mixedSentencesFollowTheirDominantLanguage() {
        // Product names and quoted titles in the other language do not flip a reply.
        #expect(SpokenLanguage.forSynthesis("Abrí Notes y Calendar; la nota se llama Weekly Meeting.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Opened Notes and Calendar; the note is called Reunión semanal.", declared: .en) == .en)
        // A reply that is mostly in the other language is voiced in it.
        #expect(SpokenLanguage.forSynthesis("Sure, opening Chrome and searching for machine learning.", declared: .es) == .en)
        #expect(SpokenLanguage.forSynthesis("Claro, abro Chrome y busco machine learning.", declared: .en) == .es)
        // Code-switched commands go with the words that carry them.
        #expect(SpokenLanguage.forSynthesis("pon mi playlist de estudiar y abre Notes", declared: .en) == .es)
    }

    @Test func shortAndEmptyTextsStayInTheDeclaredLanguage() {
        #expect(SpokenLanguage.forSynthesis("", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("   ", declared: .en) == .en)
        #expect(SpokenLanguage.forSynthesis("42.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("No.", declared: .en) == .en)
        #expect(SpokenLanguage.forSynthesis("Vale.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Hasta luego.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Jarvis está listo.", declared: .es) == .es)
        #expect(SpokenLanguage.forSynthesis("Jarvis is ready.", declared: .en) == .en)
    }
}
