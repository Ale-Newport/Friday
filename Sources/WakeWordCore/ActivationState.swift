import Foundation
import FridayAudio
import WakeWordKit

/// Why detection is not running although the user wants it.
public enum PauseReason: Hashable, Sendable, Comparable {
    /// The user turned wake-word detection off. All audio and model resources are released.
    case userDisabled
    /// The Mac is asleep (or about to be). Capture stops; the engine stays loaded so waking does
    /// not need the network again.
    case systemSleep
    /// Another user's session is in the foreground (fast user switching); the microphone is theirs.
    case userSessionInactive
    /// There is no microphone to listen to. Waits for one to be connected.
    case noInputDevice

    /// Whether pausing for this reason also unloads the engine's models and native handles.
    public var releasesEngine: Bool { self == .userDisabled }
}

/// A problem that stops detection, with what the UI needs to explain and (if possible) fix it.
public struct DetectorFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case microphonePermission(MicrophoneAuthorization)
        case engine(WakeWordError)
        case audio(AudioCaptureError)
    }

    public var kind: Kind
    public var message: String
    public var recovery: Recovery

    public init(kind: Kind, message: String, recovery: Recovery) {
        self.kind = kind
        self.message = message
        self.recovery = recovery
    }

    public static func microphone(_ authorization: MicrophoneAuthorization) -> DetectorFailure {
        let message: String
        switch authorization {
        case .denied: message = "Microphone access is turned off for Jarvis. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
        case .restricted: message = "Microphone access is restricted on this Mac, so Jarvis can’t listen. Ask the administrator to allow it."
        default: message = "Jarvis needs microphone access to hear its wake word."
        }
        return DetectorFailure(kind: .microphonePermission(authorization), message: message, recovery: .manualRetryOnly)
    }

    public static func engine(_ error: WakeWordError) -> DetectorFailure {
        // The UI shows only this text, so it carries the advice as well as the description.
        let message = [error.errorDescription ?? "\(error)", error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        return DetectorFailure(kind: .engine(error), message: message, recovery: error.recovery)
    }

    public static func audio(_ error: AudioCaptureError) -> DetectorFailure {
        let recovery: Recovery
        switch error {
        case .microphoneNotAuthorized, .noInputDevice, .deviceUnavailable: recovery = .manualRetryOnly
        case .engineFailed: recovery = .retryAutomatically
        }
        return DetectorFailure(kind: .audio(error), message: error.errorDescription ?? "\(error)", recovery: recovery)
    }

    public var isEngineFailure: Bool {
        if case .engine = kind { true } else { false }
    }

    public var isMicrophonePermissionFailure: Bool {
        if case .microphonePermission = kind { true } else { false }
    }
}

/// Identity of one assistant interaction.
public struct ActivationSessionInfo: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let event: WakeWordEvent

    public init(id: UUID = UUID(), event: WakeWordEvent) {
        self.id = id
        self.event = event
    }
}

public enum SessionOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case timedOut
    case failed(String)
}

/// Why a manual activation (hotkey, menu item, microphone button) could not open a session.
public enum ManualActivationFailure: Equatable, Sendable {
    /// Microphone access is denied or restricted, or was refused when the system asked.
    case microphone(MicrophoneAuthorization)
    /// There is no microphone to listen to.
    case noInputDevice
    /// Detection is paused for a reason a key press cannot lift (the Mac is asleep, another user is active).
    case paused(PauseReason)
    /// The microphone could not be opened; the failure says why.
    case detector(DetectorFailure)
    /// The runtime has not been started, or was stopped.
    case notRunning

    init(_ failure: DetectorFailure) {
        switch failure.kind {
        case .microphonePermission(let authorization): self = .microphone(authorization)
        case .audio(.microphoneNotAuthorized(let authorization)): self = .microphone(authorization)
        case .audio(.noInputDevice): self = .noInputDevice
        default: self = .detector(failure)
        }
    }

    init(pause reason: PauseReason) {
        self = reason == .noInputDevice ? .noInputDevice : .paused(reason)
    }
}

/// What came of ``WakeWordRuntime/activateManually()``.
public enum ManualActivationOutcome: Equatable, Sendable {
    /// A session was opened; the assistant is listening.
    case started
    /// A session already exists (the wake word was heard, or an earlier press), so nothing was done.
    case alreadyActive
    case failed(ManualActivationFailure)
}

/// The activation lifecycle:
///
///     initializing ─► listening ─(detected)─► verifying ─► wakeWordVerified ─► activated
///                         ▲                                                       │
///                         └──────────────── commandSession ◄──────────────────────┘
///
/// plus `paused` (not wanted or not possible right now) and `error` (needs attention).
public enum ActivationState: Equatable, Sendable {
    /// Acquiring the microphone and loading the engine.
    case initializing
    /// Idle: the microphone is open and the engine is listening for the wake word.
    case listening
    /// A detection passed the validator; verifiers (if any) are checking it. Normally a few milliseconds.
    case verifying(WakeWordEvent)
    /// The detection is confirmed; the assistant is about to be notified.
    case wakeWordVerified(WakeWordEvent)
    /// The assistant was notified and the confirmation UI is showing.
    case activated(ActivationSessionInfo)
    /// The assistant owns the interaction (command listening, reasoning, speaking …). Detection is gated.
    case commandSession(ActivationSessionInfo)
    case paused(PauseReason)
    case error(DetectorFailure)

    /// Detection is live and nothing else is happening.
    public var isListening: Bool { self == .listening }

    /// A wake word has been accepted and the interaction has not finished yet.
    public var isActivationInProgress: Bool {
        switch self {
        case .verifying, .wakeWordVerified, .activated, .commandSession: true
        default: false
        }
    }

