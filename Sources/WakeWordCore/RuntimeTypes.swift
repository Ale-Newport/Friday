import Foundation
import FridayAudio
import WakeWordKit

/// Everything the user can configure that affects detection. Engine-independent: nothing here
/// mentions a particular engine's parameters.
public struct RuntimeSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var engineID: String
    /// `0…1`: 0 favours fewer false activations, 1 favours fewer misses. Each engine maps it to its own scale.
    public var sensitivity: Float
    public var input: AudioInputSelection
    /// Seconds after an activation during which further detections are ignored.
    public var cooldown: Double
    /// Detections closer together than this are treated as one utterance.
    public var debounceWindow: Double
    /// Seconds of audio after a session ends during which detections are ignored.
    public var postSessionHoldoff: Double
    /// A session still running after this long is cancelled and detection resumes.
    public var maxSessionDuration: Double
    public var sessionAudioPolicy: SessionAudioPolicy
    public var developerMode: Bool

    public init(
        isEnabled: Bool = true,
        engineID: String,
        sensitivity: Float = 0.5,
        input: AudioInputSelection = .systemDefault,
        cooldown: Double = 2.0,
        debounceWindow: Double = 0.6,
        postSessionHoldoff: Double = 1.0,
        maxSessionDuration: Double = 60,
        sessionAudioPolicy: SessionAudioPolicy = .gateDetector,
        developerMode: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.engineID = engineID
        self.sensitivity = sensitivity
        self.input = input
        self.cooldown = cooldown
        self.debounceWindow = debounceWindow
        self.postSessionHoldoff = postSessionHoldoff
        self.maxSessionDuration = maxSessionDuration
        self.sessionAudioPolicy = sessionAudioPolicy
        self.developerMode = developerMode
    }
}

/// Which engine is loaded right now.
public struct ActiveEngine: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var sensitivity: Float
}

/// Everything the UI needs, as one value. Published whenever any part changes.
public struct RuntimeSnapshot: Equatable, Sendable {
    public var state: ActivationState
    public var settings: RuntimeSettings
    public var microphone: MicrophoneAuthorization
    public var engine: ActiveEngine?
    /// The microphone actually in use (may differ from the selection when a fallback applies).
    public var capture: AudioCaptureInfo?
    public var assistantPhase: AssistantPhase?
    /// A non-fatal explanation worth showing ("Selected microphone unavailable; using the system default").
    public var notice: String?
    /// When the next automatic retry happens, if one is scheduled.
    public var retryAt: Date?
    /// Increases with every published snapshot.
    public var revision: Int

    /// What the UI shows before the runtime has published anything.
    public static func initial(settings: RuntimeSettings, microphone: MicrophoneAuthorization) -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .initializing, settings: settings, microphone: microphone, engine: nil, capture: nil,
            assistantPhase: nil, notice: nil, retryAt: nil, revision: 0
        )
    }
}

/// Things that happened, for diagnostics and accuracy testing. Contains no audio and no secrets.
public enum RuntimeEvent: Sendable {
    case stateChanged(from: ActivationState, to: ActivationState)
    /// The pipeline accepted a detection (whether or not the assistant was then activated).
    case detectionAccepted(WakeWordEvent)
    case detectionSuppressed(keyword: WakeKeyword, reason: DetectionValidator.Rejection, at: HostTime)
    /// A detection arrived while the runtime was not listening and was ignored.
    case detectionIgnored(WakeWordEvent)
    case verificationRejected(WakeWordEvent, reason: String)
    /// The assistant was notified. `audioToDispatch` is the time from the end of the audio that
    /// completed the keyword until the handler was invoked.
    case activationDispatched(WakeWordEvent, session: UUID, audioToDispatch: Double)
    case sessionEnded(session: UUID, outcome: SessionOutcome)
    case engineLoaded(id: String, duration: Double)
    case engineFailed(WakeWordError)
    case captureStarted(AudioCaptureInfo)
    case captureStopped
    case notice(String)
}

/// A claim on the runtime's accuracy-test mode (see ``WakeWordRuntime/enterAccuracyTestMode(cooldown:)``). Whoever holds one gives it back
/// with ``WakeWordRuntime/leaveAccuracyTestMode(_:)``; no one else can end it.
public struct AccuracyTestLease: Sendable, Hashable {
    let id: Int
}

/// How a request to rebuild the engine from the files it reads came out (see ``WakeWordRuntime/reloadEngine()``).
public enum EngineReload: Sendable, Equatable {
    /// An engine built from the files as they are now is loaded.
    case loaded
    /// The engine could not be built from them (the reason is for the person). What was running is gone and the runtime is in its
    /// usual failure state, retrying where retrying can help.
    case failed(String)
    /// Nothing was rebuilt: the app is not listening (paused, no microphone access, shutting down…). The engine is built from the files
    /// whenever listening resumes.
    case notListening
}

public enum SystemEvent: Equatable, Sendable {
    case willSleep
    case didWake
    /// Another user's session took over the console (fast user switching).
    case userSessionDidResignActive
    case userSessionDidBecomeActive
    case applicationDidBecomeActive
}

