import Foundation
import WakeWordKit

/// Asks the keyword model **which sounds it hears** in a recording — the same network that listens for "Jarvis", used as a
/// plain streaming recogniser (greedy search, no keyword). It is how the voice-tuning tool finds out what *your* "Jarvis"
/// sounds like to the model: a Spanish accent, a fast "hey Jarvis" or a tired voice may come out as `HH AA1 R B IY0 S`, as
/// `JH AA1 B V IY0 AH0 S` — or as Mandarin syllables (`j iā zh è b ǐ s`), because the network is bilingual. A pronunciation list
/// that does not contain what the model really hears cannot match, however much the keyword is boosted.
///
/// Detection never uses this; it exists for tools. Like the engine, it vets the model files before the library sees them.
public final class SherpaSoundRecognizer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var libraryURL: URL
        public var model: SherpaOnnxWakeWordEngine.ModelFiles
        public var integrity: ModelIntegrity
        /// The same level stage the engine puts in front of the model (nil: the audio as it is). Without it a quiet recording
        /// is heard very differently from what the engine will hear.
        public var levelNormaliser: LevelNormaliser.Configuration?

        public init(
            libraryURL: URL, model: SherpaOnnxWakeWordEngine.ModelFiles,
            integrity: ModelIntegrity = SherpaOnnxBackend.phoneModel.digests.map { .verified($0) } ?? .unverified,
            levelNormaliser: LevelNormaliser.Configuration? = LevelNormaliser.Configuration()
        ) {
            self.libraryURL = libraryURL
            self.model = model
            self.integrity = integrity
            self.levelNormaliser = levelNormaliser
        }
    }

    private struct State {
        var bindings: (any SherpaRecognizerBindings)?
        var recognizer: OpaquePointer?
        var isShutDown = false
    }

    private let configuration: Configuration
    private let makeBindings: @Sendable () throws(WakeWordError) -> any SherpaRecognizerBindings
    private let state = Protected(State())
    /// One recording at a time: the native recogniser is not re-entrant.
    private let busy = Protected(())

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, makeBindings: { () throws(WakeWordError) -> any SherpaRecognizerBindings in
            try LibraryBindings.load(from: configuration.libraryURL)
        })
    }

    /// Test seam: supply the native layer.
    init(configuration: Configuration, makeBindings: @escaping @Sendable () throws(WakeWordError) -> any SherpaRecognizerBindings) {
        self.configuration = configuration
        self.makeBindings = makeBindings
    }

    deinit { shutdown() }

    /// Loads the model (about half a second). Idempotent.
    public func initialize() throws(WakeWordError) {
        let already = state.withLock { state -> WakeWordError? in
            if state.isShutDown { return .shutDown }
            return nil
        }
        if let already { throw already }
        if state.withLock({ $0.recognizer != nil }) { return }

        let missing = configuration.model.all.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        if !missing.isEmpty { throw .engineUnavailable("missing model file(s): \(missing.joined(separator: ", "))") }
        if case .verified(let digests) = configuration.integrity {
            let damaged = ModelVerifier.damagedFiles(in: configuration.model, expecting: digests)
            if !damaged.isEmpty {
                throw .engineUnavailable("damaged or unexpected model file(s): \(damaged.joined(separator: ", ")). Run Scripts/fetch-sherpa.sh and rebuild.")
            }
        }
        let bindings = try makeBindings()
        let settings = SpotterSettings(
            encoder: configuration.model.encoder.path, decoder: configuration.model.decoder.path,
            joiner: configuration.model.joiner.path, tokens: configuration.model.tokens.path, initialKeywords: ""
        )
        let recognizer: OpaquePointer
        do throws(NativeFailure) { recognizer = try bindings.makeRecognizer(settings) } catch { throw .engineUnavailable(error.message) }
        let installed: Bool = state.withLock { state in
            guard !state.isShutDown, state.recognizer == nil else { return false }
            state.bindings = bindings
            state.recognizer = recognizer
            return true
        }
        if !installed { bindings.destroyRecognizer(recognizer) }
    }

    /// The sounds the model hears in `samples` (mono, 16 kHz, within ±1), in order — empty for silence or after `shutdown()`.
    public func sounds(in samples: [Float]) -> [String] {
        busy.withLock { _ in
            let owned = state.withLock { ($0.bindings, $0.recognizer) }
            guard let bindings = owned.0, let recognizer = owned.1, !samples.isEmpty else { return [] }
            // Not audio (NaN, infinity, absurd size): the network would be fed garbage.
            guard samples.allSatisfy({ $0.isFinite && abs($0) <= SherpaOnnxWakeWordEngine.implausiblePeak }) else { return [] }
            var heard = samples
            if let configuration = configuration.levelNormaliser {
                // One gain for the whole recording, as the engine uses one for the whole opening of a stretch of sound — taken from the
                // loudest 100 ms frame as the engine counts it (a click counts for less than its peak), not from the loudest sample.
                var normaliser = LevelNormaliser(configuration)
                let frame = 1_600
                var loudest: Float = 0, peak: Float = 0
                samples.withUnsafeBufferPointer { buffer in
                    var start = 0
                    while start < buffer.count {
                        let level = AudioLevel.measure(UnsafeBufferPointer(rebasing: buffer[start..<min(buffer.count, start + frame)]))
                        loudest = max(loudest, normaliser.level(peak: level.peak, rms: level.rms))
                        peak = max(peak, level.peak)
                        start += frame
                    }
                }
                let gain = normaliser.begin(peak: loudest)
                // Within ±1, as the engine feeds the model — also when the gain is 1 and the recording itself is beyond full scale.
                if gain != 1 || peak > 1 { heard = samples.map { min(1, max(-1, $0 * gain)) } }
            }
            return heard.withUnsafeBufferPointer {
                bindings.transcribe(recognizer: recognizer, samples: $0.baseAddress!, count: $0.count, sampleRate: 16_000)
            }
        }
    }

    public func shutdown() {
        busy.withLock { _ in
            let owned = state.withLock { state -> ((any SherpaRecognizerBindings), OpaquePointer)? in
                defer { state.bindings = nil; state.recognizer = nil; state.isShutDown = true }
                guard let bindings = state.bindings, let recognizer = state.recognizer else { return nil }
                return (bindings, recognizer)
            }
            if let owned { owned.0.destroyRecognizer(owned.1) }
        }
    }
}
