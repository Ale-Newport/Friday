import Foundation
import WakeWordKit

/// How the 0…1 sensitivity becomes sherpa-onnx's two per-keyword knobs. Both are applied to the keyword itself, so
/// changing them never reloads the model:
///
/// * **boost** — a bonus added to the keyword's score while it is being decoded. More boost makes a partly matching
///   sound (a mispronunciation, an accent) survive long enough to be judged — and also lets look-alike words through.
/// * **threshold** — the probability the decoded keyword must reach before it is reported. Lower fires more easily.
///   It spans an order of magnitude, so it is interpolated geometrically: equal steps of the slider are equal
///   *ratios* of the threshold.
public struct KeywordTuning: Sendable, Equatable {
    public var boostAtZero: Float
    public var boostAtOne: Float
    public var thresholdAtZero: Float
    public var thresholdAtOne: Float

    public init(boostAtZero: Float, boostAtOne: Float, thresholdAtZero: Float, thresholdAtOne: Float) {
        self.boostAtZero = boostAtZero
        self.boostAtOne = boostAtOne
        self.thresholdAtZero = thresholdAtZero
        self.thresholdAtOne = thresholdAtOne
    }

    /// Calibrated with `jarvis-bench kws-eval` (docs/TESTING_AND_ACCURACY.md §2) together with ``SherpaOnnxBackend/defaultMaxActivePaths``
    /// and the ``LevelNormaliser``, on speech at the level a MacBook's microphone hears at arm's length (peak −22 dBFS, room −65 dBFS):
    /// the boost does the work. From 1.0 (strict: 86 % of English voices heard, 9 of 338 look-alike words accepted) through 1.5 (the
    /// middle: 95 %, 17) to 2.0 (99 %, 26), with no false activation in 30 minutes of ordinary English or Spanish speech anywhere in
    /// that range. The threshold hardly matters at these boosts (anything from 0.03 to 0.1 gave the same result), so it is held at 0.06.
    public static let `default` = KeywordTuning(boostAtZero: 1.0, boostAtOne: 2.0, thresholdAtZero: 0.06, thresholdAtOne: 0.06)

    public func values(forSensitivity sensitivity: Float) -> (boost: Float, threshold: Float) {
        let t = min(1, max(0, sensitivity.isFinite ? sensitivity : 0.5))
        let boost = boostAtZero + (boostAtOne - boostAtZero) * t
        // Geometric between two positive thresholds; a zero or negative one has no ratio, so fall back to a straight line.
        guard thresholdAtZero > 0, thresholdAtOne > 0 else { return (boost, thresholdAtZero + (thresholdAtOne - thresholdAtZero) * t) }
        return (boost, thresholdAtZero * powf(thresholdAtOne / thresholdAtZero, t))
    }
}

/// A set of model files and the way "Jarvis" is spelled in that model's alphabet.
public struct SherpaModelProfile: Sendable, Equatable {
    /// Folder below the engine's search directories.
    public let directory: String
    public let encoder: String
    public let decoder: String
    public let joiner: String
    public let tokens: String
    /// Token sequences that mean "Jarvis" in this model's alphabet.
    public let pronunciations: [String]
    /// SHA-256 of each file (see ``ModelIntegrity``); nil for variants that are only being evaluated.
    public let digests: ModelDigests?

    public init(
        directory: String, encoder: String, decoder: String, joiner: String, tokens: String,
        pronunciations: [String], digests: ModelDigests? = nil
    ) {
        self.directory = directory
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
        self.pronunciations = pronunciations
        self.digests = digests
    }
}

/// Registration point for the sherpa-onnx engine: how it is described to the UI, which files it needs, and how to
/// build it. The composition root adds ``SherpaOnnxBackend/descriptor`` to the registry; nothing else in the
/// application references this module.
public enum SherpaOnnxBackend {
    public static let engineID = SherpaOnnxWakeWordEngine.engineID

    /// What the model reports when it hears the keyword (also the label in the keyword definition).
    static let label = "JARVIS"

    /// How many alternative readings of the audio the decoder keeps alive at once. It is the strongest accuracy knob the library has
    /// besides the boost, and the one that matters for accents and for "hey Jarvis" said in one breath, where the keyword's sounds are
    /// only one of many readings: at the same boost (1.5) and with speech at the level of a MacBook's microphone, keeping 8 hears
    /// 90 % of the English voices (83 % of phrases with a word in front of "Jarvis"), keeping 12 hears 95 % (91 %), with no false
    /// activation in 30 minutes of English or Spanish speech either way. More (16) starts to fire on ordinary speech
    /// (docs/TESTING_AND_ACCURACY.md §2). It is fixed when the model is loaded, which is why sensitivity moves only the boost.
    public static let defaultMaxActivePaths = 12

    enum FileName {
        static let library = "libsherpa-onnx-c-api.dylib"
        /// One pronunciation per line, in the model's own alphabet. Overrides the built-in ones, so an accent the
        /// defaults miss can be taught without touching code.
        static let customPronunciations = "jarvis_pronunciations.txt"
    }

