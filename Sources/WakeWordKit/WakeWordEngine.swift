import Foundation

/// A wake word the application can listen for. The application owns the vocabulary; each engine
/// maps a keyword to its own model asset (a `.ppn` file, an ONNX head, a Core ML package …).
public struct WakeKeyword: Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// The standalone word "Jarvis" — not "Hey Jarvis".
    public static let jarvis = WakeKeyword(id: "jarvis", displayName: "Jarvis")
}

/// What an engine reports when it spots a keyword in a frame. Deliberately minimal: timing,
/// engine identity and sequence numbers are added by the pipeline (see `WakeWordEvent`).
public struct DetectionResult: Equatable, Sendable {
    public let keyword: WakeKeyword
    /// Engine confidence in `[0, 1]`, or `nil` when the engine does not expose a score
    /// (Porcupine reports only that a keyword occurred).
    public let confidence: Float?

    public init(keyword: WakeKeyword, confidence: Float? = nil) {
        self.keyword = keyword
        self.confidence = confidence
    }
}

/// A wake-word detector backend.
///
/// ### Contract
/// * Lifecycle: `initialize()` once → any number of `processAudio` calls → `shutdown()`. After
///   `shutdown()` an instance is dead; create another one.
/// * Threading: the host (``WakeWordPipeline``) serialises `processAudio`. `updateSensitivity` and
///   `shutdown` may arrive from other threads, but never concurrently with `processAudio` — the
///   pipeline holds its lock around all three. Implementations therefore need no internal
///   locking for those, but must be `Sendable` so the instance can cross isolation domains.
/// * `processAudio` is called roughly `sampleRate / frameLength` times per second on a
///   high-priority audio thread. It must not block on I/O, take unbounded time or allocate
///   noticeably.
/// * All failures are reported as ``WakeWordError``.
public protocol WakeWordEngine: AnyObject, Sendable {
    /// Stable identifier, matching the ``EngineDescriptor`` it was created from.
    var identifier: String { get }

    /// What this engine needs from the audio pipeline. Valid after `initialize()` returns.
    var audioRequirements: AudioRequirements { get }

    /// Loads models, validates licences and allocates native resources. May perform I/O and, for
    /// licensed engines, network access. Never called on the audio thread.
    func initialize() async throws(WakeWordError)

    /// Processes exactly one frame (`audioRequirements.frameLength` samples at
    /// `audioRequirements.sampleRate`). Returns a detection when a keyword ended within the frame.
    func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult?

    /// Applies a normalised sensitivity in `[0, 1]` (0 = fewest false activations, 1 = fewest
    /// misses). Each engine maps this onto its native control (a threshold, a Porcupine
    /// sensitivity …). Must return quickly. Engines that cannot change sensitivity in place throw
    /// ``WakeWordError/requiresReinitialization``; the runtime then builds a replacement engine
    /// with the new value and swaps it in without interrupting the microphone.
    func updateSensitivity(_ value: Float) throws(WakeWordError)

    /// Releases every native resource. Idempotent.
    func shutdown()
}
