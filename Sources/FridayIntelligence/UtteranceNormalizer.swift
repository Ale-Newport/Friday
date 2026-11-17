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

    /// Mis-hearings of the original wake word and greeting+name forms; always residue, never a word of the request.
    public static let wakeWordSpellings = ["jarvis", "jarviss", "yarvis", "jarbis", "yarbis", "llarvis", "charvis", "harvis", "jervis", "jarbas", "jarvi", "javis", "yavis", "hey jarvis", "oye jarvis", "ok jarvis", "hola jarvis", "hey friday", "oye friday", "ok friday"]
    /// Pure hesitation sounds: never words.
    static let fillers = ["um", "uh", "er", "erm", "hmm", "mmm", "eh", "pues", "bueno", "ehm"]
    /// Real words that are hesitations only when the speaker pauses on them ("este… abre Notas"), never otherwise
    /// ("copia esto", "cierra este documento").
    static let pausedFillers = ["este", "esto", "o sea", "a ver", "like", "you know"]
    /// Markers after which the user restates the request: keep only what follows the LAST marker.
    static let correctionMarkers = [
        "no wait", "no, wait", "wait no", "actually,", "actually no", "no actually", "scratch that", "forget that", "i mean", "no i meant", "no, i meant", "sorry,", "let me rephrase",
        "no espera", "no, espera", "espera no", "bueno no", "bueno, no", "mejor dicho", "perdón", "perdon", "quiero decir", "digo,", "o mejor", "mejor,", "no, mejor", "olvida eso", "olvídalo",
    ]
    /// After a bare wake word that is also a weekday ("Friday"), these start a date/time expression: the word is
    /// the weekday, not the wake word ("Friday at 9 remind me…", "Friday morning schedule…").
    static let weekdayContinuations: Set<String> = [
        "at", "morning", "afternoon", "evening", "night", "noon", "next", "this", "the", "last", "before", "after", "around", "by", "from", "until", "till", "through",
        "is", "was", "will", "would", "i", "i'm", "we", "and", "or", "a", "an", "por", "de", "del", "en", "el", "la", "las", "los", "que", "pasado", "proximo", "siguiente", "hasta", "desde", "sobre", "y", "o",
    ]

    public static func normalize(_ raw: String, wakeWord: String = "jarvis", variants: [String] = []) -> Result {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var strippedWakeWord = false
        let name = KeywordRouter.fold(wakeWord).trimmingCharacters(in: .whitespaces)
        var spellings = wakeWordSpellings + variants.map { KeywordRouter.fold($0).trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        if !name.isEmpty { spellings += ["hey \(name)", "oye \(name)", "ok \(name)", "okay \(name)", "hola \(name)"] }
        let lowered = KeywordRouter.fold(text)
        for spelling in spellings.sorted(by: { $0.count > $1.count }) {
            if lowered.hasPrefix(spelling + ",") || lowered.hasPrefix(spelling + " ") || lowered == spelling {
                text = String(text.dropFirst(spelling.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
                strippedWakeWord = true
                break
            }
        }
        // The bare configured name ("Friday, open Notes" / "Friday open Notes"), unless it reads as a weekday.
        if !strippedWakeWord, !name.isEmpty, let stripped = stripBareName(text, name: name) {
            text = stripped
            strippedWakeWord = true
        }
        // The command capture starts a little before the detector's end-of-keyword time, so the recogniser may hear
        // the tail of the wake word ("vis, what time is it"). A leading fragment of three or more letters that ends a
        // known spelling is not a word in either language; drop it.
        if !strippedWakeWord, let first = text.split(separator: " ", maxSplits: 1).first {
            let fragment = KeywordRouter.fold(String(first)).trimmingCharacters(in: CharacterSet(charactersIn: ",.?!¿¡"))
            let endings = wakeWordSpellings + [name]
            if fragment.count >= 3, fragment.count < max(name.count, 6), endings.contains(where: { $0.hasSuffix(fragment) && $0 != fragment }) {
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
        // Multi-word hesitations are only fillers when paused on ("o sea, …", "you know, …").
        for phrase in pausedFillers where phrase.contains(" ") {
            let pattern = "(?i)(?:^|(?<=\\s))" + NSRegularExpression.escapedPattern(for: phrase) + "\\s*(?:,|…|\\.\\.\\.)\\s*"
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Fillers: whole words only; real words only when the speaker paused on them.
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        words.removeAll { word in
            let cleaned = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.…"))
            let paused = word.hasSuffix(",") || word.hasSuffix("…") || word.hasSuffix("...")
            if fillers.contains(cleaned) && cleaned.count <= 5 { return true }
            return paused && pausedFillers.contains(cleaned)
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

    /// Strips a leading bare wake word. Returns nil when the name reads as a weekday ("Friday at 9…", "Friday 9am",
    /// "Friday morning…") or is not there at all.
    static func stripBareName(_ text: String, name: String) -> String? {
        let lowered = KeywordRouter.fold(text)
        if lowered == name { return "" }
        for mark in [",", ".", "…", ":", "!"] where lowered.hasPrefix(name + mark) {
            return String(text.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: ",.…:! ").union(.whitespaces))
        }
        guard lowered.hasPrefix(name + " ") else { return nil }
        let rest = String(text.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        guard let first = rest.split(separator: " ").first else { return "" }
        let next = KeywordRouter.fold(String(first)).trimmingCharacters(in: CharacterSet(charactersIn: ",.?!¿¡"))
        if next.first?.isNumber == true || weekdayContinuations.contains(next) { return nil }
        return rest
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