    /// The English phone-based model released in December 2025, in its 320 ms-chunk form with a quantised (int8)
    /// encoder — about 5 MB of weights, and as accurate as the full-precision files in the tests (see
    /// docs/TESTING_AND_ACCURACY.md). Phones generalise across accents better than the word pieces of the older
    /// English model.
    public static let phoneModel = SherpaModelProfile(
        directory: "sherpa-kws",
        encoder: "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
        decoder: "decoder-epoch-13-avg-2-chunk-16-left-64.onnx",
        joiner: "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
        tokens: "tokens.txt",
        pronunciations: [
            "JH AA1 R V AH0 S",   // JARVIS, as a dictionary has it
            "JH AA1 R V IH0 S",   // the very common "-vis" ending
            "JH AA1 V IH0 S",     // without the r, as in much British English
            "JH AA1 R B IH0 S",   // "b" for "v", as a Spanish speaker may say it
        ],
        digests: ModelDigests(
            encoder: "408bbd740838c42d5bf6d1c5b80b3c88b616c7860b92d980328b5b068c76ae48",
            decoder: "63a22dd60f40fff082ac3e09afa507f6787da36df76ded2fbe145fa233e22c21",
            joiner: "190d4067b4cc20b72a42a1916e69d92052000fb7051a427ebb1bc72a69207dc1",
            tokens: "2d3f32311f9b692b964da3c90e830258d3e78e013cb0c992dbfb15cd5a1a71b0"
        )
    )

    public static var descriptor: EngineDescriptor { makeDescriptor(voiceTrainer: nil) }

    /// The same engine, able to learn a person's voice: the profile is kept in `profileDirectory` (the user's models folder, where the
    /// engine looks for it) and the reference speech the learning checks against is made in `referenceSpeechCache`.
    public static func descriptor(profileDirectory: URL, referenceSpeechCache: URL) -> EngineDescriptor {
        makeDescriptor(voiceTrainer: voiceTrainer(profileDirectory: profileDirectory, referenceSpeechCache: referenceSpeechCache))
    }

    /// The pronunciations in the person's own file in `directory` (a profile a lesson wrote, or a list written by hand), if there is one
    /// that can be used: what a new lesson has to do better than.
    public static func customPronunciations(in directory: URL) -> [String]? {
        let file = directory.appendingPathComponent(FileName.customPronunciations)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? parsePronunciations(from: file)
    }

    /// How this engine learns how a person says "Jarvis" (see ``VoiceTuner``) and keeps what it learned.
    public static func voiceTrainer(profileDirectory: URL, referenceSpeechCache: URL, workers: Int? = nil) -> VoiceTrainer {
        let profileFile = profileDirectory.appendingPathComponent(FileName.customPronunciations)
        return VoiceTrainer(
            learn: { recordings, environment, progress in
                guard let files = locateFiles(in: environment) else {
                    throw VoiceTrainingError.unavailable("The engine’s files are missing, so Jarvis can’t learn yet. Run Scripts/fetch-sherpa.sh and rebuild.")
                }
                var options = VoiceTuner.Options()
                options.sensitivity = environment.sensitivity
                options.referenceCache = referenceSpeechCache
                // What a lesson has to beat is what the engine runs on now: the person's profile if there is one, not only the built-in list.
                if case .success(let inForce) = files.pronunciations { options.baseline = inForce }
                if let workers { options.workers = max(1, workers) }
                let outcome = try await VoiceTuner(library: files.library, model: files.model, options: options).tune(
                    utterances: recordings.utterances.map { .init(samples: $0.samples, source: $0.source) },
                    ordinaryTalk: recordings.ordinaryTalk, progress: progress
                )
                return outcome.report
            },
            install: { report in
                guard report.isImprovement, let text = String(data: report.payload, encoding: .utf8), !text.isEmpty else {
                    throw VoiceTrainingError.failed("There is nothing worth keeping from that lesson.")
                }
                return VoiceProfileChange(keptPrevious: try VoiceProfileFile.write(text, replacing: profileFile))
            },
            revert: { change in try VoiceProfileFile.revert(profileFile, restoring: change.keptPrevious) },
            currentProfile: { VoiceProfileFile.describe(profileFile) },
            removeProfile: { try VoiceProfileFile.setAside(profileFile).map { VoiceProfileChange(keptPrevious: $0) } }
        )
    }

