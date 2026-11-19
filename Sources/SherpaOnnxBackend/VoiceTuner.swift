import Foundation
import WakeWordKit

/// Learns how a particular person says "Jarvis".
///
/// "Jarvis" is data for this engine: a list of phoneme sequences. Which sequences match *you* depends on how you say it — and on what
/// the network makes of it: a Spanish accent, a fast "hey Jarvis" or a quiet voice can come out as `JH AA1 B V IY0 AH0 S`, or as
/// Mandarin syllables, because the network is bilingual. So this does not guess. It
///
///  1. asks the network what it hears in each of the person's utterances (``SherpaSoundRecognizer``),
///  2. turns what is heard often into candidate pronunciations — together with a family of plausible textbook variations — and keeps those
///     that hear the utterances **and** stay silent on look-alike words, on ordinary English and Spanish speech made with the Mac's voices,
///     and on the person's own ordinary talk,
///  3. fits on two thirds of the utterances and checks on the third it did not see, then refits on all of them,
///  4. and says whether what it found is worth installing.
///
/// It only reads the recordings it is given. It changes nothing the engine uses: ``SherpaOnnxBackend/voiceTrainer(profileDirectory:referenceSpeechCache:)``
/// installs the result.
public struct VoiceTuner: Sendable {
    public struct Options: Sendable {
        /// The sensitivity the engine runs at (what the fit keeps depends on it).
        public var sensitivity: Float = 0.5
        /// Engines working at once. Each holds the model (about 45 MB) and a core.
        public var workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        /// The most pronunciations in a profile.
        public var maximumPronunciations = 8
        /// Where the reference speech (look-alike words and ordinary speech made with the Mac's voices) is made and kept. Nil: none is
        /// used, and only the person's own ordinary talk is checked against.
        public var referenceCache: URL?
        /// The pronunciations the engine runs on now, which a new profile has to beat: the person's own profile if there is one. Nil: the
        /// built-in ones.
        public var baseline: [String]?
        /// Keep utterances in which the network hears hardly anything (for demonstrations on synthetic voices).
        public var keepsUnheardUtterances = false
        /// Look-alike words and ordinary speech to check against, instead of making them with the Mac's voices (tests).
        var injectedReference: (words: [[Float]], speech: [[Float]])?
        /// Try the ~1 150 textbook variations as well as what the network is heard to say (tests turn this off to run in a moment).
        var usesTextbookVariations = true
        /// Try no more than this many candidates (the first in alphabetical order): for a smoke test on the real network.
        var candidateLimit: Int?
        /// Noisy copies made of each recording (people talking, music, fan noise — see ``NoiseAugmentation``), which the
        /// pronunciations must hear too. 0 learns from the clean recordings only.
        public var noisyCopies = 1
        public init() {}
    }

    public struct Utterance: Sendable {
        public var samples: [Float]
        public var source: String
        public init(samples: [Float], source: String) {
            self.samples = samples
            self.source = source
        }
    }

    public struct SourceLine: Sendable, Equatable {
        public var source: String
        public var count: Int
        public var before: Int
        public var after: Int
    }

    public struct Outcome: Sendable {
        public var report: VoiceTrainingReport
        /// The pronunciations found, and the text of the profile file that holds them.
        public var pronunciations: [String]
        public var profileText: String
        /// Per source: how many utterances, and how many the list in force now (the built-in one unless the person has their own) and the fitted list hear.
        public var bySource: [SourceLine]
        /// Nil when the result may be installed; otherwise why not.
        public var refusal: String?
    }

    let library: URL
    let model: SherpaOnnxWakeWordEngine.ModelFiles
    let options: Options
    /// Test seams: how an engine and a recogniser are made (the real ones by default).
    var makeEngine: @Sendable (SherpaOnnxWakeWordEngine.Configuration) -> SherpaOnnxWakeWordEngine = { SherpaOnnxWakeWordEngine(configuration: $0) }
    var makeRecognizer: @Sendable (SherpaSoundRecognizer.Configuration) -> SherpaSoundRecognizer = { SherpaSoundRecognizer(configuration: $0) }

    public init(library: URL, model: SherpaOnnxWakeWordEngine.ModelFiles, options: Options = Options()) {
        self.library = library
        self.model = model
        self.options = options
    }

