import Foundation

/// Decides whether a raw engine detection becomes an activation.
///
/// Three independent protections against repeated or spurious triggers, all measured on the
/// *audio* timeline (frame capture times) so behaviour is deterministic and independent of thread
/// scheduling or processing delays:
///
/// 1. **Leading-edge debounce** – an engine may fire on several consecutive frames for one
///    utterance. The first detection passes; any detection within `debounceWindow` of the previous
///    *raw* detection is treated as the same utterance (and keeps extending the window while the
///    engine keeps firing).
/// 2. **Cooldown** – after an accepted detection, everything is ignored for `cooldown` seconds.
/// 3. **Holdoff** – an externally imposed quiet period (used after an assistant session so that the
///    tail of its synthesised speech cannot retrigger the detector).
///
/// Keyword and confidence filters complete the picture: a multi-keyword engine can never activate
/// Jarvis with a different word.
public struct DetectionValidator: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Seconds after an accepted detection during which all detections are ignored.
        public var cooldown: Double
        /// Detections closer than this to the previous raw detection are one utterance.
        public var debounceWindow: Double
        /// Keyword ids that may activate the assistant; `nil` accepts any.
        public var acceptedKeywords: Set<String>?
        /// Detections scoring below this are ignored (only applies when the engine reports one).
        public var minimumConfidence: Float?

        public init(
            cooldown: Double = 2.0,
            debounceWindow: Double = 0.6,
            acceptedKeywords: Set<String>? = [WakeKeyword.jarvis.id],
            minimumConfidence: Float? = nil
        ) {
            self.cooldown = cooldown
            self.debounceWindow = debounceWindow
            self.acceptedKeywords = acceptedKeywords
            self.minimumConfidence = minimumConfidence
        }
    }

    public enum Rejection: Equatable, Sendable {
        case unexpectedKeyword(String)
        case lowConfidence(Float)
        case holdoff(remaining: Double)
        case debounced
        case cooldown(remaining: Double)
    }

    public enum Verdict: Equatable, Sendable {
        case accept
        case reject(Rejection)
    }

    public var configuration: Configuration

    private var lastRawDetection: HostTime?
    private var lastAccepted: HostTime?
    private var holdoffUntil: HostTime?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Evaluates a detection that occurred at `time` (the capture time of its frame).
    public mutating func evaluate(_ result: DetectionResult, at time: HostTime) -> Verdict {
        if let accepted = configuration.acceptedKeywords, !accepted.contains(result.keyword.id) {
            return .reject(.unexpectedKeyword(result.keyword.id))
        }
        if let minimum = configuration.minimumConfidence, let confidence = result.confidence, confidence < minimum {
            return .reject(.lowConfidence(confidence))
        }
        if let until = holdoffUntil {
            if time < until {
                return .reject(.holdoff(remaining: until.seconds(since: time)))
            }
            holdoffUntil = nil
        }
        if let previous = lastRawDetection, time.seconds(since: previous) < configuration.debounceWindow {
            lastRawDetection = time
            return .reject(.debounced)
        }
        lastRawDetection = time
        if let accepted = lastAccepted {
            let elapsed = time.seconds(since: accepted)
            if elapsed < configuration.cooldown {
                return .reject(.cooldown(remaining: configuration.cooldown - elapsed))
            }
        }
        lastAccepted = time
        return .accept
    }

    /// Ignores every detection until `time`.
    public mutating func beginHoldoff(until time: HostTime) {
        holdoffUntil = time
    }

    /// Forgets all history (cooldown, debounce, holdoff). The configuration is kept.
    public mutating func reset() {
        lastRawDetection = nil
        lastAccepted = nil
        holdoffUntil = nil
    }
}