    private static func makeDescriptor(voiceTrainer: VoiceTrainer?) -> EngineDescriptor {
        EngineDescriptor(
            id: engineID,
            displayName: "Sherpa-ONNX (free)",
            summary: "Free, open-source keyword spotting for “Jarvis”, running entirely on this Mac. No account, key or "
                + "internet connection is needed, and audio never leaves the Mac.",
            credentials: [],
            capabilities: EngineCapabilities(supportsLiveSensitivity: true, reportsConfidence: false),
            preflight: { environment in
                guard let files = locateFiles(in: environment) else {
                    return .unavailable(reason: "Missing the sherpa-onnx library or its model files. Run Scripts/fetch-sherpa.sh and rebuild.")
                }
                if case .failure(let problem) = files.pronunciations {
                    return .unavailable(reason: (problem.errorDescription ?? "The pronunciation file cannot be used.") + " Fix or delete it, then switch listening off and on.")
                }
                let damaged = phoneModel.digests.map { ModelVerifier.damagedFiles(in: files.model, expecting: $0) } ?? []
                if !damaged.isEmpty {
                    return .unavailable(reason: "Damaged or unexpected model file(s): \(damaged.joined(separator: ", ")). Run Scripts/fetch-sherpa.sh and rebuild.")
                }
                // Loading (not just finding) the library catches a wrong architecture or a code-signing problem now,
                // with the system's own explanation, instead of at first use.
                if case .failure(let error) = inspectLibrary(at: files.library) {
                    return .unavailable(reason: error.errorDescription ?? "The engine library could not be loaded.")
                }
                return .ready
            },
            voiceTrainer: voiceTrainer,
            makeEngine: { environment throws(WakeWordError) in
                guard environment.keywords == [.jarvis] else {
                    throw .invalidConfiguration("the sherpa-onnx backend listens for \"Jarvis\" only")
                }
                guard let files = locateFiles(in: environment) else {
                    throw .engineUnavailable("the sherpa-onnx library or model files are missing; run Scripts/fetch-sherpa.sh")
                }
                return SherpaOnnxWakeWordEngine(configuration: .init(
                    libraryURL: files.library,
                    model: files.model,
                    pronunciations: try files.pronunciations.get(),
                    sensitivity: environment.sensitivity,
                    integrity: phoneModel.digests.map { .verified($0) } ?? .unverified
                ))
            }
        )
    }

    /// Facts reported by the native library itself.
    public struct LibraryInfo: Equatable, Sendable {
        public let version: String
    }

    /// Loads the library at `url` and reads its version. Never builds a spotter.
    public static func inspectLibrary(at url: URL) -> Result<LibraryInfo, WakeWordError> {
        do {
            return .success(LibraryInfo(version: try LibraryBindings.load(from: url).version))
        } catch {
            return .failure(error)
        }
    }

    struct Files {
        var library: URL
        var model: SherpaOnnxWakeWordEngine.ModelFiles
        /// What to listen for: the built-in pronunciations, or the user's `jarvis_pronunciations.txt` — or the reason that
        /// file cannot be used (it is never silently ignored: someone who wrote it expects it to count).
        var pronunciations: Result<[String], WakeWordError>
    }

    static func locateFiles(in environment: EngineEnvironment, profile: SherpaModelProfile = phoneModel) -> Files? {
        let resources = environment.resources
        func data(_ name: String) -> URL? { resources.locate("\(profile.directory)/\(name)") }
        guard
            // Native code: only from the library directories (the app bundle), never from the user-writable models folder.
            let library = resources.locateLibrary(FileName.library),
            let encoder = data(profile.encoder), let decoder = data(profile.decoder),
            let joiner = data(profile.joiner), let tokens = data(profile.tokens)
        else { return nil }
        var pronunciations: Result<[String], WakeWordError> = .success(profile.pronunciations)
        if let custom = resources.locate(FileName.customPronunciations) {
            do throws(WakeWordError) {
                if let lines = try parsePronunciations(from: custom) { pronunciations = .success(lines) }
            } catch {
                pronunciations = .failure(error)
            }
        }
        return Files(library: library, model: .init(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens), pronunciations: pronunciations)
    }

    /// Reads a user's pronunciation file: one sequence of sounds per line, `#` starts a comment, blanks and tabs between sounds
    /// are single spaces. Returns nil when the file holds no line at all (comments only), so the built-in list stays in force;
    /// throws when it cannot be used. What the lines *say* — sounds the model lacks, too many of them — is checked later, against
    /// the model's own token table, so that nothing is quietly dropped.
    static func parsePronunciations(from url: URL) throws(WakeWordError) -> [String]? {
        let name = url.lastPathComponent
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: PronunciationLimits.fileBytes + 1) ?? Data()
        } catch {
            throw .invalidConfiguration("\(name) cannot be read (\(error.localizedDescription)).")
        }
        guard data.count <= PronunciationLimits.fileBytes else {
            throw .invalidConfiguration("\(name) is larger than \(PronunciationLimits.fileBytes / 1_024) KB; it should hold a few short lines.")
        }
        // (Decoding as UTF-8 also drops the byte-order mark some editors put at the start of a file.)
        guard let text = String(data: data, encoding: .utf8) else {
            throw .invalidConfiguration("\(name) is not UTF-8 text.")
        }
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let sounds = uncommented.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return sounds.isEmpty ? nil : sounds.joined(separator: " ")
        }
        return lines.isEmpty ? nil : lines
    }

    /// The keyword definition handed to the library: one entry per pronunciation, all reporting the same label.
    static func keywordDefinition(pronunciations: [String], sensitivity: Float, tuning: KeywordTuning) -> String {
        let (boost, threshold) = tuning.values(forSensitivity: sensitivity)
        return pronunciations
            .map { "\($0) :\(format(boost)) #\(format(threshold)) @\(label)" }
            .joined(separator: "/")
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.3f", Double(value))
    }
}
