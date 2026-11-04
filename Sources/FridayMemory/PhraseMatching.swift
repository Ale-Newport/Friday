import Foundation
import FridayCore

/// Accent- and case-insensitive phrase matching used to recognise routine triggers and to score recall hits.
/// Builds on FridayCore's `TextFolding` so Spanish and English are treated alike ("empezár" == "empezar").
enum PhraseMatching {
    /// Minimum normalised similarity for a fuzzy routine match.
    static let threshold = 0.85

    /// Normalised Damerau-Levenshtein similarity in `0…1` (1 = identical). Inputs are folded first.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = Array(TextFolding.fold(first)), b = Array(TextFolding.fold(second))
        if a.isEmpty && b.isEmpty { return 1 }
        guard !a.isEmpty, !b.isEmpty, a.count <= 500, b.count <= 500 else { return 0 }
        let distance = editDistance(a, b)
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    /// How well `text` triggers `phrase`: `1` for an exact match, slightly less when the text merely contains the
    /// phrase or a window of it is similar enough, `nil` when it does not match.
    static func score(text: String, phrase: String) -> Double? {
        let folded = TextFolding.fold(text), target = TextFolding.fold(phrase)
        guard !folded.isEmpty, !target.isEmpty else { return nil }
        if folded == target { return 1 }
        if folded.contains(target) { return 0.95 + 0.04 * Double(target.count) / Double(folded.count) }
        let whole = similarity(folded, target)
        if whole >= threshold { return whole * 0.98 }
        // A longer utterance around the phrase ("Friday, empieza a estudiar ya"): compare token windows.
        let phraseTokens = TextFolding.tokens(target), textTokens = TextFolding.tokens(folded)
        guard !phraseTokens.isEmpty, textTokens.count > phraseTokens.count, textTokens.count <= 60 else { return nil }
        let joinedPhrase = phraseTokens.joined(separator: " ")
        var best = 0.0
        for start in 0...(textTokens.count - phraseTokens.count) {
            let window = textTokens[start..<(start + phraseTokens.count)].joined(separator: " ")
            best = max(best, similarity(window, joinedPhrase))
        }
        return best >= threshold ? best * 0.9 : nil
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