/// Source of sleep/wake and session notifications. Implemented with `NSWorkspace` in the app.
public protocol SystemEventSource: Sendable {
    func events() -> AsyncStream<SystemEvent>
}

/// A source that never emits (for tools and tests that do not care).
public struct NoSystemEvents: SystemEventSource {
    public init() {}
    public func events() -> AsyncStream<SystemEvent> { AsyncStream { $0.finish() } }
}

/// Whether the Mac has a usable network route. Engines that validate a licence online fail in the same
/// way for "offline" and "rejected", so the runtime asks this to tell them apart, and retries as soon as
/// connectivity returns instead of waiting out a back-off timer. Event-driven; implemented with
/// `NWPathMonitor` in the app.
public protocol NetworkAvailability: Sendable {
    var isOnline: Bool { get }
    /// Emits `true` / `false` whenever reachability changes.
    func changes() -> AsyncStream<Bool>
}

/// Assumes the network is always there (tools and tests that do not care).
public struct AlwaysOnline: NetworkAvailability {
    public init() {}
    public var isOnline: Bool { true }
    public func changes() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

/// Delays used by the supervisor. Tests shrink them; the defaults are tuned for real hardware.
public struct RuntimeTimings: Sendable {
    /// Collapses bursts of route-change notifications into one capture restart.
    public var captureRestartDebounce: Duration
    /// After wake from sleep, wait for audio devices to reappear before reopening the microphone.
    public var wakeSettleDelay: Duration
    /// Delays before automatic retries after a transient failure (the last value repeats).
    public var retryBackoff: [Duration]
    /// How long a verifier may take before its decision is treated as "reject".
    public var verifierTimeout: Duration
    /// More capture restarts than this within `restartWindow` is treated as a failure, not a hiccup.
    public var maxRestartsInWindow: Int
    public var restartWindow: Duration
    /// When the chosen microphone failed to open and the system default took over, the chosen one is tried again
    /// after each of these delays — and then left alone (each try briefly interrupts listening). Devices
    /// appearing or disappearing also trigger a try, so a microphone that is simply unplugged needs no timer.
    public var preferredInputRetry: [Duration]
    /// A failure that comes after the detector has run this long without one starts the retry back-off over;
    /// one that comes sooner continues it, so an engine that loads and then faults at once is not rebuilt every 5 s.
    public var stableAfter: Duration

    public init(
        captureRestartDebounce: Duration = .milliseconds(300),
        wakeSettleDelay: Duration = .seconds(1),
        retryBackoff: [Duration] = [.seconds(5), .seconds(15), .seconds(45), .seconds(120), .seconds(300)],
        verifierTimeout: Duration = .seconds(2),
        maxRestartsInWindow: Int = 6,
        restartWindow: Duration = .seconds(30),
        preferredInputRetry: [Duration] = [.seconds(10), .seconds(60), .seconds(300)],
        stableAfter: Duration = .seconds(60)
    ) {
        self.captureRestartDebounce = captureRestartDebounce
        self.wakeSettleDelay = wakeSettleDelay
        self.retryBackoff = retryBackoff
        self.verifierTimeout = verifierTimeout
        self.maxRestartsInWindow = maxRestartsInWindow
        self.restartWindow = restartWindow
        self.preferredInputRetry = preferredInputRetry
        self.stableAfter = stableAfter
    }
}

/// Everything the runtime needs from its environment. Each member is a protocol or value so a
/// test can substitute a deterministic double.
public struct RuntimeDependencies: Sendable {
    public var registry: WakeWordEngineRegistry
    public var credentials: any CredentialReading
    public var resources: EngineResourceLocator
    public var capture: any AudioCaptureSource
    public var devices: any AudioDeviceProviding
    public var permission: any MicrophonePermissionProviding
    public var systemEvents: any SystemEventSource
    public var network: any NetworkAvailability
    public var assistant: any AssistantActivationHandler
    public var verifiers: [any DetectionVerifier]
    public var clock: any Clock<Duration>
    public var timings: RuntimeTimings

    public init(
        registry: WakeWordEngineRegistry,
        credentials: any CredentialReading,
        resources: EngineResourceLocator = EngineResourceLocator(),
        capture: any AudioCaptureSource,
        devices: any AudioDeviceProviding,
        permission: any MicrophonePermissionProviding,
        systemEvents: any SystemEventSource = NoSystemEvents(),
        network: any NetworkAvailability = AlwaysOnline(),
        assistant: any AssistantActivationHandler = NoopAssistant(),
        verifiers: [any DetectionVerifier] = [],
        clock: any Clock<Duration> = ContinuousClock(),
        timings: RuntimeTimings = RuntimeTimings()
    ) {
        self.registry = registry
        self.credentials = credentials
        self.resources = resources
        self.capture = capture
        self.devices = devices
        self.permission = permission
        self.systemEvents = systemEvents
        self.network = network
        self.assistant = assistant
        self.verifiers = verifiers
        self.clock = clock
        self.timings = timings
    }
}
