import Foundation
import WakeWordKit

/// Wake-word detection with Picovoice Porcupine, via the official macOS C library.
///
/// Everything Porcupine-specific lives in this module: the native library, its model and keyword
/// files, its 16-bit input format, its sensitivity semantics and its licensing errors. The rest
/// of the application sees only ``WakeWordEngine``.
public final class PorcupineWakeWordEngine: WakeWordEngine, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var accessKey: String
        public var libraryURL: URL
        public var modelURL: URL
        /// Keywords to listen for, each paired with its `.ppn` file. Order matches Porcupine's indices.
        public var keywords: [(keyword: WakeKeyword, url: URL)]
        /// Normalised sensitivity in `[0, 1]`; Porcupine's native range is the same.
        public var sensitivity: Float
        /// Porcupine device string. `cpu:1` keeps inference on a single thread, which for this tiny
        /// model costs less energy than fanning out or waking the GPU (`best`).
        public var device: String

        public init(
            accessKey: String,
            libraryURL: URL,
            modelURL: URL,
            keywords: [(keyword: WakeKeyword, url: URL)],
            sensitivity: Float = 0.5,
            device: String = "cpu:1"
        ) {
            self.accessKey = accessKey
            self.libraryURL = libraryURL
            self.modelURL = modelURL
            self.keywords = keywords
            self.sensitivity = sensitivity
            self.device = device
        }
    }

    public static let engineID = "porcupine"
    public static let accessKeyCredential = CredentialKey(engineID: engineID, name: "AccessKey")

    public let identifier = PorcupineWakeWordEngine.engineID

    private enum Lifecycle { case created, ready, shutDown }

    private struct State {
        var lifecycle = Lifecycle.created
        /// Resolved once, in `initialize()`: the audio path must not look symbols up (or fail to) per frame.
        var bindings: (any PorcupineBindings)?
        var handle: OpaquePointer?
        var pcm: [Int16] = []
        var requirements = AudioRequirements(sampleRate: 16_000, frameLength: 512)
    }

    private let configuration: Configuration
    private let makeBindings: @Sendable () throws(WakeWordError) -> any PorcupineBindings
    private let state = Protected(State())
    private let sensitivity: Float

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, makeBindings: { () throws(WakeWordError) -> any PorcupineBindings in
            try LibraryBindings.load(from: configuration.libraryURL)
        })
    }

    /// Test seam: supply the native layer.
    init(configuration: Configuration, makeBindings: @escaping @Sendable () throws(WakeWordError) -> any PorcupineBindings) {
        self.configuration = configuration
        self.makeBindings = makeBindings
        self.sensitivity = min(1, max(0, configuration.sensitivity))
    }

    deinit {
        // Defensive: the host is expected to call shutdown(), but never leak a native handle.
        release()
    }

    public var audioRequirements: AudioRequirements { state.withLock { $0.requirements } }

    // MARK: - Lifecycle

    public func initialize() async throws(WakeWordError) {
        let lifecycle = state.withLock { $0.lifecycle }
        switch lifecycle {
        case .shutDown: throw .shutDown
        case .ready: return
        case .created: break
        }

        let bindings = try makeBindings()
        try validateFiles()
        guard !configuration.keywords.isEmpty else {
            throw .invalidConfiguration("no keywords configured")
        }
        let secret = configuration.accessKey
        guard !secret.isEmpty else { throw .credentialMissing(Self.accessKeyCredential) }
        guard bindings.sampleRate > 0, bindings.frameLength > 0 else {
            throw .engineUnavailable("the library reported unusable audio parameters")
        }

        // Initialisation validates the licence (network) and loads the model: keep it off the
        // cooperative thread pool so a slow connection can never stall unrelated async work.
        let configuration = self.configuration
        let sensitivities = [Float](repeating: sensitivity, count: configuration.keywords.count)
        let outcome: Result<HandleBox, NativeFailure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(NativeFailure) {
                    let handle = try bindings.makeHandle(
                        accessKey: configuration.accessKey,
                        modelPath: configuration.modelURL.path,
                        device: configuration.device,
                        keywordPaths: configuration.keywords.map(\.url.path),
                        sensitivities: sensitivities
                    )
                    continuation.resume(returning: .success(HandleBox(handle: handle)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch outcome {
        case .failure(let failure):
            throw PorcupineErrorMapping.map(failure, credential: Self.accessKeyCredential, secrets: [secret])
        case .success(let box):
            let requirements = AudioRequirements(sampleRate: bindings.sampleRate, frameLength: bindings.frameLength)
            let accepted: Bool = state.withLock { state in
                // A concurrent shutdown() while we were initialising wins; release what we built.
                guard state.lifecycle == .created else { return false }
                state.bindings = bindings
                state.handle = box.handle
                state.requirements = requirements
                state.pcm = [Int16](repeating: 0, count: requirements.frameLength)
                state.lifecycle = .ready
                return true
            }
            if !accepted {
                bindings.destroy(handle: box.handle)
                throw .shutDown
            }
        }
    }

    public func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult? {
        let secret = configuration.accessKey
        let keywords = configuration.keywords
        return try state.withLock { (state) throws(WakeWordError) -> DetectionResult? in
            switch state.lifecycle {
            case .created: throw .notInitialized
            case .shutDown: throw .shutDown
            case .ready: break
            }
            guard let handle = state.handle, let bindings = state.bindings else { throw .notInitialized }
            let required = state.requirements
            guard frame.samples.count == required.frameLength else {
                throw .invalidFrame(expected: required.frameLength, actual: frame.samples.count)
            }
            guard frame.sampleRate == required.sampleRate else {
                throw .invalidConfiguration("frame sample rate \(frame.sampleRate) ≠ \(required.sampleRate)")
            }

            frame.copyInt16Samples(into: &state.pcm)
            let index: Int32
            do throws(NativeFailure) {
                index = try state.pcm.withUnsafeBufferPointer { buffer throws(NativeFailure) -> Int32 in
                    try bindings.process(handle: handle, pcm: buffer.baseAddress!)
                }
            } catch {
                throw .processingFailed(PorcupineErrorMapping.describe(error, secrets: [secret]))
            }
            guard index >= 0 else { return nil }
            guard Int(index) < keywords.count else {
                throw .processingFailed("engine reported keyword index \(index) but only \(keywords.count) are loaded")
            }
            return DetectionResult(keyword: keywords[Int(index)].keyword, confidence: nil)
        }
    }

    /// Porcupine fixes its sensitivities at construction, so a change means building a new engine;
    /// the runtime does that and swaps it in without interrupting audio.
    public func updateSensitivity(_ value: Float) throws(WakeWordError) {
        guard (0...1).contains(value) else { throw .invalidConfiguration("sensitivity \(value) is outside 0...1") }
        throw .requiresReinitialization
    }

    public func shutdown() {
        release()
    }

    // MARK: - Helpers

    /// Marks the engine shut down and destroys the native handle, once. (`processAudio` holds the same lock
    /// for the whole native call, so a handle is never destroyed while it is being used.)
    private func release() {
        let owned = state.withLock { state -> (handle: OpaquePointer, bindings: any PorcupineBindings)? in
            defer {
                state.handle = nil
                state.bindings = nil
                state.lifecycle = .shutDown
            }
            guard let handle = state.handle, let bindings = state.bindings else { return nil }
            return (handle, bindings)
        }
        if let owned { owned.bindings.destroy(handle: owned.handle) }
    }

    private func validateFiles() throws(WakeWordError) {
        let fileManager = FileManager.default
        var missing: [String] = []
        if !fileManager.fileExists(atPath: configuration.modelURL.path) { missing.append(configuration.modelURL.lastPathComponent) }
        for (_, url) in configuration.keywords where !fileManager.fileExists(atPath: url.path) {
            missing.append(url.lastPathComponent)
        }
        if !missing.isEmpty {
            throw .engineUnavailable("missing file(s): \(missing.joined(separator: ", "))")
        }
    }
}

/// `OpaquePointer` is not `Sendable`; the box documents that ownership is handed over exactly once.
private struct HandleBox: @unchecked Sendable {
    let handle: OpaquePointer
}