    /// Analyses `utterances` and `ordinaryTalk` (16 kHz mono) and says what it found. Takes minutes. `log` receives the narrative a
    /// command-line tool prints; `progress` drives a progress bar. Stops, throwing ``VoiceTrainingError/cancelled``, when the task is
    /// cancelled.
    public func tune(
        utterances: [Utterance], ordinaryTalk: [[Float]],
        heldOutGroups: [(name: String, clips: [[Float]])] = [],
        log: @escaping @Sendable (String) -> Void = { _ in },
        progress: @escaping @Sendable (VoiceTrainingProgress) -> Void = { _ in }
    ) async throws -> Outcome {
        let cancelled = Protected(false)
        var engines: [SherpaOnnxWakeWordEngine] = []
        func shutDown() { engines.forEach { $0.shutdown() } }
        do {
            progress(VoiceTrainingProgress(message: "Getting ready…", fraction: 0.01))
            for _ in 0..<max(1, options.workers) {
                try Task.checkCancellation()
                let engine = makeEngine(.init(
                    libraryURL: library, model: model, pronunciations: SherpaOnnxBackend.phoneModel.pronunciations,
                    sensitivity: options.sensitivity,
                    integrity: SherpaOnnxBackend.phoneModel.digests.map { .verified($0) } ?? .unverified
                ))
                do { try await engine.initialize() } catch {
                    throw VoiceTrainingError.unavailable(error.errorDescription ?? "The engine could not be loaded.")
                }
                engines.append(engine)
            }
            let run = TuningRun(
                library: library, model: model, options: options, engines: engines, utterances: utterances, ordinaryTalk: ordinaryTalk,
                heldOutGroups: heldOutGroups, makeRecognizer: makeRecognizer, log: log, progress: progress, isCancelled: { cancelled.get() }
            )
            let outcome: Outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue(label: "jarvis.voice-tuner", qos: .utility).async {
                        do { continuation.resume(returning: try run.perform()) } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            shutDown()
            return outcome
        } catch {
            shutDown()
            if error is CancellationError { throw VoiceTrainingError.cancelled }
            throw error
        }
    }
}

// MARK: - The work

/// Several engines at once: each worker has its own, because an engine is not re-entrant.
struct EnginePool {
    let engines: [SherpaOnnxWakeWordEngine]

    /// Runs `body(engine, item)` for every item, spreading the items over the engines; results come back in item order.
    func map<Item: Sendable, Result: Sendable>(_ items: [Item], _ body: @escaping @Sendable (SherpaOnnxWakeWordEngine, Item) -> Result) -> [Result] {
        guard !items.isEmpty else { return [] }
        let workers = min(engines.count, items.count)
        let results = Protected([Result?](repeating: nil, count: items.count))
        let engines = self.engines
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var index = worker
            while index < items.count {
                let value = body(engines[worker], items[index])
                results.withLock { $0[index] = value }
                index += workers
            }
        }
        return results.get().map { $0! }
    }

    /// Puts `pronunciations` in force in every engine; false if any refused them.
    func setAll(_ pronunciations: [String]) -> Bool {
        let accepted = Protected(true)
        let engines = self.engines
        DispatchQueue.concurrentPerform(iterations: engines.count) { index in
            if (try? engines[index].setPronunciations(pronunciations)) == nil { accepted.withLock { $0 = false } }
        }
        return accepted.get()
    }
}

/// One analysis. Everything here runs on a queue of its own, one step after another; the engines work in parallel inside a step.
final class TuningRun: @unchecked Sendable {
    typealias Outcome = VoiceTuner.Outcome

    private let library: URL
    private let model: SherpaOnnxWakeWordEngine.ModelFiles
    private let options: VoiceTuner.Options
    private let pool: EnginePool
    private let utterances: [VoiceTuner.Utterance]
    private let ordinaryTalk: [[Float]]
    private let heldOutGroups: [(name: String, clips: [[Float]])]
    private let makeRecognizer: @Sendable (SherpaSoundRecognizer.Configuration) -> SherpaSoundRecognizer
    private let log: @Sendable (String) -> Void
    private let progressSink: @Sendable (VoiceTrainingProgress) -> Void
    private let isCancelled: @Sendable () -> Bool
    private let shipped = SherpaOnnxBackend.phoneModel
    /// What the engine runs on now, which is what a new list has to beat (see ``VoiceTuner/Options/baseline``).
    private var baseline: [String] { options.baseline ?? shipped.pronunciations }
    private var baselineName: String { options.baseline == nil || options.baseline == shipped.pronunciations ? "built-in" : "current" }

