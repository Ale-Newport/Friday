import Foundation
import NaturalLanguage
import FridayCore

/// Which voice a reply should be spoken with. The orchestrator knows the language of the conversation; the text it
/// hands over may still be in the other one (a model answering in English to a Spanish question, a quoted title, a
/// mixed sentence), and a Spanish voice reading English is hard to follow. The reply's own words decide, with the
/// conversation's language as the prior: it stays unless the text clearly reads as the other language.
public enum SpokenLanguage {
    /// A text is voiced in the other language only when the recogniser is at least this sure of it.
    public static let switchThreshold = 0.75
    /// How much the declared language is favoured before the text is looked at.
    static let declaredPrior = 0.6

    /// The language `text` should be synthesised in, given the language the conversation is in.
    public static func forSynthesis(_ text: String, declared: Language) -> Language {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return declared }
        let other: Language = declared == .es ? .en : .es
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.languageHints = [nlLanguage(declared): declaredPrior, nlLanguage(other): 1 - declaredPrior]
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let confidence = hypotheses[nlLanguage(other)] ?? 0
        return confidence >= switchThreshold ? other : declared
    }

    private static func nlLanguage(_ language: Language) -> NLLanguage {
        language == .es ? .spanish : .english
    }
}
