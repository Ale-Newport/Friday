import Foundation

/// A scriptable engine for automated tests and for hardware-free checks of the whole activation
/// flow. It performs no speech recognition.
///
/// * **Scripted**: report a detection on chosen frame numbers, fail on demand, take time to
///   initialise, or record every call so tests can assert on the lifecycle.
/// * **Loudness trigger** (developer mode): reports "Jarvis" when the microphone level stays above
///   a threshold for a few frames — clap, or say anything loudly — so you can verify the real
///   microphone → pipeline → state machine → HUD path without an AccessKey. Sensitivity moves the
///   threshold.
public final class MockWakeWordEngine: WakeWordEngine, @unchecked Sendable {
    public static let engineID = "mock"

    public struct Behavior: Sendable {
        public var requirements = AudioRequirements(sampleRate: 16_000, frameLength: 512)
        public var keyword = WakeKeyword.jarvis
        /// Zero-based indices (counting every processed frame) at which a detection is reported.
        public var detectAtFrames: Set<Int> = []
        /// Report a detection on every Nth frame (0 = never).
        public var detectEveryNthFrame = 0
        public var confidence: Float?
        public var initializeDelay: Duration = .zero
        public var initializeError: WakeWordError?
        /// Fail every frame from this frame index on with the given error.
        public var failFromFrame: (index: Int, error: WakeWordError)?
        public var supportsLiveSensitivity = true
        public var loudnessTrigger: LoudnessTrigger?

        public init() {}
    }

    public struct LoudnessTrigger: Sendable {
        /// Consecutive loud frames required.
        public var consecutiveFrames = 3
        public init(consecutiveFrames: Int = 3) { self.consecutiveFrames = consecutiveFrames }
    }

    /// A record of everything the host did to the engine.
    public struct CallLog: Equatable, Sendable {
        public var initializeCalls = 0
        public var processCalls = 0
        public var shutdownCalls = 0
        public var sensitivityUpdates: [Float] = []
    }

    private enum Lifecycle { case created, ready, shutDown }

    private struct State {
        var lifecycle = Lifecycle.created
        var log = CallLog()
        var framesSeen = 0
        var triggerCountdown: Int?
        var sensitivity: Float
        var loudFrames = 0
    }

    public let identifier: String
    private let behavior: Behavior
    private let state: Protected<State>

    public init(behavior: Behavior = Behavior(), sensitivity: Float = 0.5, identifier: String = MockWakeWordEngine.engineID) {
        self.identifier = identifier
        self.behavior = behavior
        self.state = Protected(State(sensitivity: sensitivity))
    }

    public var audioRequirements: AudioRequirements { behavior.requirements }

    public var callLog: CallLog { state.withLock { $0.log } }
    public var currentSensitivity: Float { state.withLock { $0.sensitivity } }
    public var isShutDown: Bool { state.withLock { $0.lifecycle == .shutDown } }

    /// The next processed frame reports a detection (or, with `afterFrames: n`, the (n+1)-th from now).
    public func trigger(afterFrames: Int = 0) {
        state.withLock { $0.triggerCountdown = max(0, afterFrames) }
    }

    public func initialize() async throws(WakeWordError) {
        let lifecycle = state.withLock { state -> Lifecycle in
            state.log.initializeCalls += 1
            return state.lifecycle
        }
        guard lifecycle != .shutDown else { throw .shutDown }
        if behavior.initializeDelay > .zero {
            try? await Task.sleep(for: behavior.initializeDelay)
        }
        if let error = behavior.initializeError { throw error }
        state.withLock { $0.lifecycle = .ready }
    }

    public func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult? {
        let behavior = self.behavior
        let outcome: Result<Bool, WakeWordError> = state.withLock { state in
            switch state.lifecycle {
            case .created: return .failure(.notInitialized)
            case .shutDown: return .failure(.shutDown)
            case .ready: break
            }
            guard frame.samples.count == behavior.requirements.frameLength else {
                return .failure(.invalidFrame(expected: behavior.requirements.frameLength, actual: frame.samples.count))
            }
            state.log.processCalls += 1
            let index = state.framesSeen
            state.framesSeen += 1

            if let failure = behavior.failFromFrame, index >= failure.index {
                return .failure(failure.error)
            }
            var detected = behavior.detectAtFrames.contains(index)
            if behavior.detectEveryNthFrame > 0 && (index + 1) % behavior.detectEveryNthFrame == 0 { detected = true }
            if let countdown = state.triggerCountdown {
                if countdown == 0 {
                    state.triggerCountdown = nil
                    detected = true
                } else {
                    state.triggerCountdown = countdown - 1
                }
            }
            if let trigger = behavior.loudnessTrigger {
                let threshold = Self.loudnessThreshold(sensitivity: state.sensitivity)
                var sumSquares: Float = 0
                for sample in frame.samples { sumSquares += sample * sample }
                let rms = (sumSquares / Float(max(1, frame.samples.count))).squareRoot()
                state.loudFrames = rms > threshold ? state.loudFrames + 1 : 0
                if state.loudFrames >= trigger.consecutiveFrames {
                    state.loudFrames = 0
                    detected = true
                }
            }
            return .success(detected)
        }
        switch outcome {
        case .failure(let error): throw error
        case .success(let detected):
            return detected ? DetectionResult(keyword: behavior.keyword, confidence: behavior.confidence) : nil
        }
    }

    public func updateSensitivity(_ value: Float) throws(WakeWordError) {
        guard behavior.supportsLiveSensitivity else { throw .requiresReinitialization }
        guard (0...1).contains(value) else { throw .invalidConfiguration("sensitivity \(value) is outside 0...1") }
        state.withLock {
            $0.sensitivity = value
            $0.log.sensitivityUpdates.append(value)
        }
    }

    public func shutdown() {
        state.withLock {
            $0.lifecycle = .shutDown
            $0.log.shutdownCalls += 1
        }
    }

    /// RMS threshold in linear amplitude: -12 dBFS at sensitivity 0 (shout) down to -40 dBFS at 1.
    static func loudnessThreshold(sensitivity: Float) -> Float {
        let decibels = -12 - 28 * min(1, max(0, sensitivity))
        return powf(10, decibels / 20)
    }
}

extension MockWakeWordEngine {
    /// Registry entry for the mock. Developer-only: it is hidden from the engine picker unless
    /// developer mode is enabled.
    public static func descriptor(
        displayName: String = "Mock (loudness trigger — testing only)",
        behavior: @escaping @Sendable () -> Behavior = {
            var behavior = Behavior()
            behavior.loudnessTrigger = LoudnessTrigger()
            return behavior
        }
    ) -> EngineDescriptor {
        EngineDescriptor(
            id: MockWakeWordEngine.engineID,
            displayName: displayName,
            summary: "Does not recognise speech. Activates when the microphone level stays high for a moment, "
                + "so the whole activation flow can be tested without an AccessKey.",
            capabilities: EngineCapabilities(supportsLiveSensitivity: true, reportsConfidence: false),
            isDeveloperOnly: true,
            makeEngine: { environment in
                MockWakeWordEngine(behavior: behavior(), sensitivity: environment.sensitivity)
            }
        )
    }
}
