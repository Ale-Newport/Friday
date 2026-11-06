import Foundation
import FridayCore

/// Accent- and case-insensitive phrase matching used to recognise routine triggers and to score recall hits.
/// Builds on FridayCore's `TextFolding` so Spanish and English are treated alike ("empezár" == "empezar").
enum PhraseMatching {
    /// Minimum normalised similarity for a fuzzy routine match.
    static let threshold = 0.85

    /// Words that may surround a trigger phrase without changing its meaning: the wake word, greetings,
    /// politeness and "now". They are ignored on both sides of the comparison.
    static let fillerTokens: Set<String> = [
        "friday", "oye", "hey", "hola", "ok", "okay", "vale", "venga", "ya", "ahora", "now", "please", "por", "favor", "porfa",
        "porfavor", "gracias", "thanks", "can", "could", "you", "puedes", "podrias", "quiero", "want", "to",
    ]

    /// Normalised Damerau-Levenshtein similarity in `0…1` (1 = identical). Inputs are folded first.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = Array(TextFolding.fold(first)), b = Array(TextFolding.fold(second))
        if a.isEmpty && b.isEmpty { return 1 }
        guard !a.isEmpty, !b.isEmpty, a.count <= 500, b.count <= 500 else { return 0 }
        let distance = editDistance(a, b)
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    /// How well `text` triggers `phrase`: `1` for an exact match, slightly less for a typo-level difference or when
    /// the utterance is the phrase surrounded only by filler words ("oye Friday, empieza a estudiar ya"), `nil`
    /// otherwise. An utterance that merely *contains* the phrase among other content words ("voy a estudiar inglés
    /// mañana, pon un recordatorio") does not match: at most `max(1, phraseWords / 2)` non-filler words may remain
    /// outside the phrase.
    static func score(text: String, phrase: String) -> Double? {
        let folded = TextFolding.fold(text), target = TextFolding.fold(phrase)
        guard !folded.isEmpty, !target.isEmpty else { return nil }
        if folded == target { return 1 }
        let whole = similarity(folded, target)
        if whole >= threshold { return whole * 0.98 }

        let phraseTokens = contentTokens(target), textTokens = contentTokens(folded)
        guard !phraseTokens.isEmpty, !textTokens.isEmpty, textTokens.count <= 60 else { return nil }
        guard textTokens.count >= phraseTokens.count else {
            // Fewer words than the phrase: only a typo-level difference of the whole thing counts.
            let partial = similarity(textTokens.joined(separator: " "), phraseTokens.joined(separator: " "))
            return partial >= threshold ? partial * 0.95 : nil
        }
        let extra = textTokens.count - phraseTokens.count
        guard extra <= max(1, phraseTokens.count / 2) else { return nil }
        let joinedPhrase = phraseTokens.joined(separator: " ")
        var best = 0.0
        for start in 0...(textTokens.count - phraseTokens.count) {
            let window = textTokens[start..<(start + phraseTokens.count)]
            if Array(window) == phraseTokens { best = max(best, 1); break }
            best = max(best, similarity(window.joined(separator: " "), joinedPhrase))
        }
        guard best >= threshold else { return nil }
        // A perfect window inside filler-only context scores just under an exact match; extra words cost a little.
        return best * (extra == 0 ? 0.97 : 0.9)
    }

    /// The folded word tokens of `text` without filler words; the raw tokens when nothing else is left.
    static func contentTokens(_ text: String) -> [String] {
        let tokens = TextFolding.tokens(text)
        let content = tokens.filter { !fillerTokens.contains($0) }
        return content.isEmpty ? tokens : content
    }

    /// Fraction of `queryTokens` found (as word prefixes) in `foldedText`, `0…1`.
    static func coverage(queryTokens: [String], foldedText: String) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let words = TextFolding.tokens(foldedText)
        var matched = 0
        for token in queryTokens where words.contains(where: { $0 == token || ($0.hasPrefix(token) && token.count >= 3) }) {
            matched += 1
        }
        return Double(matched) / Double(queryTokens.count)
    }

    /// Damerau-Levenshtein: insertion, deletion, substitution and adjacent transposition.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var older = Array(0...b.count)
        var previous = older
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], older[j - 2] + 1)
                }
            }
            older = previous
            previous = current
        }
        return previous[b.count]
    }
}
