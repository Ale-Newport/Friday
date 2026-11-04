import Foundation
import WakeWordKit

/// Wake-word detection with sherpa-onnx's open-vocabulary keyword spotter: a tiny streaming speech model that is told
/// *which sounds to listen for*, so "Jarvis" needs no per-word training, no account, no key and no network.
///
/// Everything sherpa-specific lives in this module: the native library, its model files, its keyword syntax and the
/// mapping from the 0…1 sensitivity to its boost and threshold. The rest of the application sees only
/// ``WakeWordEngine``.
public final class SherpaOnnxWakeWordEngine: WakeWordEngine, @unchecked Sendable {
    /// The three network files and the token table of one streaming transducer model.
    public struct ModelFiles: Sendable, Equatable {
        public var encoder: URL
        public var decoder: URL
        public var joiner: URL
        public var tokens: URL

        public init(encoder: URL, decoder: URL, joiner: URL, tokens: URL) {
            self.encoder = encoder
            self.decoder = decoder
            self.joiner = joiner
            self.tokens = tokens
        }

        var all: [URL] { [encoder, decoder, joiner, tokens] }
    }

    public struct Configuration: Sendable {
        public var libraryURL: URL
        public var model: ModelFiles
        /// How "Jarvis" can sound, as token sequences in the model's own alphabet — several, so that an accent or a
        /// different stress still matches (see ``SherpaOnnxBackend/Keyword``).
        public var pronunciations: [String]
        /// Normalised sensitivity in `[0, 1]`.
        public var sensitivity: Float
        public var tuning: KeywordTuning
        public var numThreads: Int
        public var numTrailingBlanks: Int
        /// How many alternative decodings are kept alive at once; more finds a keyword spoken unusually, at some CPU cost.
        public var maxActivePaths: Int
        /// Keeps the neural model idle while the room is quiet (see ``ActivityGate``); nil runs it on every frame.
        public var activityGate: ActivityGate.Configuration?
        /// Brings speech to the level the network hears best, whatever the microphone delivers (see ``LevelNormaliser``); nil feeds
        /// the audio as it comes.
        public var levelNormaliser: LevelNormaliser.Configuration?
        /// What is checked about the model files before the library is allowed to read them.
        public var integrity: ModelIntegrity
        /// Samples per frame handed to the engine. 1 600 at 16 kHz is 100 ms: one engine call per microphone buffer.
        public var frameLength: Int

        public init(
            libraryURL: URL,
            model: ModelFiles,
            pronunciations: [String],
            sensitivity: Float = 0.5,
            tuning: KeywordTuning = .default,
            numThreads: Int = 1,
            numTrailingBlanks: Int = 1,
            maxActivePaths: Int = SherpaOnnxBackend.defaultMaxActivePaths,
            activityGate: ActivityGate.Configuration? = ActivityGate.Configuration(),
            levelNormaliser: LevelNormaliser.Configuration? = LevelNormaliser.Configuration(),
            frameLength: Int = 1_600,
            integrity: ModelIntegrity = SherpaOnnxBackend.phoneModel.digests.map { .verified($0) } ?? .unverified
        ) {
            self.libraryURL = libraryURL
            self.model = model
            self.pronunciations = pronunciations
            self.sensitivity = sensitivity
            self.tuning = tuning
            self.numThreads = numThreads
            self.numTrailingBlanks = numTrailingBlanks
            self.maxActivePaths = maxActivePaths
            self.activityGate = activityGate
            self.levelNormaliser = levelNormaliser
            self.frameLength = frameLength
            self.integrity = integrity
        }
    }

    public static let engineID = "sherpa-onnx"
    public static let sampleRate = 16_000

    /// Upper bounds on the native settings; a larger number is a mistake, and `Int32(_:)` traps on an absurd one.
    static let maxThreads = 32, maxActivePaths = 256, maxTrailingBlanks = 64

