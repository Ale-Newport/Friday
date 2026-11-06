import Foundation

/// The user's vocabulary (names, apps, the wake word), applied to a transcript: a word or run of words that sounds
/// like an entry and is spelt nearly like it is replaced by the entry, so "Xylora", "Corvix" or "Mark" come back as
/// "Zylora", "Quorvix" and "Marc" when those are in the list.
///
/// This is what contextual strings are for; the same words are also handed to the recogniser (`AnalysisContext`),
/// but Apple's `SpeechTranscriber` on macOS 26/27 was measured to leave its output unchanged by them, so the list
/// is applied here as well. Only spellings close to an entry are touched: a span must either sound the same (the
/// phonetic fold below, with most of its letters shared) or share four letters in five, and nothing shorter than
/// three letters is ever replaced.
public struct RecognitionVocabulary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let text: String
        let words: [String]
        let raw: String
        let soft: String
    }

    public let entries: [Entry]

    /// Spans whose phonetic fold is this close to an entry's, with at least `rawFloor` of the letters shared, are replaced.
    public static let softThreshold = 0.85
    public static let rawFloor = 0.6
    /// Spans with this many letters in five shared with an entry are replaced whatever they sound like.
    public static let rawThreshold = 0.8
    /// Entries and spans shorter than this (letters) are never matched.
    public static let minimumLetters = 3

    public init(_ vocabulary: [String]) {
        entries = vocabulary.compactMap { text in
            let words = Self.words(of: text)
            let raw = Self.raw(words.joined())
            guard raw.count >= Self.minimumLetters else { return nil }
            return Entry(text: text.trimmingCharacters(in: .whitespacesAndNewlines), words: words, raw: raw, soft: Self.soft(raw))
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// `transcript` with every span that matches an entry replaced by that entry (its own spelling and casing).
    public func apply(to transcript: String) -> String {
        guard !entries.isEmpty, !transcript.isEmpty else { return transcript }
        let tokens = Self.tokens(of: transcript)
        guard !tokens.isEmpty else { return transcript }
        struct Match { let start: Int; let length: Int; let entry: Entry; let score: Double }
        var matches: [Match] = []
        for entry in entries {
            let lengths = Set([max(1, entry.words.count - 1), entry.words.count, entry.words.count + 1])
            for length in lengths where length <= tokens.count {
                for start in 0...(tokens.count - length) {
                    let span = tokens[start..<(start + length)].map(\.word).joined()
                    let raw = Self.raw(span)
                    guard raw.count >= Self.minimumLetters else { continue }
                    if raw == entry.raw {
                        // Already the right word: only the spelling (casing, accents) may differ.
                        if tokens[start..<(start + length)].map(\.word).joined(separator: " ") != entry.text {
                            matches.append(Match(start: start, length: length, entry: entry, score: 1))
                        }
                        continue
                    }
                    let rawSimilarity = Self.similarity(raw, entry.raw)
                    let softSimilarity = Self.similarity(Self.soft(raw), entry.soft)
                    let accepted = rawSimilarity >= Self.rawThreshold
                        || (softSimilarity >= Self.softThreshold && rawSimilarity >= Self.rawFloor)
                    guard accepted else { continue }
                    matches.append(Match(start: start, length: length, entry: entry, score: max(rawSimilarity, softSimilarity)))
                }
            }
        }
        guard !matches.isEmpty else { return transcript }
        // Best matches first; a token belongs to one replacement.
        var taken = [Bool](repeating: false, count: tokens.count)
        var chosen: [Match] = []
        for match in matches.sorted(by: { $0.score == $1.score ? $0.length > $1.length : $0.score > $1.score }) {
            let range = match.start..<(match.start + match.length)
            guard !range.contains(where: { taken[$0] }) else { continue }
            for index in range { taken[index] = true }
            chosen.append(match)
        }
        var result = transcript
        for match in chosen.sorted(by: { $0.start > $1.start }) {
            let first = tokens[match.start].range
            let last = tokens[match.start + match.length - 1].range
            result.replaceSubrange(first.lowerBound..<last.upperBound, with: match.entry.text)
        }
        return result
    }

    // MARK: Folding

    struct Token { let word: String; let range: Range<String.Index> }

    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            tokens.append(Token(word: String(text[range]), range: range))
        }
        return tokens
    }

    static func words(of text: String) -> [String] {
        tokens(of: text).map(\.word)
    }

    /// Lowercase letters and digits only, accents stripped: what two spellings are compared on.
    static func raw(_ text: String) -> String {
        String(text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A rough phonetic fold of `raw` text, the same for spellings that sound alike in English or Spanish:
    /// qu/ck/c→k, x→ks (a leading x→s), z/soft c→s, y→i, w→v, v→b, th→t, ph→f, silent h dropped, doubles collapsed.
    static func soft(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("x") { text = "s" + text.dropFirst() }
        for (pattern, replacement) in [("ph", "f"), ("th", "t"), ("qu", "k"), ("ck", "k"), ("x", "ks"), ("w", "v")] {
            text = text.replacingOccurrences(of: pattern, with: replacement)
        }
        var folded: [Character] = []
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            var out = character
            switch character {
            case "c":
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                out = "eiy".contains(next) ? "s" : "k"
            case "z": out = "s"
            case "y": out = "i"
            case "v": out = "b"
            case "h": continue
            default: break
            }
            if folded.last != out { folded.append(out) }
        }
        return String(folded)
    }

    /// 1 − edit distance / longer length; 1 for equal strings, 0 for nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = min(current[j], previous[j - 1])   // transposition costs no more than a substitution
                }
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