    /// How far the progress bar has got. (The reference speech is made by several processes at once, each telling how far it is.)
    private let lastFraction = Protected(0.0)
    private var positives: [VoiceTuner.Utterance] = []
    private var heardBySegment: [[String]] = []
    private var shortNegatives: [[Float]] = [], longNegatives: [[Float]] = [], mine: [[Float]] = []
    private var wordAlarmCache: [String: Int] = [:], speechAlarmCache: [String: Int] = [:]
    private var sensitivity: Float { options.sensitivity }

    init(
        library: URL, model: SherpaOnnxWakeWordEngine.ModelFiles, options: VoiceTuner.Options, engines: [SherpaOnnxWakeWordEngine],
        utterances: [VoiceTuner.Utterance], ordinaryTalk: [[Float]], heldOutGroups: [(name: String, clips: [[Float]])],
        makeRecognizer: @escaping @Sendable (SherpaSoundRecognizer.Configuration) -> SherpaSoundRecognizer,
        log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (VoiceTrainingProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.library = library
        self.model = model
        self.options = options
        self.pool = EnginePool(engines: engines)
        self.utterances = utterances
        self.ordinaryTalk = ordinaryTalk
        self.heldOutGroups = heldOutGroups
        self.makeRecognizer = makeRecognizer
        self.log = log
        self.progressSink = progress
        self.isCancelled = isCancelled
    }

    private func report(_ message: String, _ fraction: Double) {
        let shown = lastFraction.withLock { value -> Double in
            value = max(value, fraction)
            return value
        }
        progressSink(VoiceTrainingProgress(message: message, fraction: shown))
    }

    private func checkCancelled() throws {
        if isCancelled() { throw VoiceTrainingError.cancelled }
    }

    // MARK: Measuring

    /// The audio exactly as the engine is tested with it: room before and after, a little noise, as a microphone would deliver.
    private func prepared(_ clip: [Float], seed: UInt64) -> [Float] {
        EvaluationAudio.roomNoise([Float](repeating: 0, count: 8_000) + clip + [Float](repeating: 0, count: 16_000), level: 0.003, seed: seed)
    }

    private func fires(_ engine: SherpaOnnxWakeWordEngine, _ clip: [Float], seed: UInt64, sensitivity: Float) -> Bool {
        ((try? EvaluationAudio.feed(clip, through: engine, sensitivity: sensitivity, noise: 0.003, seed: seed)) ?? []).isEmpty == false
    }

    /// Which of `clips` (by index) are heard with `pronunciations` in force.
    private func heard(_ pronunciations: [String], in clips: [[Float]]) throws -> Set<Int> {
        try checkCancelled()
        guard pool.setAll(pronunciations) else { return [] }
        let sensitivity = self.sensitivity
        let flags = pool.map(Array(clips.indices)) { [self] engine, index in
            fires(engine, clips[index], seed: EvaluationAudio.contentSeed(clips[index]), sensitivity: sensitivity)
        }
        return Set(clips.indices.filter { flags[$0] })
    }

    private func alarms(_ pronunciations: [String], in clips: [[Float]]) throws -> Int {
        try checkCancelled()
        guard pool.setAll(pronunciations) else { return 1_000_000 }   // a list the engine refuses is as bad as it gets (and sums stay far from overflow)
        let sensitivity = self.sensitivity
        return pool.map(Array(clips.indices)) { [self] engine, index in
            fires(engine, clips[index], seed: EvaluationAudio.contentSeed(clips[index]) &+ 1_000, sensitivity: sensitivity)
        }.filter { $0 }.count
    }

    private func wordAlarms(_ candidate: String) throws -> Int {
        if let known = wordAlarmCache[candidate] { return known }
        let value = try alarms([candidate], in: shortNegatives)
        wordAlarmCache[candidate] = value
        return value
    }

    /// Alarms on ordinary speech — English and Spanish from the system voices, and the person's own.
    private func speechAlarms(_ candidate: String) throws -> Int {
        if let known = speechAlarmCache[candidate] { return known }
        let value = try alarms([candidate], in: mine) + alarms([candidate], in: longNegatives)
        speechAlarmCache[candidate] = value
        return value
    }

    /// False alarms of a whole list, apart: a look-alike word that fires is a small price, ordinary speech that fires is not.
    private func alarmSummary(_ list: [String]) throws -> (words: Int, speech: Int, text: String) {
        let words = try alarms(list, in: shortNegatives)
        let speech = try alarms(list, in: longNegatives) + alarms(list, in: mine)
        return (words, speech, "\(words) of \(shortNegatives.count) look-alike words, \(speech) of \(longNegatives.count + mine.count) stretches of speech")
    }

    /// Each pronunciation was checked on its own; together they could still fire on ordinary speech. Drops from the end — the ones that
    /// add the least — until they do not.
    private func quietOnSpeech(_ list: [String]) throws -> [String] {
        var list = list
        while !list.isEmpty, try alarms(list, in: longNegatives) + alarms(list, in: mine) > 0 { list.removeLast() }
        return list
    }

    // MARK: Searching

    /// Finds a few pronunciations that hear `clips` and stay silent. `transcripts` are what the model hears in them. `fraction` reports
    /// how far the scan of the candidates has got (0…1).
    private func search(clips: [[Float]], transcripts: [[String]], verbose: Bool, fraction: @escaping (Double) -> Void) throws -> [String] {
        // Candidates: the textbook variations, plus the stretches of what the model hears that recur across utterances.
        var candidates = Set(options.usesTextbookVariations ? Self.candidatePronunciations() : [])
        var support: [String: Set<Int>] = [:]
        for (clip, tokens) in transcripts.enumerated() where tokens.count >= 4 {
            for length in 4...min(9, tokens.count) {
                for start in 0...(tokens.count - length) {
                    let span = tokens[start..<start + length]
                    if span.contains(where: { $0.hasPrefix("<") }) { continue }
                    support[span.joined(separator: " "), default: []].insert(clip)
                }
            }
        }
        // Ties are broken by the text itself: a dictionary's order changes from run to run, and with it, past 150 spans, the fit.
        let recurring = support.filter { $0.value.count >= 2 }.sorted { a, b in
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.key.count != b.key.count { return a.key.count > b.key.count }
            return a.key < b.key
        }.prefix(150).map(\.key)
        candidates.formUnion(recurring)
        candidates.formUnion(shipped.pronunciations)
        candidates.formUnion(baseline)
        let list = options.candidateLimit.map { Array(candidates.sorted().prefix($0)) } ?? candidates.sorted()
        if verbose { log("Trying \(list.count) candidate pronunciations (\(recurring.count) of them taken from what the model hears)…") }

        // Stage 1: a quick look at a spread of utterances prunes most candidates; the rest are scored on all of them.
        let probe = stride(from: 0, to: clips.count, by: max(1, clips.count / 10)).map { clips[$0] }
        var tried = 0
        var scored: [(String, Set<Int>)] = []
        for candidate in list {
            try checkCancelled()
            tried += 1
            if tried % 20 == 0 { fraction(Double(tried) / Double(list.count)) }
            if verbose, tried % 200 == 0 { log("  … \(tried) of \(list.count)") }
            guard pool.setAll([candidate]) else { continue }
            guard try !heard([candidate], in: probe).isEmpty else { continue }
            let h = try heard([candidate], in: clips)
            if !h.isEmpty { scored.append((candidate, h)) }
        }
        scored.sort { a, b in   // most utterances first, then the shorter, then alphabetical: the same order on every run
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            if a.0.count != b.0.count { return a.0.count < b.0.count }
            return a.0 < b.0
        }
        if verbose { log("  \(scored.count) of them hear at least one utterance; best single: \(scored.first.map { "\($0.0) (\($0.1.count)/\(clips.count))" } ?? "none")") }

        // Stage 2: the best ones must also stay silent — on look-alike words (a few allowed), and on speech (none).
        let allowedWords = max(1, shortNegatives.count / 100)
        var usable: [(String, Set<Int>, Int)] = []
        for (candidate, covered) in scored.prefix(70) {
            let words = try wordAlarms(candidate)
            guard words <= allowedWords else { continue }
            usable.append((candidate, covered, words))
            if usable.count == 24 { break }
        }
        var quiet: [(String, Set<Int>, Int)] = []
        for item in usable where try speechAlarms(item.0) == 0 { quiet.append(item) }
        usable = quiet
        if verbose { log("  \(usable.count) of the best stay quiet on the words and the speech that must not fire") }

        // Stage 3: the few that together hear the most.
        var chosen: [String] = []
        var covered = Set<Int>()
        var remaining = usable
        while chosen.count < options.maximumPronunciations, let best = remaining.max(by: { ($0.1.subtracting(covered).count, -$0.2) < ($1.1.subtracting(covered).count, -$1.2) }),
              !best.1.subtracting(covered).isEmpty {
            chosen.append(best.0)
            covered.formUnion(best.1)
            remaining.removeAll { $0.0 == best.0 }
        }
        return chosen
    }

    /// The family of pronunciations tried: the dictionary form and the variations a non-native or regional speaker might
    /// produce. Every sound is one the model has.
    static func candidatePronunciations() -> [String] {
        var result: [String] = []
        let onsets = ["JH", "HH", "Y", "CH", "ZH", "SH"]
        let vowels = ["AA1", "AA0", "AO1", "AH1"]
        let rs = ["R", ""]
        let middles = ["V", "B", "F"]
        let endings = ["IH0", "IY0", "AH0", "IH1"]
        let codas = ["S", "Z"]
        for onset in onsets { for vowel in vowels { for r in rs { for middle in middles { for ending in endings { for coda in codas {
            result.append([onset, vowel, r, middle, ending, coda].filter { !$0.isEmpty }.joined(separator: " "))
        } } } } } }
        result.append(contentsOf: ["JH ER1 V IH0 S", "JH ER1 B IH0 S", "HH ER1 V IH0 S", "JH AA1 R V IH0 S"])
        return Array(Set(result)).sorted()
    }

    // MARK: The analysis

    func perform() throws -> Outcome {
        // The reference speech first: it is the long wait the first time, and then it is kept.
        if let injected = options.injectedReference {
            shortNegatives = injected.words
            longNegatives = injected.speech
        } else if let cache = options.referenceCache {
            report("Making the reference voices (only the first time)…", 0.02)
            let negatives = try ReferenceSpeech.negatives(cache: cache, isCancelled: isCancelled) { [self] done, total in
                report("Making the reference voices (only the first time)…", 0.02 + 0.16 * Double(done) / Double(max(1, total)))
            }
            shortNegatives = negatives.words
            longNegatives = negatives.speech
        }
        mine = ordinaryTalk
        let minutes = (shortNegatives + longNegatives + mine).reduce(0.0) { $0 + Double($1.count) / 16_000 } / 60

        // What the network hears in each utterance.
        report("Listening to what the model hears in your phrases…", 0.19)
        let recognizer = makeRecognizer(.init(libraryURL: library, model: model))
        do { try recognizer.initialize() } catch {
            throw VoiceTrainingError.unavailable(error.errorDescription ?? "The model could not be loaded.")
        }
        defer { recognizer.shutdown() }
        var kept: [VoiceTuner.Utterance] = []
        for (index, take) in utterances.enumerated() {
            try checkCancelled()
            let sounds = recognizer.sounds(in: prepared(take.samples, seed: EvaluationAudio.contentSeed(take.samples)))
            if sounds.count >= 3 || options.keepsUnheardUtterances { kept.append(take); heardBySegment.append(sounds) }
            report("Listening to what the model hears in your phrases…", 0.19 + 0.04 * Double(index + 1) / Double(max(1, utterances.count)))
        }
        if kept.count < utterances.count { log("  (\(utterances.count - kept.count) stretches of sound were too short or too faint to be words, and were left out)") }
        positives = kept
        // Noisy copies: the same words over babble, music and fan noise. They teach nothing new about how the word sounds
        // (no transcript, so they add no candidate spans), but every pronunciation kept must hear them too.
        let cleanCount = positives.count
        if options.noisyCopies > 0, cleanCount >= 4 {
            let babbleSources = (longNegatives + mine).filter { $0.count >= 16_000 }
            var copies: [VoiceTuner.Utterance] = []
            for round in 0..<options.noisyCopies {
                for (index, take) in kept.enumerated() {
                    let background = NoiseAugmentation.background(for: index + round)
                    let seed = EvaluationAudio.contentSeed(take.samples) &+ UInt64(round + 1) &* 7_919
                    copies.append(VoiceTuner.Utterance(
                        samples: NoiseAugmentation.augment(take.samples, background: background, speech: babbleSources, seed: seed),
                        source: take.source + " + " + background.rawValue))
                }
            }
            positives += copies
            heardBySegment += Array(repeating: [], count: copies.count)
            log("  (+\(copies.count) noisy copies of your phrases — people talking, music and fan noise in the background — which Jarvis must hear too)")
        }
        guard cleanCount >= 4 else {
            log("\nOnly \(cleanCount) usable utterance(s) found — record at least about 10, a pause of a second or more between them, closer to the microphone if the room is noisy.")
            let reason = "Only \(positives.count) of your phrases could be used. Jarvis needs at least about ten, said clearly with a pause between them."
            return Outcome(
                report: VoiceTrainingReport(verdict: .notEnoughSpeech(reason: reason), total: positives.count), pronunciations: [], profileText: "",
                bySource: [], refusal: reason
            )
        }

        // Training and held-out utterances: every third one is held back, spread over all the sources (and, when they are so short that
        // this holds back almost nothing — a dozen sources of one word each — over the utterances as a whole).
        var train: [Int] = [], test: [Int] = []
        var seen: [String: Int] = [:]
        for (index, take) in positives.enumerated() {
            let count = seen[take.source, default: 0]
            seen[take.source] = count + 1
            if positives.count >= 9, count % 3 == 2 { test.append(index) } else { train.append(index) }
        }
        if positives.count >= 9, test.count < 3 {
            test = positives.indices.filter { $0 % 3 == 2 }
            train = positives.indices.filter { $0 % 3 != 2 }
        }
        log("\n\(positives.count) utterances of the word\(test.isEmpty ? "" : ": \(train.count) to learn from, \(test.count) held back to check")."
            + " Typical sounds the model hears:")
        for index in positives.indices.prefix(6) { log("    \(positives[index].source): \(heardBySegment[index].joined(separator: " "))") }
        log("\n\(shortNegatives.count) look-alike words, \(longNegatives.count) stretches of ordinary speech and \(mine.count) recording(s) of yours must stay silent (\(String(format: "%.1f", minutes)) min).")

        let trainClips = train.map { positives[$0].samples }, testClips = test.map { positives[$0].samples }
        let allClips = positives.map(\.samples)

        // Before: what the engine does now.
        report("Seeing how Jarvis hears you now…", 0.24)
        let beforeTrain = try heard(baseline, in: trainClips).count
        let beforeTest = try heard(baseline, in: testClips).count
        let beforeGroups = try heldOutGroups.map { try heard(baseline, in: $0.clips).count }
        log("\nWith the \(baselineName) pronunciations: \(beforeTrain)/\(trainClips.count) of the utterances to learn from heard"
            + (testClips.isEmpty ? "" : ", \(beforeTest)/\(testClips.count) of the held-back ones")
            + zip(heldOutGroups, beforeGroups).map { ", \($1)/\($0.clips.count) of \($0.name)" }.joined() + ".\n")

        // First fit: on the training utterances only, so that the held-back ones are a fair test.
        report("Trying ways of saying it…", 0.26)
        let trainTranscripts = train.map { heardBySegment[$0] }
        let found = try search(clips: trainClips, transcripts: trainTranscripts, verbose: true) { [self] scan in
            report("Trying ways of saying it…", 0.26 + 0.30 * scan)
        }
        report("Checking they stay quiet on everything else…", 0.58)
        let firstFit = try quietOnSpeech(found)
        guard !firstFit.isEmpty else {
            log("\nNo pronunciation hears your utterances and stays quiet on what must not fire — keep the defaults, raise Sensitivity, or record again closer to the microphone.")
            let reason = "Nothing I tried both understood you better and stayed quiet on everything else."
            return Outcome(
                report: VoiceTrainingReport(
                    verdict: .notImproved(reason: reason), heldBack: test.count, heardBefore: beforeTest, heardAfter: beforeTest, total: positives.count,
                    totalHeardBefore: beforeTrain + beforeTest, totalHeardAfter: beforeTrain + beforeTest,
                    silenceChecks: shortNegatives.count + longNegatives.count + mine.count
                ),
                pronunciations: [], profileText: "", bySource: [], refusal: reason
            )
        }
        let tunedTrain = try heard(firstFit, in: trainClips).count
        let tunedTest = try heard(firstFit, in: testClips).count
        let tunedGroups = try heldOutGroups.map { try heard(firstFit, in: $0.clips).count }
        log("\nFitted on the \(trainClips.count) utterances to learn from: \(firstFit.joined(separator: "  /  "))")
        log("  learned from: \(tunedTrain)/\(trainClips.count) heard (was \(beforeTrain))"
            + (testClips.isEmpty ? "" : " · held back: \(tunedTest)/\(testClips.count) heard (was \(beforeTest))")
            + " · false alarms: \(try alarmSummary(firstFit).text)")
        for (index, group) in heldOutGroups.enumerated() { log("  held out, \(group.name): \(tunedGroups[index])/\(group.clips.count) (was \(beforeGroups[index]))") }
        var bySource: [VoiceTuner.SourceLine] = []
        report("Checking each part of the lesson…", 0.62)
        for source in Set(positives.map(\.source)).sorted() {
            let clips = positives.indices.filter { positives[$0].source == source }.map { positives[$0].samples }
            bySource.append(.init(source: source, count: clips.count, before: try heard(baseline, in: clips).count, after: try heard(firstFit, in: clips).count))
        }
        if !test.isEmpty {
            log("  by recording, \(baselineName) → fitted (all utterances):\n" + bySource.map { "    \($0.source): \($0.before)/\($0.count) → \($0.after)/\($0.count)" }.joined(separator: "\n"))
        }

        // Final fit: all utterances, because there are few of them and every one teaches something. Nothing can check it on utterances
        // it has not seen, so it must at least keep the promises the first fit was held to — not one false alarm on ordinary speech,
        // which is what would show as the assistant waking up on its own — and hear no fewer of the utterances than the first fit does.
        let builtInHeard = try heard(baseline, in: allClips).count
        var chosen = firstFit
        if !test.isEmpty {
            report("Learning from all your phrases…", 0.66)
            let found = try search(clips: allClips, transcripts: heardBySegment, verbose: false) { [self] scan in
                report("Learning from all your phrases…", 0.66 + 0.24 * scan)
            }
            let refit = try quietOnSpeech(found)
            report("Final check…", 0.92)
            let refitHeard = refit.isEmpty ? 0 : try heard(refit, in: allClips).count
            let firstHeard = try heard(firstFit, in: allClips).count
            if !refit.isEmpty, refitHeard >= firstHeard {
                chosen = refit
                log("\nRefitted on all \(allClips.count) utterances: \(chosen.joined(separator: "  /  "))")
                log("  \(refitHeard)/\(allClips.count) heard (\(baselineName): \(builtInHeard)) · false alarms: \(try alarmSummary(refit).text)")
            } else {
                log("\nRefitting on all \(allClips.count) utterances found nothing better; keeping the first fit.")
                log("  \(firstHeard)/\(allClips.count) heard (\(baselineName): \(builtInHeard))")
            }
        }
        report("Final check…", 0.95)

        // Whether the list may be installed: only on evidence from utterances it did not learn from.
        let chosenHeard = try heard(chosen, in: allClips).count
        let silenceChecks = shortNegatives.count + longNegatives.count + mine.count
        let final = try alarmSummary(chosen)
        let improved = test.isEmpty ? tunedTrain > beforeTrain : (tunedTest > beforeTest && tunedTrain + tunedTest > beforeTrain + beforeTest)
        var verdict = VoiceTrainingReport.Verdict.improved
        if test.isEmpty {
            verdict = .notEnoughSpeech(reason: "There were too few phrases (\(positives.count)) to keep some back and check on them — about ten or more are needed.")
        } else if !improved {
            verdict = .notImproved(reason: "On phrases it hadn’t learned from, the new settings were no better than the ones Jarvis already has.")
        } else if chosenHeard <= builtInHeard {
            verdict = .notImproved(reason: "The new settings would not understand more of your phrases than the ones Jarvis already has.")
        } else if longNegatives.count + mine.count == 0 {
            verdict = .notEnoughSpeech(reason: "There was no ordinary speech to check that the new settings stay quiet on it.")
        }
        let refusal: String? = {
            switch verdict {
            case .improved: nil
            case .notImproved(let reason), .notEnoughSpeech(let reason): reason
            }
        }()
        let profileText = VoiceProfileFile.text(pronunciations: chosen, phrases: positives.count, sensitivity: sensitivity)
        let trainingReport = VoiceTrainingReport(
            verdict: verdict, heldBack: test.count, heardBefore: beforeTest, heardAfter: tunedTest, total: positives.count,
            totalHeardBefore: builtInHeard, totalHeardAfter: chosenHeard, silenceChecks: silenceChecks, falseAlarms: final.words + final.speech,
            notes: ["pronunciations: " + chosen.joined(separator: " / "), "false alarms: " + final.text], payload: Data(profileText.utf8)
        )
        self.report("Done.", 1)
        return Outcome(report: trainingReport, pronunciations: chosen, profileText: profileText, bySource: bySource, refusal: refusal)
    }
}

// MARK: - The reference speech

/// What the fit must stay silent on, made with the Mac's own voices: look-alike words in English and Spanish, and stretches of ordinary
/// speech in both (full of names that sound like Jarvis). About eleven minutes of audio, made the first time and then kept.
enum ReferenceSpeech {
    static func requests() -> (words: [MacSpeech.Request], speech: [MacSpeech.Request]) {
        var words: [MacSpeech.Request] = [], speech: [MacSpeech.Request] = []
        for voice in ["Samantha", "Moira", "Daniel", "Tessa"] {
            for text in ReferenceCorpus.decoys { words.append(.init(voice: voice, rate: 175, text: text)) }
        }
        for voice in ["Paulina", "Mónica", "Eddy (Español (México))"] {
            for text in ReferenceCorpus.spanishDecoys { words.append(.init(voice: voice, rate: 175, text: text)) }
        }
        for (index, paragraph) in (ReferenceCorpus.paragraphs.prefix(8) + ReferenceCorpus.lookalikeParagraphs.prefix(4)).enumerated() {
            for voice in ["Samantha", "Daniel"].prefix(index % 2 + 1) { speech.append(.init(voice: voice, rate: 175, text: paragraph)) }
        }
        for (index, paragraph) in (ReferenceCorpus.spanishParagraphs.prefix(6) + ReferenceCorpus.spanishLookalikeParagraphs.prefix(4)).enumerated() {
            for voice in ["Paulina", "Mónica", "Flo (Español (México))"].prefix(index % 2 + 1) { speech.append(.init(voice: voice, rate: 175, text: paragraph)) }
        }
        return (words, speech)
    }