    public var session: ActivationSessionInfo? {
        switch self {
        case .activated(let session), .commandSession(let session): session
        default: nil
        }
    }
}

public enum ActivationEvent: Sendable {
    case engineReady
    /// A detection accepted by the pipeline's validator.
    case detection(WakeWordEvent)
    case verificationPassed
    case verificationRejected(reason: String)
    case activationDispatched(ActivationSessionInfo)
    case commandSessionBegan(id: UUID)
    case sessionEnded(id: UUID, outcome: SessionOutcome)
    case pause(PauseReason)
    case resume
    case failure(DetectorFailure)
    case retry
}

/// What the supervisor must do as a consequence of a transition. The reducer never performs I/O.
public enum ActivationEffect: Equatable, Sendable {
    /// Stop feeding the engine immediately (idempotent).
    case gateDetector
    /// Resume feeding the engine, ignoring detections for `holdoff` seconds of audio.
    case ungateDetector(holdoff: Double)
    case runVerifiers(WakeWordEvent)
    case dispatchActivation(WakeWordEvent)
    /// Cancel the assistant's work for this session.
    case cancelSession(id: UUID, outcome: SessionOutcome)
    case releaseCapture
    case releaseEngine
    /// A detection arrived while not listening and was ignored.
    case recordIgnoredDetection(WakeWordEvent)
    /// Begin acquiring resources (after a pause or an error).
    case acquireResources
}

/// A pure state machine: `handle` computes the next state and the effects; it performs no I/O,
/// starts no timers and reads no clock, so every transition is deterministic and unit-testable.
public struct ActivationStateMachine: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Seconds of audio after a session during which detections are ignored (lets the tail of
        /// synthesised speech die away so Jarvis cannot trigger itself).
        public var postSessionHoldoff: Double
        public init(postSessionHoldoff: Double = 1.0) { self.postSessionHoldoff = postSessionHoldoff }
    }

    public private(set) var state: ActivationState
    public var configuration: Configuration

    public init(state: ActivationState = .initializing, configuration: Configuration = .init()) {
        self.state = state
        self.configuration = configuration
    }

    /// Applies `event`; returns the effects the supervisor must carry out.
    @discardableResult
    public mutating func handle(_ event: ActivationEvent) -> [ActivationEffect] {
        let (next, effects) = Self.reduce(state, event, configuration)
        state = next
        return effects
    }

    public static func reduce(
        _ state: ActivationState,
        _ event: ActivationEvent,
        _ configuration: Configuration
    ) -> (ActivationState, [ActivationEffect]) {
        // Events that mean the same thing in every state.
        switch event {
        case .pause(let reason):
            return pause(from: state, reason: reason)
        case .failure(let failure):
            return fail(from: state, failure: failure)
        case .detection(let detection) where !state.isListening:
            return (state, [.recordIgnoredDetection(detection)])
        default:
            break
        }

        switch (state, event) {
        // MARK: bring-up
        case (.initializing, .engineReady):
            return (.listening, [])

        case (.paused, .resume), (.error, .resume), (.error, .retry):
            return (.initializing, [.acquireResources])

        // MARK: detection → activation
        case (.listening, .detection(let detection)):
            return (.verifying(detection), [.gateDetector, .runVerifiers(detection)])

        case (.verifying(let detection), .verificationPassed):
            return (.wakeWordVerified(detection), [.dispatchActivation(detection)])

        case (.verifying, .verificationRejected):
            return (.listening, [.ungateDetector(holdoff: 0)])

        case (.wakeWordVerified, .activationDispatched(let session)):
            return (.activated(session), [])

        case (.activated(let session), .commandSessionBegan(let id)) where session.id == id:
            return (.commandSession(session), [])

        // MARK: return to idle
        case (.activated(let session), .sessionEnded(let id, _)) where session.id == id,
             (.commandSession(let session), .sessionEnded(let id, _)) where session.id == id:
            return (.listening, [.ungateDetector(holdoff: configuration.postSessionHoldoff)])

        default:
            // Stale or irrelevant (a late `sessionEnded` for an old session, a second `engineReady` …).
            return (state, [])
        }
    }

    private static func pause(from state: ActivationState, reason: PauseReason) -> (ActivationState, [ActivationEffect]) {
        let unloadEngine: [ActivationEffect] = reason.releasesEngine ? [.releaseEngine] : []
        switch state {
        case .paused, .error:
            // Capture should already be released, but in-flight work can have reopened it; releasing is
            // idempotent, so always make sure. The displayed reason (and the engine) can change too.
            return (.paused(reason), [.releaseCapture] + unloadEngine)
        default:
            return (.paused(reason), endSessionEffects(for: state) + [.releaseCapture] + unloadEngine)
        }
    }

    private static func fail(from state: ActivationState, failure: DetectorFailure) -> (ActivationState, [ActivationEffect]) {
        switch state {
        case .paused:
            // A late result from work that was superseded by a pause: ignore it.
            return (state, [])
        case .error:
            return (.error(failure), failure.isEngineFailure ? [.releaseEngine] : [])
        default:
            let effects = endSessionEffects(for: state) + [.releaseCapture] + (failure.isEngineFailure ? [.releaseEngine] : [])
            return (.error(failure), effects)
        }
    }

    private static func endSessionEffects(for state: ActivationState) -> [ActivationEffect] {
        switch state {
        case .activated(let session), .commandSession(let session):
            [.cancelSession(id: session.id, outcome: .cancelled)]
        default:
            []
        }
    }
}
