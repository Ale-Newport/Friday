import CSherpaOnnx
import Foundation
import FridaySpeech
import os

/// Voice activity with the Silero VAD model on sherpa-onnx: 16 kHz mono in, speech segments out.
///
/// The model judges 512-sample windows (32 ms); audio of any chunk size is accumulated into whole windows here, and the
/// remainder is kept for the next call (or padded with silence by `flush()`). The model loads on first use; a failure
/// to load is reported by `availability()` and `prepare()`, and makes `accept` a no-op rather than a crash.
public final class SileroVoiceActivityDetector: VoiceActivityDetector, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var libraryURL: URL
        public var modelURL: URL
        /// Speech probability above which a window counts as speech.
        public var threshold: Float
        /// Quiet that ends an utterance, in seconds.
        public var minSilenceDuration: Float
        /// Bursts shorter than this are not reported, in seconds.
        public var minSpeechDuration: Float
        /// A segment running this long is split: the detector raises its threshold until it finds a gap. Seconds.
        public var maxSpeechDuration: Float
        public var numThreads: Int

        public init(
            resources: SherpaOnnxSpeechResources,
            threshold: Float = 0.5,
            minSilenceDuration: Float = 0.5,
            minSpeechDuration: Float = 0.25,
            maxSpeechDuration: Float = 20,
            numThreads: Int = 1
        ) {
            self.libraryURL = resources.libraryURL
            self.modelURL = resources.sileroModelURL
            self.threshold = threshold
            self.minSilenceDuration = minSilenceDuration
            self.minSpeechDuration = minSpeechDuration
            self.maxSpeechDuration = maxSpeechDuration
            self.numThreads = numThreads
        }
    }

    public static let engineID = "silero"
    public static let sampleRate = 16_000
    public static let windowSize = 512
    static let maxThreads = 16

    public let id = SileroVoiceActivityDetector.engineID
    public let configuration: Configuration

    private struct State {
        var detector: NativeVAD?
        var failure: SpeechError?
        /// Samples not yet making up a whole window.
        var pending: [Float] = []
        /// Completed segments moved out of the library, oldest first.
        var segments: [SpeechSegment] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public convenience init(resources: SherpaOnnxSpeechResources) {
        self.init(configuration: Configuration(resources: resources))
    }

    // MARK: - Setup

    public func availability() -> EngineAvailability {
        let missing = missingFiles
        if !missing.isEmpty {
            return .needsSetup("missing \(missing.joined(separator: ", ")); run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh")
        }
        if let failure = state.withLock({ $0.failure }) { return .unavailable(failure.reason) }
        return .available
    }

    public var missingFiles: [String] {
        [configuration.libraryURL, configuration.modelURL]
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
    }

    /// Loads the model now (idempotent); `accept` does it on first use otherwise, silently.
    public func prepare() throws(SpeechError) {
        let outcome: Result<Void, SpeechError> = state.withLock { state in
            do throws(SpeechError) {
                _ = try load(&state)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try outcome.get()
    }

    // MARK: - VoiceActivityDetector

    public func accept(_ samples: [Float]) {
        state.withLock { state in
            guard let detector = try? load(&state) else { return }
            state.pending.append(contentsOf: samples)
            let windows = state.pending.count / Self.windowSize
            guard windows > 0 else { return }
            state.pending.withUnsafeBufferPointer { buffer in
                for index in 0..<windows {
                    detector.accept(buffer.baseAddress! + index * Self.windowSize, count: Self.windowSize)
                }
            }
            state.pending.removeFirst(windows * Self.windowSize)
            detector.drain(into: &state.segments)
        }
    }

    public var isSpeechActive: Bool {
        state.withLock { $0.detector?.isDetected ?? false }
    }

    public func popSegments() -> [SpeechSegment] {
        state.withLock { state in
            state.detector?.drain(into: &state.segments)
            defer { state.segments.removeAll() }
            return state.segments
        }
    }

    public func flush() {
        state.withLock { state in
            guard let detector = state.detector else { return }
            if !state.pending.isEmpty {
                // The last partial window, padded with silence so its samples are not lost.
                var window = state.pending
                window.append(contentsOf: repeatElement(0, count: Self.windowSize - window.count))
                window.withUnsafeBufferPointer { detector.accept($0.baseAddress!, count: Self.windowSize) }
                state.pending.removeAll()
            }
            detector.flush()
            detector.drain(into: &state.segments)
        }
    }

    public func reset() {
        state.withLock { state in
            state.pending.removeAll()
            state.segments.removeAll()
            state.detector?.reset()
        }
    }

    // MARK: - Helpers

    /// The detector, created on first use; a failure is remembered and reported, not retried on every frame.
    private func load(_ state: inout State) throws(SpeechError) -> NativeVAD {
        if let detector = state.detector { return detector }
        if let failure = state.failure { throw failure }
        do throws(SpeechError) {
            let missing = missingFiles
            guard missing.isEmpty else {
                throw .engineUnavailable("missing \(missing.joined(separator: ", ")); run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh")
            }
            let detector = try NativeVAD.create(configuration)
            state.detector = detector
            return detector
        } catch {
            state.failure = error
            throw error
        }
    }
}

/// One Silero detector. Used under the engine's lock only; destroyed with the last reference.
final class NativeVAD: @unchecked Sendable {
    private let library: SpeechLibrary
    private let handle: OpaquePointer

    private init(library: SpeechLibrary, handle: OpaquePointer) {
        self.library = library
        self.handle = handle
    }

    deinit {
        library.api.destroy_vad?(handle)
    }

    static func create(_ configuration: SileroVoiceActivityDetector.Configuration) throws(SpeechError) -> NativeVAD {
        let library = try SpeechLibrary.load(from: configuration.libraryURL)
        guard let create = library.api.create_vad else { throw .engineUnavailable("library not loaded") }
        let strings = CStringBox()
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = strings.pointer(configuration.modelURL.path)
        config.silero_vad.threshold = configuration.threshold
        config.silero_vad.min_silence_duration = configuration.minSilenceDuration
        config.silero_vad.min_speech_duration = configuration.minSpeechDuration
        config.silero_vad.max_speech_duration = configuration.maxSpeechDuration
        config.silero_vad.window_size = Int32(SileroVoiceActivityDetector.windowSize)
        config.sample_rate = Int32(SileroVoiceActivityDetector.sampleRate)
        config.num_threads = Int32(min(max(configuration.numThreads, 1), SileroVoiceActivityDetector.maxThreads))
        config.provider = strings.pointer("cpu")
        config.debug = 0
        // The library keeps the audio of the segment in progress in a ring of this many seconds; it grows if a segment
        // outlasts it, so this is a starting size, not a limit.
        let bufferSeconds = max(30, configuration.maxSpeechDuration * 2)
        let handle = withExtendedLifetime(strings) {
            withUnsafePointer(to: &config) { create($0, bufferSeconds) }
        }
        guard let handle else {
            throw .engineUnavailable("the Silero VAD model could not be loaded (\(configuration.modelURL.lastPathComponent) is unreadable or not a Silero model)")
        }
        return NativeVAD(library: library, handle: handle)
    }

    func accept(_ samples: UnsafePointer<Float>, count: Int) {
        library.api.vad_accept_waveform?(handle, samples, Int32(count))
    }

    var isDetected: Bool {
        library.api.vad_detected?(handle) != 0
    }

    /// Moves every completed segment out of the library.
    func drain(into segments: inout [SpeechSegment]) {
        guard let empty = library.api.vad_empty, let front = library.api.vad_front, let pop = library.api.vad_pop,
              let destroy = library.api.vad_destroy_segment else { return }
        while empty(handle) == 0 {
            guard let segment = front(handle) else { break }
            let native = segment.pointee
            let samples = native.samples.map { Array(UnsafeBufferPointer(start: $0, count: Int(native.n))) } ?? []
            segments.append(SpeechSegment(startSample: Int(native.start), samples: samples))
            destroy(segment)
            pop(handle)
        }
    }

    func flush() {
        library.api.vad_flush?(handle)
    }

    func reset() {
        library.api.vad_clear?(handle)
        library.api.vad_reset?(handle)
    }
}