    /// A sentence every voice says, to tell the voices the Mac really has from the ones it only lists.
    static let probeText = "Good morning. The quick brown fox jumps over the lazy dog."
    static let probeRate = 175

    /// The voices, among `voices`, that are worth making reference speech with. `say -v NAME` speaks with the system's own voice — without a word —
    /// when NAME is known but not downloaded, which would put several copies of one voice among the reference clips (an earlier corpus had
    /// seventeen). So each voice says the same sentence (`clips`; a voice that could not be made to speak has none), and of voices whose
    /// recordings are the same the first in `voices` stays: one copy of a voice is reference speech, seventeen are a bias. (The system's own voice
    /// may well be one of the reference voices, as it is on the author's Mac, so it is not itself a reason to leave a voice out.)
    static func genuine(among voices: [String], clips: [String: [Float]]) -> Set<String> {
        var seen: [[Float]] = []
        var result = Set<String>()
        for voice in voices {
            guard let clip = clips[voice], !clip.isEmpty, !seen.contains(clip) else { continue }
            seen.append(clip)
            result.insert(voice)
        }
        return result
    }

    static func genuineVoices(among voices: [String], cache: URL) -> Set<String> {
        var clips: [String: [Float]] = [:]
        for voice in voices { clips[voice] = MacSpeech.samples(voice: voice, rate: probeRate, text: probeText, cache: cache) }
        return genuine(among: voices, clips: clips)
    }

    static func negatives(
        cache: URL, isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) throws -> (words: [[Float]], speech: [[Float]]) {
        var wanted = requests()
        // Which of the voices exist is found out first (a few seconds, the first time), so that no minutes are spent on stand-ins.
        let voices = Array(Set((wanted.words + wanted.speech).map(\.voice))).sorted()
        MacSpeech.prepare(voices.map { MacSpeech.Request(voice: $0, rate: probeRate, text: probeText) }, cache: cache, isCancelled: isCancelled)
        if isCancelled() { throw VoiceTrainingError.cancelled }
        let genuine = genuineVoices(among: voices, cache: cache)
        wanted.words = wanted.words.filter { genuine.contains($0.voice) }
        wanted.speech = wanted.speech.filter { genuine.contains($0.voice) }
        MacSpeech.prepare(wanted.words + wanted.speech, cache: cache, progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw VoiceTrainingError.cancelled }
        func clips(_ list: [MacSpeech.Request]) -> [[Float]] {
            list.compactMap { MacSpeech.samples(voice: $0.voice, rate: $0.rate, text: $0.text, cache: cache) }
        }
        return (clips(wanted.words), clips(wanted.speech))
    }
}
