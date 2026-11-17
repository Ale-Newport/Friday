import Foundation

/// Cuts a reply into the phrases the voice says one after another.
///
/// The first phrase is cut early — at the first comma, colon, semicolon or dash once it has a few words, or after a
/// handful of words when the first sentence is long — so the first audio is ready in a fraction of the time a whole
/// sentence takes (the idea comes from Jarvis-Live's Gemini client, which measured ~2 s → ~0.6 s). Later phrases end at
/// sentence boundaries, which keeps the prosody natural.
public enum SpeechSegmenter {
    /// The first phrase is cut at a clause mark once it has at least this many words.
    static let firstClauseMinimumWords = 1
    /// A first sentence longer than this (in words) without a clause mark is cut after `firstPhraseWords` words.
    static let longFirstSentenceWords = 14
    static let firstPhraseWords = 7
    /// Later phrases longer than this many characters are cut at a clause mark (very long sentences).
    static let maximumPhraseCharacters = 260

    public static func segments(_ text: String) -> [String] {
        var segmenter = Incremental()
        var result = segmenter.append(text)
        result += segmenter.finish()
        return result
    }

    /// Feeds a growing text (a reply being generated) and hands back the phrases that are complete.
    public struct Incremental: Sendable {
        private var buffer = ""
        private var emittedAny = false
        /// Everything handed out so far, joined (to compare with the final reply).
        public private(set) var spoken = ""

        public init() {}

        /// Appends `delta` and returns the phrases completed by it.
        public mutating func append(_ delta: String) -> [String] {
            buffer += delta
            var out: [String] = []
            while let cut = nextCut(final: false) {
                emit(cut, into: &out)
            }
            return out
        }

        /// The rest of the text, as the last phrase(s).
        public mutating func finish() -> [String] {
            var out: [String] = []
            while let cut = nextCut(final: true) { emit(cut, into: &out) }
            let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            if !rest.isEmpty { out.append(rest); spoken += (spoken.isEmpty ? "" : " ") + rest; emittedAny = true }
            return out
        }

        private mutating func emit(_ cut: String.Index, into out: inout [String]) {
            let phrase = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            guard !phrase.isEmpty else { return }
            out.append(phrase)
            spoken += (spoken.isEmpty ? "" : " ") + phrase
            emittedAny = true
        }

        /// Where the next complete phrase ends (just after its punctuation and the following space), or nil.
        private func nextCut(final: Bool) -> String.Index? {
            let characters = buffer
            var words = 0
            var inWord = false
            var clauseCut: String.Index?
            var index = characters.startIndex
            while index < characters.endIndex {
                let character = characters[index]
                let next = characters.index(after: index)
                if character.isLetter || character.isNumber {
                    if !inWord { words += 1; inWord = true }
                } else {
                    inWord = false
                }
                // A boundary needs what follows: whitespace (or the end of a finished text), so "3.5" and "e.g." in
                // the middle of a token are not cut.
                let followedBySpace = next < characters.endIndex ? characters[next].isWhitespace : final
                if followedBySpace || character == "\n" {
                    if ".!?…".contains(character) || character == "\n" {
                        if words > 0 { return next }
                    } else if ",;:—–".contains(character) || (character == "-" && index > characters.startIndex && characters[characters.index(before: index)] == " ") {
                        if !emittedAny, words >= SpeechSegmenter.firstClauseMinimumWords { return next }
                        if clauseCut == nil, characters.distance(from: characters.startIndex, to: index) > SpeechSegmenter.maximumPhraseCharacters / 2 { clauseCut = next }
                    }
                }
                // A long first sentence with no clause mark: cut after a few words, at a space.
                if !emittedAny, words > SpeechSegmenter.longFirstSentenceWords, let space = characters[..<index].lastIndex(where: { $0 == " " }) {
                    return firstWordsCut(in: characters, upTo: space) ?? characters.index(after: space)
                }
                if emittedAny, characters.distance(from: characters.startIndex, to: index) > SpeechSegmenter.maximumPhraseCharacters, let clauseCut {
                    return clauseCut
                }
                index = next
            }
            return nil
        }

        /// The position just after the `firstPhraseWords`-th word.
        private func firstWordsCut(in text: String, upTo limit: String.Index) -> String.Index? {
            var words = 0
            var inWord = false
            var index = text.startIndex
            while index < limit {
                let character = text[index]
                if character.isLetter || character.isNumber {
                    if !inWord { words += 1; inWord = true }
                } else {
                    if inWord, words >= SpeechSegmenter.firstPhraseWords, character == " " { return text.index(after: index) }
                    inWord = false
                }
                index = text.index(after: index)
            }
            return nil
        }
    }
}
