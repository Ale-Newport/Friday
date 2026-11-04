import Foundation

/// Extension point for a second-stage check after the engine and validator have accepted a
/// detection — for example speaker verification, or a cheap "was this really addressed to me"
/// classifier. Nothing in the application ships a verifier today; the hook exists so adding one
/// never requires touching the audio pipeline or the activation flow.
///
/// Privacy: the pipeline retains audio history **only** when a verifier asks for it
/// (`requiredPreRoll > 0`), keeps it in memory, and releases it as soon as the decision is made.
public protocol DetectionVerifier: Sendable {
    /// Seconds of audio, ending at the detection, the verifier needs. Zero means none is kept.
    var requiredPreRoll: Double { get }

    func verify(_ context: VerificationContext) async -> VerificationDecision
}

public struct VerificationContext: Sendable {
    public let event: WakeWordEvent
    /// Mono samples ending at the detection, at `sampleRate`; `nil` when no pre-roll was requested.
    public let preRoll: [Float]?
    public let sampleRate: Int

    public init(event: WakeWordEvent, preRoll: [Float]?, sampleRate: Int) {
        self.event = event
        self.preRoll = preRoll
        self.sampleRate = sampleRate
    }
}

public enum VerificationDecision: Equatable, Sendable {
    case accept
    case reject(reason: String)
}
