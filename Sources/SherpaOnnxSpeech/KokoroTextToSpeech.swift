import CSherpaOnnx
import Foundation
import FridaySpeech
import os

/// Text to speech with Kokoro (82M parameters, 24 kHz) running on sherpa-onnx: 54 voices in nine languages, no account,
/// no key and no network.
///
/// One loaded model speaks every language: English text goes through the lexicon the model was trained against, every
/// other language is phonemised by espeak-ng, chosen per call from the voice's language. Audio is streamed one sentence
/// at a time, as the library produces it, so a reply starts playing after its first sentence is ready rather than after
/// the whole text was synthesised. All native work runs on one serial queue; the object itself may be shared freely.
public final class KokoroTextToSpeech: TextToSpeechEngine, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var resources: SherpaOnnxSpeechResources
        /// Threads ONNX Runtime may use. Two is right for a model this size on Apple silicon: more buys little.
        public var numThreads: Int
        /// Lexicon file names in the model folder, consulted in order for English text (the first to list a word wins)
        /// before espeak-ng is asked. American English by default; add or substitute the British table for `b*` voices.
        public var lexicons: [String]
        /// Pause between sentences, as a fraction of the model's own (its examples use 0.2).
        public var silenceScale: Float
        /// What `warmUp()` says, quietly, so the first real reply pays no first-call cost.
        public var warmUpPhrase: String

        public init(
            resources: SherpaOnnxSpeechResources,
            numThreads: Int = 2,
            lexicons: [String] = [KokoroModelFiles.americanEnglishLexicon],
            silenceScale: Float = 0.2,
            warmUpPhrase: String = "Hello."
        ) {
            self.resources = resources
            self.numThreads = numThreads
            self.lexicons = lexicons
            self.silenceScale = silenceScale
            self.warmUpPhrase = warmUpPhrase
        }
    }

    public static let engineID = "kokoro"
    public static let sampleRate = 24_000
    /// `rate` is clamped to this before it reaches the model (outside it the speech is garbled or absurd).
    public static let rateRange: ClosedRange<Float> = 0.5...2.0
    /// The voice `warmUp()` uses.
    public static let warmUpVoiceID = "af_heart"
    static let maxThreads = 16

    /// Every voice, as the orchestrator sees them.
    public static let allVoices: [TTSVoice] = KokoroVoices.all.map {
        TTSVoice(id: $0.id, name: $0.name, language: $0.language, engineID: engineID)
    }

    public let id = KokoroTextToSpeech.engineID
    public let displayName = "Kokoro"
    public let configuration: Configuration

    /// Loading and generation happen here, one after the other: the native object is used from one thread at a time.
    private let queue = DispatchQueue(label: "friday.speech.kokoro", qos: .userInitiated)

    private struct State {
        var engine: NativeTTS?
        var lastFailure: SpeechError?
        var loadDuration: Duration?
        var lastReport: SynthesisReport?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public convenience init(resources: SherpaOnnxSpeechResources) {
        self.init(configuration: Configuration(resources: resources))
    }

    // MARK: - TextToSpeechEngine

    public func availability() async -> EngineAvailability {
        let missing = missingFiles
        if !missing.isEmpty {
            return .needsSetup(configuration.resources.setupMessage(missing: missing))
        }
        if let failure = state.withLock({ $0.lastFailure }) { return .unavailable(failure.localizedReason) }
        return .available
    }

    public func warmUp() async {
        guard let voice = Self.allVoices.first(where: { $0.id == Self.warmUpVoiceID }) else { return }
        do {
            for try await _ in synthesize(configuration.warmUpPhrase, voice: voice, rate: 1) {}
        } catch {
            // Reported by availability(); nothing to do here.
        }
    }

    public func voices() async -> [TTSVoice] { Self.allVoices }

    public func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error> {
        AsyncThrowingStream { continuation in
            let job = SynthesisJob(continuation: continuation)
            // The consumer stopped listening (or its task was cancelled): the next chunk callback returns 0 and the
            // library stops after the sentence it is on.
            continuation.onTermination = { @Sendable _ in job.cancel() }
            queue.async { [self] in
                if job.isCancelled {
                    continuation.finish()
                    return
                }
                do throws(SpeechError) {
                    guard voice.engineID == Self.engineID, let entry = KokoroVoices.entry(for: voice.id) else {
                        throw .synthesisFailed("\(voice.id) is not a Kokoro voice")
                    }
                    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !spoken.isEmpty else {
                        continuation.finish()
                        return
                    }
                    let engine = try loadedEngine()
                    let speed = min(max(rate.isFinite ? rate : 1, Self.rateRange.lowerBound), Self.rateRange.upperBound)
                    let report = try engine.generate(
                        spoken, speaker: entry.speakerID, speed: speed,
                        espeakVoice: KokoroVoices.espeakVoice(forLanguage: entry.language),
                        silenceScale: configuration.silenceScale, job: job
                    )
                    state.withLock { $0.lastReport = report }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Loading

    /// Loads the model now (idempotent), so the first reply is not delayed; `synthesize` does it on demand otherwise.
    public func load() async throws(SpeechError) {
        let outcome: Result<Void, SpeechError> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                do throws(SpeechError) {
                    _ = try loadedEngine()
                    continuation.resume(returning: .success(()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        try outcome.get()
    }

    /// How long loading the model took, once it has.
    public var loadDuration: Duration? { state.withLock { $0.loadDuration } }

    /// The files that are not where `configuration` says; empty when the engine can be loaded.
    public var missingFiles: [String] {
        var missing: [String] = []
        if !configuration.resources.isLibraryPresent { missing.append(configuration.resources.libraryURL.lastPathComponent) }
        missing += configuration.resources.kokoroFiles(lexicons: configuration.lexicons).missingFiles
        return missing
    }

    /// Runs on `queue` only.
    private func loadedEngine() throws(SpeechError) -> NativeTTS {
        if let engine = state.withLock({ $0.engine }) { return engine }
        let missing = missingFiles
        guard missing.isEmpty else {
            throw .engineUnavailable(configuration.resources.setupReason(missing: missing))
        }
        let clock = ContinuousClock()
        let started = clock.now
        do throws(SpeechError) {
            let engine = try NativeTTS.create(configuration)
            let elapsed = clock.now - started
            state.withLock {
                $0.engine = engine
                $0.loadDuration = elapsed
                $0.lastFailure = nil
            }
            return engine
        } catch {
            state.withLock { $0.lastFailure = error }
            throw error
        }
    }

    // MARK: - Diagnostics (tests and tools)

    /// What the last synthesis did; nil before the first.
    var lastReport: SynthesisReport? { state.withLock { $0.lastReport } }

    /// Returns once every synthesis queued so far has finished.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

/// How one synthesis went.
struct SynthesisReport: Sendable, Equatable {
    /// Chunks (sentences) delivered to the consumer.
    var chunks: Int
    var samples: Int
    /// The consumer went away and generation was stopped before the text was finished.
    var stoppedEarly: Bool
    /// From the start of generation to the first chunk; nil when nothing was delivered.
    var timeToFirstChunk: Duration?
    var elapsed: Duration
}

/// The consumer side of one `synthesize` call: where chunks go, and whether anyone is still listening.
final class SynthesisJob: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation

    private struct Progress {
        var cancelled = false
        var chunks = 0
        var samples = 0
        var sampleRate = KokoroTextToSpeech.sampleRate
        var started = ContinuousClock.now
        var firstChunk: Duration?
    }
    private let progress = OSAllocatedUnfairLock(initialState: Progress())

    init(continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool { progress.withLock { $0.cancelled } }

    func cancel() {
        progress.withLock { $0.cancelled = true }
    }

    /// Generation is about to start, at the model's rate.
    func begin(sampleRate: Int) {
        progress.withLock {
            $0.sampleRate = sampleRate
            $0.started = .now
        }
    }

    /// Copies `count` samples out of the library's buffer (only valid during the callback) and hands them to the
    /// consumer. False once the consumer has gone away: the library then stops.
    func deliver(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        let (cancelled, sampleRate) = progress.withLock { ($0.cancelled, $0.sampleRate) }
        if cancelled { return false }
        continuation.yield(AudioChunk(samples: Array(UnsafeBufferPointer(start: samples, count: count)), sampleRate: sampleRate))
        return progress.withLock { progress in
            progress.chunks += 1
            progress.samples += count
            if progress.firstChunk == nil { progress.firstChunk = ContinuousClock.now - progress.started }
            return !progress.cancelled
        }
    }

    func report() -> SynthesisReport {
        progress.withLock {
            SynthesisReport(
                chunks: $0.chunks, samples: $0.samples, stoppedEarly: $0.cancelled,
                timeToFirstChunk: $0.firstChunk, elapsed: ContinuousClock.now - $0.started
            )
        }
    }
}

/// The library calls this once per generated sentence, on the thread that called generate. `arg` is the job.
private let chunkCallback: SherpaOnnxGeneratedAudioProgressCallbackWithArg = { samples, count, _, arg in
    guard let arg else { return 0 }
    let job = Unmanaged<SynthesisJob>.fromOpaque(arg).takeUnretainedValue()
    if let samples, count > 0 {
        return job.deliver(samples, count: Int(count)) ? 1 : 0
    }
    return job.isCancelled ? 0 : 1
}

/// One loaded Kokoro model. Created and used on the engine's queue; destroyed with the last reference.
final class NativeTTS: @unchecked Sendable {
    private let library: SpeechLibrary
    private let handle: OpaquePointer
    let sampleRate: Int
    let speakerCount: Int

    private init(library: SpeechLibrary, handle: OpaquePointer, sampleRate: Int, speakerCount: Int) {
        self.library = library
        self.handle = handle
        self.sampleRate = sampleRate
        self.speakerCount = speakerCount
    }

    deinit {
        library.api.destroy_tts?(handle)
    }

    static func create(_ configuration: KokoroTextToSpeech.Configuration) throws(SpeechError) -> NativeTTS {
        let library = try SpeechLibrary.load(from: configuration.resources.libraryURL)
        guard let create = library.api.create_tts, let sampleRate = library.api.tts_sample_rate,
              let speakers = library.api.tts_num_speakers else {
            throw .engineUnavailable("library not loaded")
        }
        let files = configuration.resources.kokoroFiles(lexicons: configuration.lexicons)
        let strings = CStringBox()
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = strings.pointer(files.model.path)
        config.model.kokoro.voices = strings.pointer(files.voices.path)
        config.model.kokoro.tokens = strings.pointer(files.tokens.path)
        config.model.kokoro.data_dir = strings.pointer(files.espeakData.path)
        if !files.lexicons.isEmpty {
            config.model.kokoro.lexicon = strings.pointer(files.lexicons.map(\.path).joined(separator: ","))
        }
        // No fixed language: it is chosen per call from the voice (see `generate`). `dict_dir` is a legacy field the
        // library ignores.
        config.model.kokoro.length_scale = 1
        config.model.num_threads = Int32(min(max(configuration.numThreads, 1), KokoroTextToSpeech.maxThreads))
        config.model.provider = strings.pointer("cpu")
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = configuration.silenceScale

        let handle = withExtendedLifetime(strings) {
            withUnsafePointer(to: &config) { create($0) }
        }
        guard let handle else {
            throw .engineUnavailable(
                "the Kokoro model could not be loaded: the files are unreadable or do not match each other, or the sherpa-onnx "
                + "library was built without text-to-speech (run Scripts/fetch-sherpa.sh)"
            )
        }
        return NativeTTS(library: library, handle: handle, sampleRate: Int(sampleRate(handle)), speakerCount: Int(speakers(handle)))
    }

    /// One Piper (VITS) model: `model.onnx`, `tokens.txt`, phonemised by espeak-ng from `dataDirectory`.
    static func createVits(
        libraryURL: URL, model: URL, tokens: URL, dataDirectory: URL, numThreads: Int, silenceScale: Float
    ) throws(SpeechError) -> NativeTTS {
        let library = try SpeechLibrary.load(from: libraryURL)
        guard let create = library.api.create_tts, let sampleRate = library.api.tts_sample_rate,
              let speakers = library.api.tts_num_speakers else {
            throw .engineUnavailable("library not loaded")
        }
        let strings = CStringBox()
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.vits.model = strings.pointer(model.path)
        config.model.vits.tokens = strings.pointer(tokens.path)
        config.model.vits.data_dir = strings.pointer(dataDirectory.path)
        // Piper's own defaults (its voice cards): a little variation keeps the prosody from sounding flat.
        config.model.vits.noise_scale = 0.667
        config.model.vits.noise_scale_w = 0.8
        config.model.vits.length_scale = 1
        config.model.num_threads = Int32(min(max(numThreads, 1), KokoroTextToSpeech.maxThreads))
        config.model.provider = strings.pointer("cpu")
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = silenceScale
        let handle = withExtendedLifetime(strings) {
            withUnsafePointer(to: &config) { create($0) }
        }
        guard let handle else {
            throw .engineUnavailable("the Piper model could not be loaded (unreadable files, or a sherpa-onnx build without text-to-speech)")
        }
        return NativeTTS(library: library, handle: handle, sampleRate: Int(sampleRate(handle)), speakerCount: Int(speakers(handle)))
    }

    /// Synthesises `text`, delivering each sentence to `job` as it is produced. `espeakVoice` selects the language for
    /// phonemisation; nil routes the text through the lexicon (English).
    func generate(
        _ text: String, speaker: Int32, speed: Float, espeakVoice: String?, silenceScale: Float, job: SynthesisJob
    ) throws(SpeechError) -> SynthesisReport {
        guard let generate = library.api.tts_generate, let destroyAudio = library.api.tts_destroy_audio else {
            throw .engineUnavailable("library not loaded")
        }
        guard speaker >= 0, Int(speaker) < speakerCount else {
            throw .synthesisFailed("speaker \(speaker) is outside the model's \(speakerCount) voices")
        }
        job.begin(sampleRate: sampleRate)
        let strings = CStringBox()
        var config = SherpaOnnxGenerationConfig()
        config.sid = speaker
        config.speed = speed
        config.silence_scale = silenceScale
        if let espeakVoice {
            // The per-call language hint: the library reads `extra` as JSON and passes `lang` to the phonemiser.
            config.extra = strings.pointer("{\"lang\":\"\(espeakVoice)\"}")
        }
        let spoken = strings.pointer(text)
        let audio = withExtendedLifetime(strings) {
            withUnsafePointer(to: &config) { generate(handle, spoken, $0, chunkCallback, Unmanaged.passUnretained(job).toOpaque()) }
        }
        if let audio {
            // Everything was already handed over sentence by sentence; the assembled copy is only freed. (Defensively,
            // audio that arrived without a single callback is still delivered.)
            if job.report().chunks == 0, audio.pointee.n > 0, let samples = audio.pointee.samples {
                _ = job.deliver(samples, count: Int(audio.pointee.n))
            }
            destroyAudio(audio)
        }
        let report = job.report()
        if report.chunks == 0, !report.stoppedEarly {
            throw .synthesisFailed("the text produced no audio (an alphabet or language the model cannot read?)")
        }
        return report
    }
}