    /// A sample larger than this is not audio (normalised samples lie within ±1).
    static let implausiblePeak: Float = 16

    public let identifier = SherpaOnnxWakeWordEngine.engineID

    private enum Lifecycle { case created, ready, shutDown }
    private enum Installation { case installed, alreadyReady, shutDown }

    private struct State {
        var lifecycle = Lifecycle.created
        /// Resolved once, in `initialize()`: the audio path must not look symbols up (or fail to) per frame.
        var bindings: (any SherpaBindings)?
        var spotter: OpaquePointer?
        var stream: OpaquePointer?
        var sensitivity: Float
        var gate: ActivityGate?
        var normaliser: LevelNormaliser?
        /// Whether the normaliser is following a stretch of sound (it begins with each burst, or with the first frame when there is no gate).
        var normaliserRunning = false
        /// What the stream is listening for now (starts as the configuration's; tools may retarget it).
        var pronunciations: [String]
        var tokenTable: TokenTable?
        /// The last few frames while the gate is closed: if speech starts, the model hears its beginning too.
        var preRoll: [[Float]] = []
        var gateWasOpen = false
        var framesFed = 0
        var framesSkipped = 0
    }

    /// Visible to the tests, which check that the descriptor builds the engine it should.
    let configuration: Configuration
    private let makeBindings: @Sendable () throws(WakeWordError) -> any SherpaBindings
    private let state: Protected<State>
    public let audioRequirements: AudioRequirements

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, makeBindings: { () throws(WakeWordError) -> any SherpaBindings in
            try LibraryBindings.load(from: configuration.libraryURL)
        })
    }

    /// Test seam: supply the native layer.
    init(configuration: Configuration, makeBindings: @escaping @Sendable () throws(WakeWordError) -> any SherpaBindings) {
        self.configuration = configuration
        self.makeBindings = makeBindings
        self.audioRequirements = AudioRequirements(sampleRate: Self.sampleRate, frameLength: configuration.frameLength)
        self.state = Protected(State(
            sensitivity: min(1, max(0, configuration.sensitivity)),
            gate: configuration.activityGate.map { ActivityGate($0) },
            normaliser: configuration.levelNormaliser.map { LevelNormaliser($0) },
            pronunciations: configuration.pronunciations
        ))
    }

    deinit {
        // Defensive: the host is expected to call shutdown(), but never leak native objects.
        release()
    }

    // MARK: - Lifecycle

    public func initialize() async throws(WakeWordError) {
        let lifecycle = state.withLock { $0.lifecycle }
        switch lifecycle {
        case .shutDown: throw .shutDown
        case .ready: return
        case .created: break
        }

        // Everything the library is given is vetted first, and before it is even loaded: it answers a bad model, or a keyword made
        // of sounds the model does not have, by logging and exiting the whole process. (See `PronunciationLimits` and `TokenTable`.)
        guard !configuration.pronunciations.isEmpty else { throw .invalidConfiguration("no pronunciation of the keyword configured") }
        guard audioRequirements.isValid else { throw .invalidConfiguration("unusable frame length \(configuration.frameLength)") }
        guard (1...Self.maxThreads).contains(configuration.numThreads),
              (1...Self.maxActivePaths).contains(configuration.maxActivePaths),
              (0...Self.maxTrailingBlanks).contains(configuration.numTrailingBlanks) else {
            throw .invalidConfiguration("threads (1–\(Self.maxThreads)), alternative readings (1–\(Self.maxActivePaths)) and trailing blanks (0–\(Self.maxTrailingBlanks)) must be in range")
        }
        try validateFiles()
        if case .verified(let digests) = configuration.integrity {
            let damaged = ModelVerifier.damagedFiles(in: configuration.model, expecting: digests)
            if !damaged.isEmpty {
                throw .engineUnavailable("damaged or unexpected model file(s): \(damaged.joined(separator: ", ")). Run Scripts/fetch-sherpa.sh and rebuild.")
            }
        }
        let table = try TokenTable(contentsOf: configuration.model.tokens)
        try table.validate(configuration.pronunciations)
        let sensitivity = state.withLock { $0.sensitivity }
        let keywords = try keywordDefinition(sensitivity: sensitivity, pronunciations: configuration.pronunciations)
        let bindings = try makeBindings()

        // Building the spotter loads and prepares three neural networks: keep that off the cooperative thread pool.
        let configuration = self.configuration
        let settings = SpotterSettings(
            encoder: configuration.model.encoder.path, decoder: configuration.model.decoder.path,
            joiner: configuration.model.joiner.path, tokens: configuration.model.tokens.path,
            numThreads: Int32(configuration.numThreads), maxActivePaths: Int32(configuration.maxActivePaths),
            numTrailingBlanks: Int32(configuration.numTrailingBlanks), initialKeywords: keywords
        )
        let outcome: Result<NativeObjects, NativeFailure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(NativeFailure) {
                    let spotter = try bindings.makeSpotter(settings)
                    do throws(NativeFailure) {
                        let stream = try bindings.makeStream(spotter: spotter, keywords: keywords)
                        continuation.resume(returning: .success(NativeObjects(spotter: spotter, stream: stream)))
                    } catch {
                        bindings.destroySpotter(spotter)
                        continuation.resume(returning: .failure(error))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch outcome {
        case .failure(let failure):
            throw .engineUnavailable(failure.message)
        case .success(let objects):
            let installation: Installation = state.withLock { state in
                // A concurrent shutdown() (or a second initialize()) while we were building wins; release what we built.
                switch state.lifecycle {
                case .shutDown: return .shutDown
                case .ready: return .alreadyReady
                case .created:
                    state.bindings = bindings
                    state.tokenTable = table
                    state.spotter = objects.spotter
                    state.stream = objects.stream
                    state.lifecycle = .ready
                    return .installed
                }
            }
            if installation != .installed {
                bindings.destroyStream(objects.stream)
                bindings.destroySpotter(objects.spotter)
                if installation == .shutDown { throw .shutDown }
            }
        }
    }

    public func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult? {
        try state.withLock { (state) throws(WakeWordError) -> DetectionResult? in
            switch state.lifecycle {
            case .created: throw .notInitialized
            case .shutDown: throw .shutDown
            case .ready: break
            }
            guard let bindings = state.bindings, let spotter = state.spotter, let stream = state.stream else { throw .notInitialized }
            guard frame.samples.count == configuration.frameLength else {
                throw .invalidFrame(expected: configuration.frameLength, actual: frame.samples.count)
            }
            guard frame.sampleRate == Self.sampleRate else {
                throw .invalidConfiguration("frame sample rate \(frame.sampleRate) ≠ \(Self.sampleRate)")
            }

            /// Feeds a frame to the model, scaled by a gain that moves from `from` to `to` across it (so there is no step in the
            /// waveform). The result stays within ±1, whatever the gain.
            func feed(_ samples: [Float], from: Float = 1, to: Float = 1, clamp: Bool = false) -> Bool {
                var scaled = samples
                if from != 1 || to != 1 || clamp {
                    let count = Float(samples.count)
                    for index in scaled.indices {
                        let gain = from + (to - from) * Float(index) / count
                        scaled[index] = min(1, max(-1, samples[index] * gain))
                    }
                }
                return scaled.withUnsafeBufferPointer { buffer in
                    bindings.feed(spotter: spotter, stream: stream, samples: buffer.baseAddress!, count: buffer.count, sampleRate: Self.sampleRate) != nil
                }
            }

            let measured = frame.samples.withUnsafeBufferPointer { AudioLevel.measure($0) }
            let level = measured.rmsDecibels
            // A frame of NaN, infinity or absurdly large numbers (a driver glitch, a divide by zero upstream) is not audio.
            // Fed to the model it would poison the streaming state, and nothing would clean it while a noisy room keeps the
            // gate open. So it is dropped, together with the quiet frames remembered before it, and the next frame that is
            // heard starts the model afresh. (Normalised samples lie within ±1; 16 leaves room for a hot device.)
            guard level.isFinite, measured.peak <= Self.implausiblePeak else {
                state.gateWasOpen = false
                state.normaliserRunning = false
                state.preRoll.removeAll(keepingCapacity: true)
                state.framesSkipped += 1
                if state.gate == nil {
                    bindings.reset(spotter: spotter, stream: stream)
                }
                return nil
            }

            // A quiet room: nothing can have been said, so the model stays idle (and the frame is remembered in case
            // the next one is the start of a word).
            if var gate = state.gate {
                let open = gate.update(levelDecibels: level)
                state.gate = gate
                guard open else {
                    state.gateWasOpen = false
                    state.normaliserRunning = false
                    state.framesSkipped += 1
                    state.preRoll.append(frame.samples)
                    if state.preRoll.count > gate.configuration.preRollFrames { state.preRoll.removeFirst() }
                    return nil
                }
            }

            var heard = false
            var gainFrom: Float = 1, gainTo: Float = 1
            if state.gate != nil, !state.gateWasOpen {
                // The room just got louder: start from a clean slate, with the last moments of quiet as lead-in.
                bindings.reset(spotter: spotter, stream: stream)
                var burstGain: Float = 1
                if var normaliser = state.normaliser {
                    // One gain for the whole opening: the lead-in and the first loud frame are one stretch of sound to the model.
                    var counts = normaliser.level(peak: measured.peak, rms: measured.rms), peak = measured.peak
                    for earlier in state.preRoll {
                        let level = earlier.withUnsafeBufferPointer { AudioLevel.measure($0) }
                        counts = max(counts, normaliser.level(peak: level.peak, rms: level.rms))
                        peak = max(peak, level.peak)
                    }
                    burstGain = normaliser.begin(level: counts, peak: peak)
                    state.normaliser = normaliser
                    state.normaliserRunning = true
                }
                for earlier in state.preRoll where feed(earlier, from: burstGain, to: burstGain) { heard = true }
                state.framesFed += state.preRoll.count
                state.preRoll.removeAll(keepingCapacity: true)
                state.gateWasOpen = true
                (gainFrom, gainTo) = (burstGain, burstGain)
            } else if var normaliser = state.normaliser {
                let counts = normaliser.level(peak: measured.peak, rms: measured.rms)   // a click counts for less than its peak
                if state.normaliserRunning {
                    (gainFrom, gainTo) = normaliser.advance(level: counts, peak: measured.peak)
                } else {
                    // No gate (a tool evaluating the model): the first frame begins the stretch of sound.
                    gainFrom = normaliser.begin(level: counts, peak: measured.peak)
                    gainTo = gainFrom
                    state.normaliserRunning = true
                }
                state.normaliser = normaliser
            }
            if feed(frame.samples, from: gainFrom, to: gainTo, clamp: measured.peak > 1) { heard = true }   // a hot device may exceed full scale
            state.framesFed += 1
            return heard ? DetectionResult(keyword: .jarvis, confidence: nil) : nil
        }
    }

    /// How many frames the model processed and how many it skipped because the room was quiet.
    var activity: (fed: Int, skipped: Int) { state.withLock { ($0.framesFed, $0.framesSkipped) } }

    /// The threshold and boost live in the keyword definition of a *stream*, so a new sensitivity is a new stream
    /// built from the same loaded model: instant, and the network is not reloaded.
    public func updateSensitivity(_ value: Float) throws(WakeWordError) {
        guard (0...1).contains(value) else { throw .invalidConfiguration("sensitivity \(value) is outside 0...1") }
        try replaceStream(sensitivity: value, pronunciations: nil)
    }

    /// Listens for a different set of pronunciations from now on, with a fresh stream. They are checked against the
    /// model's own sounds exactly like the configured ones. For tools that search for the pronunciations that suit a
    /// voice (`jarvis-bench kws-tune`); not part of the ``WakeWordEngine`` contract.
    public func setPronunciations(_ pronunciations: [String]) throws(WakeWordError) {
        try replaceStream(sensitivity: nil, pronunciations: pronunciations)
    }

    private func replaceStream(sensitivity: Float?, pronunciations: [String]?) throws(WakeWordError) {
        let snapshot = state.withLock { ($0.bindings, $0.spotter, $0.lifecycle, $0.tokenTable, $0.sensitivity, $0.pronunciations) }
        let (bindings, spotter, lifecycle, table, currentSensitivity, currentPronunciations) = snapshot
        switch lifecycle {
        case .created: throw .notInitialized
        case .shutDown: throw .shutDown
        case .ready: break
        }
        guard let bindings, let spotter else { throw .notInitialized }
        if let pronunciations {
            guard let table else { throw .notInitialized }
            try table.validate(pronunciations)
        }
        let value = sensitivity ?? currentSensitivity
        let list = pronunciations ?? currentPronunciations
        let keywords = try keywordDefinition(sensitivity: value, pronunciations: list)
        let replacement: OpaquePointer
        do throws(NativeFailure) {
            replacement = try bindings.makeStream(spotter: spotter, keywords: keywords)
        } catch {
            throw .internalFailure(error.message)
        }
        let previous: OpaquePointer?? = state.withLock { state in
            guard state.lifecycle == .ready else { return nil }   // shut down meanwhile: drop the new stream below
            let previous = state.stream
            state.stream = replacement
            state.sensitivity = value
            state.pronunciations = list
            state.gateWasOpen = false   // a new stream starts clean; the gate re-primes it when sound arrives
            return .some(previous)
        }
        guard let previous else {
            bindings.destroyStream(replacement)
            throw .shutDown
        }
        if let previous { bindings.destroyStream(previous) }
    }

    public func shutdown() {
        release()
    }

    // MARK: - Helpers

    /// Marks the engine shut down and destroys the native objects, once. (`processAudio` holds the same lock for the
    /// whole native call, so nothing is destroyed while it is in use.)
    private func release() {
        let owned = state.withLock { state -> (bindings: any SherpaBindings, spotter: OpaquePointer, stream: OpaquePointer?)? in
            defer {
                state.stream = nil
                state.spotter = nil
                state.bindings = nil
                state.lifecycle = .shutDown
            }
            guard let bindings = state.bindings, let spotter = state.spotter else { return nil }
            return (bindings, spotter, state.stream)
        }
        guard let owned else { return }
        if let stream = owned.stream { owned.bindings.destroyStream(stream) }
        owned.bindings.destroySpotter(owned.spotter)
    }

    /// The keyword definition handed to the library, refusing a boost or threshold it would answer by aborting the process.
    private func keywordDefinition(sensitivity: Float, pronunciations: [String]) throws(WakeWordError) -> String {
        let (boost, threshold) = configuration.tuning.values(forSensitivity: sensitivity)
        guard boost.isFinite, threshold.isFinite, threshold > 0 else {
            throw .invalidConfiguration("the tuning gives a boost of \(boost) and a threshold of \(threshold) for sensitivity \(sensitivity)")
        }
        return SherpaOnnxBackend.keywordDefinition(pronunciations: pronunciations, sensitivity: sensitivity, tuning: configuration.tuning)
    }

    private func validateFiles() throws(WakeWordError) {
        let missing = configuration.model.all.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        if !missing.isEmpty {
            throw .engineUnavailable("missing model file(s): \(missing.joined(separator: ", "))")
        }
    }
}

/// `OpaquePointer` is not `Sendable`; the box documents that ownership is handed over exactly once.
private struct NativeObjects: @unchecked Sendable {
    let spotter: OpaquePointer
    let stream: OpaquePointer
}
