import Foundation
import FridayCore

/// Cleans up transcribed speech before the deterministic fast path sees it: removes wake-word residue, fillers and
/// hesitations, and applies the simplest self-corrections ("open … no wait, open Notes" → "open Notes").
/// The language model always receives the ORIGINAL text as well, so nothing is lost when a heuristic is wrong.
public enum UtteranceNormalizer {
    public struct Result: Sendable, Hashable {
        public var text: String
        public var corrected: Bool
        public var strippedWakeWord: Bool
    }

    public static let wakeWordSpellings = ["jarvis", "yarvis", "jarbis", "yarbis", "charvis", "harvis", "jarvi", "javis", "yavis", "hey jarvis", "oye jarvis", "ok jarvis", "hey friday", "friday", "oye friday"]
    static let fillers = ["um", "uh", "er", "erm", "hmm", "mmm", "eh", "este", "esto", "pues", "o sea", "bueno", "a ver", "like,", "you know,", "ehm"]
    /// Markers after which the user restates the request: keep only what follows the LAST marker.
    static let correctionMarkers = [
        "no wait", "no, wait", "wait no", "actually,", "actually no", "no actually", "scratch that", "forget that", "i mean", "no i meant", "no, i meant", "sorry,", "let me rephrase",
        "no espera", "no, espera", "espera no", "bueno no", "bueno, no", "mejor dicho", "perdón", "perdon", "quiero decir", "digo,", "o mejor", "mejor,", "no, mejor", "olvida eso", "olvídalo",
    ]

    public static func normalize(_ raw: String, wakeWord: String = "jarvis") -> Result {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var strippedWakeWord = false
        let lowered = text.lowercased()
        for spelling in wakeWordSpellings.sorted(by: { $0.count > $1.count }) {
            if lowered.hasPrefix(spelling + ",") || lowered.hasPrefix(spelling + " ") || lowered == spelling {
                text = String(text.dropFirst(spelling.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
                strippedWakeWord = true
                break
            }
        }
        if !wakeWord.isEmpty, text.lowercased().hasPrefix(wakeWord.lowercased() + " ") {
            text = String(text.dropFirst(wakeWord.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
            strippedWakeWord = true
        }
        // The command capture starts a little before the detector's end-of-keyword time, so the recogniser may hear
        // the tail of the wake word ("vis, what time is it"). A leading fragment of three or more letters that ends a
        // known spelling is not a word in either language; drop it.
        if !strippedWakeWord, let first = text.split(separator: " ", maxSplits: 1).first {
            let fragment = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.?!¿¡"))
            let endings = wakeWordSpellings + [wakeWord.lowercased()]
            if fragment.count >= 3, fragment.count < wakeWord.count, endings.contains(where: { $0.hasSuffix(fragment) && $0 != fragment }), !["bis", "vis", "avis", "rvis"].isEmpty {
                let rest = text.dropFirst(first.count).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
                if !rest.isEmpty { text = rest; strippedWakeWord = true }
            }
        }
        // Self-correction first (markers such as "bueno no" contain filler words): keep the text after the LAST marker.
        var corrected = false
        let folded = text.lowercased()
        var best: Range<String.Index>?
        for marker in correctionMarkers {
            if let range = folded.range(of: marker, options: .backwards) {
                if best == nil || range.lowerBound > best!.lowerBound { best = range }
            }
        }
        if let best {
            let after = text[best.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
            if after.split(separator: " ").count >= 2 {
                text = after
                corrected = true
            }
        }
        // Fillers: whole words only.
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        words.removeAll { word in
            let cleaned = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.…"))
            return fillers.contains(cleaned) && cleaned.count <= 5
        }
        text = words.joined(separator: " ")
        // Collapse repeated words ("open open Notes").
        var deduplicated: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if let last = deduplicated.last, last.lowercased() == word.lowercased(), word.count > 2 { continue }
            deduplicated.append(word)
        }
        text = deduplicated.joined(separator: " ")
        return Result(text: text, corrected: corrected, strippedWakeWord: strippedWakeWord)
    }

    /// True for short, single-clause commands that the deterministic parser handles well.
    public static func isSimpleCommand(_ text: String) -> Bool {
        let folded = KeywordRouter.fold(text)
        if folded.count > 80 { return false }
        if KeywordRouter.looksMultistep(folded) { return false }
        let hedges = ["something like", "algo como", "the one", "la que", "el que", "that i", "que tengo", "yesterday", "ayer", "last week", "la semana pasada", "whatever", "lo que sea"]
        return !hedges.contains { folded.contains($0) }
    }
}
