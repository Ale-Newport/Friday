import Foundation
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

// MARK: - Deterministic clock

/// A clock that only moves when the test says so. Sleepers wake when `advance(by:)` passes their
/// deadline, so timeouts, back-off and debounce can be tested without real waiting.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Hashable {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
    }

    private let state = Protected(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case wake, cancel, parked }
                let outcome = state.withLock { state -> Outcome in
                    if deadline <= state.now { return .wake }
                    if Task.isCancelled { return .cancel }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .parked
                }
                switch outcome {
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed (earliest first).
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let ready = state.sleepers.filter { $0.deadline <= state.now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { sleeper in ready.contains { $0.id == sleeper.id } }
            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

// MARK: - Waiting

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` (yielding between checks) until it holds or `timeout` passes.
func eventually(
    _ what: String = "condition", timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw TimedOut(what: what)
}

extension WakeWordRuntime {
    /// Waits until a published snapshot satisfies `predicate`; returns it.
    @discardableResult
    func waitForSnapshot(
        _ what: String, timeout: Duration = .seconds(5), where predicate: @escaping @Sendable (RuntimeSnapshot) -> Bool
    ) async throws -> RuntimeSnapshot {
        let stream = snapshots()
        return try await withThrowingTaskGroup(of: RuntimeSnapshot.self) { group in
            group.addTask {
                for await snapshot in stream where predicate(snapshot) { return snapshot }
                throw TimedOut(what: "\(what) (stream ended)")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut(what: what)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func waitForState(_ description: String, timeout: Duration = .seconds(5), _ predicate: @escaping @Sendable (ActivationState) -> Bool) async throws {
        try await waitForSnapshot(description, timeout: timeout) { predicate($0.state) }
    }
}

// MARK: - Fakes

final class FakePermission: MicrophonePermissionProviding, @unchecked Sendable {
    private let state: Protected<(status: MicrophoneAuthorization, grantOnRequest: Bool, requests: Int)>

    init(_ status: MicrophoneAuthorization = .authorized, grantOnRequest: Bool = true) {
        state = Protected((status, grantOnRequest, 0))
    }

    var requests: Int { state.withLock { $0.requests } }
    func set(_ status: MicrophoneAuthorization) { state.withLock { $0.status = status } }
    func status() -> MicrophoneAuthorization { state.withLock { $0.status } }
    func request() async -> MicrophoneAuthorization {
        state.withLock { state in
            state.requests += 1
            if state.status == .notDetermined { state.status = state.grantOnRequest ? .authorized : .denied }
            return state.status
        }
    }
}

final class FakeDevices: AudioDeviceProviding, @unchecked Sendable {
    private let list: Protected<[AudioInputDevice]>
    private let broadcaster = Broadcaster<AudioDeviceChange>()

    init(_ devices: [AudioInputDevice] = [FakeDevices.builtIn]) { list = Protected(devices) }

    static let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Microphone", transport: .builtIn, inputChannelCount: 1)
    static let usb = AudioInputDevice(uid: "usb-1", name: "USB Mic", transport: .usb, inputChannelCount: 1)

    func inputDevices() -> [AudioInputDevice] { list.get() }
    func defaultInputDevice() -> AudioInputDevice? { list.withLock { $0.first } }
    func changes() -> AsyncStream<AudioDeviceChange> { broadcaster.stream() }

    func set(_ devices: [AudioInputDevice], emitting change: AudioDeviceChange? = .deviceListChanged) {
        list.withLock { $0 = devices }
        if let change { broadcaster.send(change) }
    }
}

final class FakeNetwork: NetworkAvailability, @unchecked Sendable {
    private let online: Protected<Bool>
    private let broadcaster = Broadcaster<Bool>()
    init(online: Bool = true) { self.online = Protected(online) }
    var isOnline: Bool { online.get() }
    func changes() -> AsyncStream<Bool> { broadcaster.stream() }
    func set(_ value: Bool) {
        online.withLock { $0 = value }
        broadcaster.send(value)
    }
}

final class FakeSystemEvents: SystemEventSource, @unchecked Sendable {
    private let broadcaster = Broadcaster<SystemEvent>()
    func events() -> AsyncStream<SystemEvent> { broadcaster.stream() }
    func send(_ event: SystemEvent) { broadcaster.send(event) }
}

/// Records what the assistant was asked to do and lets the test decide how the interaction ends.
final class RecordingAssistant: AssistantActivationHandler, @unchecked Sendable {
    enum Behavior: Sendable {
        /// Returns immediately.
        case immediate
        /// Begins the command, then waits until released (or cancelled).
        case holdUntilReleased
        /// Ignores cancellation: sleeps in the real clock for this long.
        case stubborn(Duration)
    }

    struct Call: Sendable {
        let event: WakeWordEvent
        let session: ActivationSession
    }

    private struct State {
        var calls: [Call] = []
        var cancelled = 0
        var released = false
        var phases: [AssistantPhase] = []
    }
    private let state = Protected(State())
    var behavior: Behavior

    init(_ behavior: Behavior = .immediate) { self.behavior = behavior }

    var calls: [Call] { state.withLock { $0.calls } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }
    func release() { state.withLock { $0.released = true } }

    func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {
        state.withLock { $0.calls.append(Call(event: event, session: session)) }
        session.beginCommand()
        switch behavior {
        case .immediate:
            return
        case .holdUntilReleased:
            while !state.withLock({ $0.released }) {
                if Task.isCancelled {
                    state.withLock { $0.cancelled += 1 }
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        case .stubborn(let duration):
            try? await Task.sleep(for: duration)
        }
    }
}

struct ScriptedVerifier: DetectionVerifier {
    var requiredPreRoll: Double = 0
    var decision: VerificationDecision = .accept
    var delay: Duration = .zero
    var clock: (any Clock<Duration>)?

    func verify(_ context: VerificationContext) async -> VerificationDecision {
        if delay > .zero {
            if let clock { try? await clock.sleep(for: delay) } else { try? await Task.sleep(for: delay) }
        }
        return decision
    }
}

/// A capture source whose `stop()` first delivers in-flight audio — exactly what a tap callback that is
/// already running can do while the owner is closing the microphone.
final class RacingCapture: AudioCaptureSource, @unchecked Sendable {
    let inner = SyntheticAudioSource()
    private let armed = Protected<(() -> Void)?>(nil)
    func arm(_ body: @escaping () -> Void) { armed.withLock { $0 = body } }
    var isRunning: Bool { inner.isRunning }
    func events() -> AsyncStream<AudioCaptureEvent> { inner.events() }
    @discardableResult
    func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        try inner.start(input: input, handler: handler)
    }
    func stop() {
        let body = armed.withLock { state -> (() -> Void)? in
            let current = state
            state = nil
            return current
        }
        body?()
        inner.stop()
    }
}

/// A capture source whose notifications can be held back — reproducing the real-world ordering "the source stopped
/// itself, the owner reopened it, and only then did the news of the first stop arrive".
final class LateEventCapture: AudioCaptureSource, @unchecked Sendable {
    let inner = SyntheticAudioSource()
    private let broadcaster = Broadcaster<AudioCaptureEvent>()
    private let gate = Protected<(holding: Bool, held: [AudioCaptureEvent])>((false, []))
    private var forwarder: Task<Void, Never>?

    init() {
        let stream = inner.events()
        forwarder = Task { [weak self] in
            for await event in stream { self?.deliver(event) }
        }
    }

    deinit { forwarder?.cancel() }

    func holdEvents() { gate.withLock { $0.holding = true } }

    func releaseEvents() {
        let events = gate.withLock { state -> [AudioCaptureEvent] in
            state.holding = false
            defer { state.held.removeAll() }
            return state.held
        }
        for event in events { broadcaster.send(event) }
    }

    private func deliver(_ event: AudioCaptureEvent) {
        let held = gate.withLock { state -> Bool in
            guard state.holding else { return false }
            state.held.append(event)
            return true
        }
        if !held { broadcaster.send(event) }
    }

    var isRunning: Bool { inner.isRunning }
    func events() -> AsyncStream<AudioCaptureEvent> { broadcaster.stream() }
    @discardableResult
    func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        try inner.start(input: input, handler: handler)
    }
    func stop() { inner.stop() }
}

/// A verifier that does not honour cancellation: it answers after `seconds` of real time no matter what.
struct UncancellableVerifier: DetectionVerifier {
    var seconds: Double = 1.5
    var requiredPreRoll: Double { 0 }
    func verify(_ context: VerificationContext) async -> VerificationDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<VerificationDecision, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: .accept) }
        }
    }
}

// MARK: - Engines

/// Builds mock engines through registry descriptors and remembers every instance created.
final class EngineFactory: @unchecked Sendable {
    private let instances = Protected<[(id: String, engine: MockWakeWordEngine)]>([])

    func engines(id: String? = nil) -> [MockWakeWordEngine] {
        instances.withLock { $0.filter { id == nil || $0.id == id }.map(\.engine) }
    }

    func latest(_ id: String) -> MockWakeWordEngine? { engines(id: id).last }

    func descriptor(
        id: String,
        behavior: @escaping @Sendable () -> MockWakeWordEngine.Behavior = { MockWakeWordEngine.Behavior() },
        credentials: [CredentialRequirement] = [],
        supportsLiveSensitivity supportsLive: Bool = true,
        developerOnly: Bool = false
    ) -> EngineDescriptor {
        EngineDescriptor(
            id: id, displayName: id.capitalized, summary: "test engine",
            credentials: credentials,
            capabilities: .init(supportsLiveSensitivity: supportsLive, reportsConfidence: false),
            isDeveloperOnly: developerOnly,
            makeEngine: { [weak self] environment in
                let engine = MockWakeWordEngine(behavior: behavior(), sensitivity: environment.sensitivity, identifier: id)
                self?.instances.withLock { $0.append((id, engine)) }
                return engine
            }
        )
    }
}

// MARK: - Harness

/// A fully wired runtime on fakes: synthetic microphone, scripted engines, manual clock.
struct Harness: Sendable {
    let runtime: WakeWordRuntime
    let capture: SyntheticAudioSource
    let permission: FakePermission
    let devices: FakeDevices
    let system: FakeSystemEvents
    let assistant: RecordingAssistant
    let factory: EngineFactory
    let clock: ManualClock
    let credentials: InMemoryCredentialStore
    let network: FakeNetwork

    static let fastTimings = RuntimeTimings(
        captureRestartDebounce: .milliseconds(300),
        wakeSettleDelay: .seconds(1),
        retryBackoff: [.seconds(5), .seconds(15)],
        verifierTimeout: .seconds(2),
        maxRestartsInWindow: 4,
        restartWindow: .seconds(30)
    )

    static func make(
        settings: RuntimeSettings? = nil,
        engines: [EngineDescriptor]? = nil,
        factory: EngineFactory = EngineFactory(),
        permission: FakePermission = FakePermission(),
        assistant: RecordingAssistant = RecordingAssistant(),
        verifiers: [any DetectionVerifier] = [],
        credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
        clock: ManualClock = ManualClock(),
        network: FakeNetwork = FakeNetwork(),
        timings: RuntimeTimings = Harness.fastTimings
    ) -> Harness {
        let descriptors = engines ?? [factory.descriptor(id: "alpha"), factory.descriptor(id: "beta")]
        let registry = WakeWordEngineRegistry(descriptors)
        let capture = SyntheticAudioSource()
        let devices = FakeDevices()
        let system = FakeSystemEvents()
        let settings = settings ?? RuntimeSettings(engineID: descriptors[0].id)
        let runtime = WakeWordRuntime(
            settings: settings,
            dependencies: RuntimeDependencies(
                registry: registry, credentials: credentials, capture: capture, devices: devices,
                permission: permission, systemEvents: system, network: network, assistant: assistant, verifiers: verifiers,
                clock: clock, timings: timings
            )
        )
        return Harness(
            runtime: runtime, capture: capture, permission: permission, devices: devices, system: system,
            assistant: assistant, factory: factory, clock: clock, credentials: credentials, network: network
        )
    }

    /// Starts the runtime and waits until it is listening.
    func startListening() async throws {
        await runtime.start()
        try await runtime.waitForState("listening") { $0 == .listening }
    }

    /// Feeds audio (silence) until the engine under test has processed `frames` more frames than
    /// before. Bounded: a pipeline that stops delivering frames fails the test instead of hanging it.
    func feedFrames(_ frames: Int, engine: MockWakeWordEngine, timeout: Duration = .seconds(5)) async throws {
        let target = engine.callLog.processCalls + frames
        let deadline = ContinuousClock.now + timeout
        // 100 ms of 48 kHz audio is about three 32 ms frames.
        while engine.callLog.processCalls < target {
            guard ContinuousClock.now < deadline else {
                throw TimedOut(what: "\(frames) frames to reach the engine (saw \(engine.callLog.processCalls - (target - frames)))")
            }
            capture.push(seconds: 0.1)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Collects runtime events for assertions.
final class EventLog: @unchecked Sendable {
    private let storage = Protected<[RuntimeEvent]>([])
    private var task: Task<Void, Never>?

    init(_ runtime: WakeWordRuntime) async {
        let stream = await runtime.events()
        task = Task { [storage] in for await event in stream { storage.withLock { $0.append(event) } } }
    }

    deinit { task?.cancel() }

    var events: [RuntimeEvent] { storage.get() }

    var states: [ActivationState] {
        events.compactMap { if case .stateChanged(_, let to) = $0 { to } else { nil } }
    }

    var acceptedDetections: [WakeWordEvent] {
        events.compactMap { if case .detectionAccepted(let event) = $0 { event } else { nil } }
    }

    var suppressions: [DetectionValidator.Rejection] {
        events.compactMap { if case .detectionSuppressed(_, let reason, _) = $0 { reason } else { nil } }
    }

    var ignored: Int { events.filter { if case .detectionIgnored = $0 { true } else { false } }.count }

    var sessionOutcomes: [SessionOutcome] {
        events.compactMap { if case .sessionEnded(_, let outcome) = $0 { outcome } else { nil } }
    }
}

extension ActivationState {
    /// Case name without payload, for readable assertions on state sequences.
    var label: String {
        switch self {
        case .initializing: "initializing"
        case .listening: "listening"
        case .verifying: "verifying"
        case .wakeWordVerified: "wakeWordVerified"
        case .activated: "activated"
        case .commandSession: "commandSession"
        case .paused(let reason): "paused:\(reason)"
        case .error: "error"
        }
    }
}
