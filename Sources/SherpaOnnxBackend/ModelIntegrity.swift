import CryptoKit
import Foundation
import WakeWordKit

/// The SHA-256 (lowercase hex) each model file must have, by *role*: the encoder file cannot be accepted because it happens
/// to be some other file this version knows.
public struct ModelDigests: Sendable, Equatable {
    public var encoder: String
    public var decoder: String
    public var joiner: String
    public var tokens: String

    public init(encoder: String, decoder: String, joiner: String, tokens: String) {
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
    }
}

/// How much the engine trusts the model files it is pointed at.
///
/// The library reports a damaged or foreign model not with an error code but with a C++ exception that nothing
/// above it can catch — the whole app would abort, and abort again every time it launched. So the model files are
/// checked *before* the library sees them.
public enum ModelIntegrity: Sendable, Equatable {
    /// Every model file must be exactly the one this version ships.
    case verified(ModelDigests)
    /// No check. Only for tools that evaluate other model variants, and for tests that never reach the library.
    case unverified
}

enum ModelVerifier {
    /// Hashing five megabytes is quick but not free, and availability is asked for from a SwiftUI body: remember the
    /// verdict for as long as the file is the same (name, size, modification time).
    private static let verdicts = Protected<[String: Bool]>([:])

    /// The files in `model` that are damaged, unexpected or unreadable (empty when all is well).
    static func damagedFiles(in model: SherpaOnnxWakeWordEngine.ModelFiles, expecting digests: ModelDigests) -> [String] {
        [(model.encoder, digests.encoder), (model.decoder, digests.decoder), (model.joiner, digests.joiner), (model.tokens, digests.tokens)]
            .filter { !matches($0.0, digest: $0.1) }
            .map { $0.0.lastPathComponent }
    }

    private static func matches(_ url: URL, digest expected: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(url.path)|\(attributes?[.size] ?? 0)|\(((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)|\(expected)"
        if let known = verdicts.withLock({ $0[identity] }) { return known }
        let verdict: Bool
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            verdict = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
        } else {
            verdict = false
        }
        verdicts.withLock { $0[identity] = verdict }
        return verdict
    }
}

/// What a hand-edited pronunciation list may contain. The library builds a keyword's automaton in time quadratic in its
/// length and destroys it recursively, so an absurd file would stall the audio path (it is built under the pipeline's lock) or
/// overflow a thread's stack — measured: 20 000 sounds in one line take about 0.4 s, 4 000 lines crash a Swift-concurrency thread.
public enum PronunciationLimits {
    /// Pronunciations used at once.
    public static let pronunciations = 32
    /// Sounds in one pronunciation ("Jarvis" has six).
    public static let soundsPerPronunciation = 48
    /// Size of the pronunciation file that is read at all.
    public static let fileBytes = 64 * 1024
}

/// The sounds (or word pieces) a model knows, read from its `tokens.txt`. A keyword that uses anything else makes the
/// library log an error and exit the process, so keywords are checked against this first.
struct TokenTable: Sendable {
    /// Tokens as **bytes**, because the library compares bytes. Swift's own `String` equality treats canonically equivalent
    /// spellings as one string — "à" typed as a single character or as "a" plus a combining accent, the Kelvin sign for "K" —
    /// so a check done with `String`s lets a spelling through that the library does not recognise, and the library answers by
    /// exiting the process (at every launch, for as long as the file stays).
    let tokens: Set<[UInt8]>

    init(contentsOf url: URL) throws(WakeWordError) {
        guard let data = try? Data(contentsOf: url) else {
            throw .engineUnavailable("the model's token table (\(url.lastPathComponent)) cannot be read")
        }
        // One "TOKEN ID" pair per line. Tokens that contain the keyword syntax's own characters (or any whitespace or control
        // character) can never be written inside a keyword definition, so they are not offered.
        var found = Set<[UInt8]>()
        for var line in data.split(separator: 0x0A) {
            if line.last == 0x0D { line = line.dropLast() }
            let token = Array(line.prefix { $0 != 0x20 && $0 != 0x09 })
            if token.isEmpty || token.contains(where: { $0 <= 0x20 || $0 == 0x7F || Self.syntax.contains($0) }) { continue }
            found.insert(token)
        }
        tokens = found
        if tokens.isEmpty { throw .engineUnavailable("the model's token table (\(url.lastPathComponent)) is empty") }
    }

    /// The bytes of `/ @ : #`, the characters the library's keyword syntax gives a meaning to.
    private static let syntax: Set<UInt8> = [0x2F, 0x40, 0x3A, 0x23]

    /// The sounds of a pronunciation: what stands between ASCII spaces (the only separator that is checked, so anything else
    /// — a tab, a line break, a no-break space — stays inside a sound, which then is not one the model has).
    private func sounds(of pronunciation: String) -> [[UInt8]] {
        pronunciation.utf8.split(separator: 0x20, omittingEmptySubsequences: true).map { Array($0) }
    }

    /// The tokens of `pronunciation` the model does not have.
    func unknownTokens(in pronunciation: String) -> [String] {
        let pieces = sounds(of: pronunciation)
        return pieces.isEmpty ? ["(nothing)"] : pieces.filter { !tokens.contains($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Refuses a list the library must never see: empty, longer than ``PronunciationLimits``, or using a sound the model does
    /// not have.
    func validate(_ pronunciations: [String]) throws(WakeWordError) {
        guard !pronunciations.isEmpty else { throw .invalidConfiguration("no pronunciation of the keyword configured") }
        guard pronunciations.count <= PronunciationLimits.pronunciations else {
            throw .invalidConfiguration("\(pronunciations.count) pronunciations of the keyword; at most \(PronunciationLimits.pronunciations) are used")
        }
        for pronunciation in pronunciations {
            let count = sounds(of: pronunciation).count
            guard count <= PronunciationLimits.soundsPerPronunciation else {
                throw .invalidConfiguration("the pronunciation “\(Self.excerpt(pronunciation))” has \(count) sounds; at most \(PronunciationLimits.soundsPerPronunciation) are used")
            }
            let unknown = unknownTokens(in: pronunciation)
            if !unknown.isEmpty {
                throw .invalidConfiguration("the pronunciation “\(Self.excerpt(pronunciation))” uses sounds the model does not have: \(unknown.prefix(5).joined(separator: ", "))")
            }
        }
    }

    /// A pronunciation shortened for an error message (a hand-edited file may hold anything).
    private static func excerpt(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(60)) + "…"
    }
}
