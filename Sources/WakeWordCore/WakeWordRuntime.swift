import Foundation
import FridayAudio
import WakeWordKit
import os

/// The supervisor that turns a microphone, an engine and a state machine into "Jarvis is listening".
///
/// ### Structure
/// * The **audio hot path** (capture thread → ``WakeWordPipeline`` → engine) never touches this
///   actor. The pipeline reports accepted detections into an ordered mailbox.
/// * Every external input — pipeline events, assistant session calls, capture/device/system
///   notifications, verifier results — goes through that one mailbox, so they are handled one at a
///   time in the order they happened.
/// * Slow work (the permission prompt, engine initialisation — which may involve the network) runs
///   in a *reconcile loop*: "make reality match the settings", idempotent and restartable. It
///   suspends at `await` points, so detections and session calls are still handled promptly while an
///   engine is loading.
/// * All state changes go through the pure ``ActivationStateMachine``; this actor only carries out
///   the effects it returns.
public actor WakeWordRuntime {
    // MARK: - Types

    private enum Input: Sendable {
        case pipeline(WakeWordPipeline.Event)
        case session(ActivationSession.Command)
        case capture(AudioCaptureEvent)
        case devices(AudioDeviceChange)
        case system(SystemEvent)
        case network(Bool)
        case verification(wakeEventID: UUID, VerificationOutcome)
    }

    private enum VerificationOutcome: Sendable {
        case accepted
        case rejected(String)
    }

    private struct LoadedEngine {
        let descriptor: EngineDescriptor
        let instance: any WakeWordEngine
        var sensitivity: Float
    }

    private struct ActiveSession {
        let info: ActivationSessionInfo
        let handlerTask: Task<Void, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct AccuracyMode {
        var cooldown: Double
    }

    private struct ReloadWaiter {
        let id: Int
        /// The ``WakeWordRuntime/engineInputsRevision`` asked for: an engine built under this revision or a later one answers it.
        let revision: Int
        let continuation: CheckedContinuation<EngineReload, Never>
    }

    /// Context of the detection currently being verified (pre-roll audio exists only if asked for).
    private struct PendingDetection {
        var preRoll: [Float]?
        var sampleRate: Int
    }

    // MARK: - State

    private let dependencies: RuntimeDependencies
    private let pipeline: WakeWordPipeline
    private let mailbox: AsyncStream<Input>.Continuation
    private let mailboxStream: AsyncStream<Input>
    private let snapshotBroadcaster = Broadcaster<RuntimeSnapshot>()
    private let eventBroadcaster = Broadcaster<RuntimeEvent>()
    private let preRollDuration: Double
    private let log = Logger(subsystem: "com.alejandro.friday", category: "runtime")

    private var settings: RuntimeSettings
    private var machine: ActivationStateMachine
    private var pauseReasons: Set<PauseReason> = []
    private var microphone: MicrophoneAuthorization
    private var loadedEngine: LoadedEngine?
    /// Bumped when something the engine is built from changes: a credential the user saved or removed, or the files it reads
    /// (a voice profile). The loaded engine remembers the revision it was built under, so "it must be rebuilt" can never be lost
    /// to a rebuild that was superseded half-way.
    private var engineInputsRevision = 0
    private var loadedEngineInputsRevision = 0
    /// Callers of ``reloadEngine()`` still waiting to hear how it went, and the last engine that could not be loaded (with the revision
    /// of the inputs it was being built from), which is what answers them when it fails.
    private var reloadWaiters: [ReloadWaiter] = []
    private var nextReloadWaiterID = 0
    private var lastEngineLoadFailure: (revision: Int, message: String)?
    private var captureInfo: AudioCaptureInfo?
    private var captureSelection: AudioInputSelection?
    private var captureRestartNeeded = false
    private var captureReleasedForSession = false
    private var restartLog: [HostTime] = []
    /// Two independent notices, because they have independent lives: one about an engine change that could not be
    /// applied yet, one about the chosen microphone not being in use. Clearing one must never forget the other.
    private var engineNotice: String?
    private var microphoneNotice: String?
    private var retryAt: Date?
    private var retryAttempt = 0
    /// Measures how long the detector has been ready (see `RuntimeTimings.stableAfter`); nil when it is not.
    private var healthyFor: (@Sendable () -> Duration)?
    private var preferredInputAttempts = 0
    private var assistantPhase: AssistantPhase?
    private var revision = 0
    private var pendingDetection: PendingDetection?
    private var session: ActiveSession?
    /// Who has asked for the accuracy-test mode, and the cooldown each wants. The mode is on while anyone holds a claim, so one test ending
    /// can never end another's.
    private var accuracyLeases: [Int: Double] = [:]
    private var nextAccuracyLeaseID = 0
    private var accuracyMode: AccuracyMode? { accuracyLeases.values.max().map { AccuracyMode(cooldown: $0) } }

    /// Bumped whenever resources are torn down on purpose, so in-flight async work can tell it was superseded.
    private var generation = 0
    private var started = false
    private var stopped = false
    private var reconcileTask: Task<Void, Never>?
    private var reconcileRequested = false
    private var retryTask: Task<Void, Never>?
    private var preferredInputTask: Task<Void, Never>?
    private var captureRestartTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []

    // MARK: - Lifecycle

    public init(settings: RuntimeSettings, dependencies: RuntimeDependencies) {
        self.settings = settings
        self.dependencies = dependencies
        self.preRollDuration = dependencies.verifiers.map(\.requiredPreRoll).max() ?? 0
        self.microphone = dependencies.permission.status()
        self.machine = ActivationStateMachine(configuration: .init(postSessionHoldoff: settings.postSessionHoldoff))

        let (stream, continuation) = AsyncStream.makeStream(of: Input.self, bufferingPolicy: .unbounded)
        self.mailboxStream = stream
        self.mailbox = continuation
        self.pipeline = WakeWordPipeline(
            configuration: Self.pipelineConfiguration(settings: settings, preRoll: preRollDuration, accuracy: nil)
        ) { event in continuation.yield(.pipeline(event)) }
    }

    /// Begins supervising: starts listening for notifications and brings detection up (unless
    /// the user has it disabled).
    public func start() {
        guard !started, !stopped else { return }
        started = true

        let stream = mailboxStream
        observers.append(Task { [weak self] in
            for await input in stream { await self?.handle(input) }
        })
        let mailbox = self.mailbox
        let capture = dependencies.capture, devices = dependencies.devices, system = dependencies.systemEvents
        observers.append(Task { for await event in capture.events() { mailbox.yield(.capture(event)) } })
        observers.append(Task { for await change in devices.changes() { mailbox.yield(.devices(change)) } })
        observers.append(Task { for await event in system.events() { mailbox.yield(.system(event)) } })
        let network = dependencies.network
        observers.append(Task { for await online in network.changes() { mailbox.yield(.network(online)) } })

        if !settings.isEnabled {
            pauseReasons.insert(.userDisabled)
            send(.pause(.userDisabled))
        }
        publish()
        scheduleReconcile()
    }

    /// Releases the microphone, the engine and every task. The runtime cannot be restarted.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        pipeline.setAudioTap(nil)
        cancelRetry()
        cancelPreferredInputRetry()
        captureRestartTask?.cancel()
        wakeTask?.cancel()
        reconcileTask?.cancel()
        if let session {
            session.timeoutTask.cancel()
            session.handlerTask.cancel()
            self.session = nil
        }
        dependencies.capture.stop()
        releaseEngine()
        captureInfo = nil
        mailbox.finish()
        observers.forEach { $0.cancel() }
        observers.removeAll()
        answerReloadWaiters(final: true)
        snapshotBroadcaster.finish()
        eventBroadcaster.finish()
    }

    // MARK: - Immediate shutdown

    /// Closes the microphone and unloads the engine **synchronously, from any thread**, without
    /// waiting for the actor. For process termination, where the event loop may not run async work:
    /// `applicationShouldTerminate` calls this and returns `.terminateNow`. Afterwards the runtime is
    /// inert; use `stop()` for orderly teardown elsewhere.
    public nonisolated func shutdownImmediately() {
        pipeline.setAudioTap(nil)
        dependencies.capture.stop()
        pipeline.uninstall()?.shutdown()
        mailbox.finish()
    }

    // MARK: - Public API

    /// The latest snapshot.
    public func snapshot() -> RuntimeSnapshot { makeSnapshot() }

    /// A stream of snapshots, starting with the current one. Always delivers the newest value.
    public func snapshots() -> AsyncStream<RuntimeSnapshot> {
        snapshotBroadcaster.stream(bufferingPolicy: .bufferingNewest(1), initial: makeSnapshot())
    }

    /// Diagnostic events (no audio, no secrets).
    public func events() -> AsyncStream<RuntimeEvent> {
        eventBroadcaster.stream()
    }

    public func pipelineStatistics() -> PipelineStatistics { pipeline.statistics() }
    public func resetPipelineStatistics() { pipeline.resetStatistics() }

    /// Applies new settings, doing only the work that the difference requires.
    public func apply(_ newSettings: RuntimeSettings) {
        let old = settings
        guard newSettings != old, !stopped else { return }
        settings = newSettings
        machine.configuration.postSessionHoldoff = newSettings.postSessionHoldoff
        pipeline.updateConfiguration(Self.pipelineConfiguration(settings: newSettings, preRoll: preRollDuration, accuracy: accuracyMode))

        let engineAffected = old.engineID != newSettings.engineID || old.sensitivity != newSettings.sensitivity
        let inputChanged = old.input != newSettings.input
        if inputChanged {
            captureRestartNeeded = true
            preferredInputAttempts = 0
            cancelPreferredInputRetry()
        }

        setPause(.userDisabled, active: !newSettings.isEnabled)

        if case .error = machine.state, engineAffected || inputChanged {
            retryAttempt = 0
            cancelRetry()
            send(.retry)
        }
        if engineAffected || inputChanged { scheduleReconcile() }
        publish()
    }

    /// Call after the user saved or removed a credential: the engine is rebuilt with the new one.
    public func credentialsDidChange() {
        rebuildEngine()
    }

    /// Call after the files the engine is built from have changed (the person's voice profile, say): the engine is rebuilt from
    /// them, and a failure to load is reported like any other. The microphone stays as it is.
    public func engineFilesDidChange() {
        rebuildEngine()
    }

    /// ``engineFilesDidChange()``, but it waits and says how the rebuild came out: an engine built from the files as they are now is
    /// loaded (``EngineReload/loaded``), or it could not be built from them (``EngineReload/failed(_:)``), or nothing is listening and so
    /// nothing was built (``EngineReload/notListening``). Cancelling the caller stops the wait, not the rebuild.
    public func reloadEngine() async -> EngineReload {
        guard started, !stopped else { return .notListening }
        rebuildEngine()
        let id = nextReloadWaiterID
        nextReloadWaiterID += 1
        let revision = engineInputsRevision
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineReload, Never>) in
                // Registered before this method first suspends, and the reconcile pass it asked for runs on this actor, so the answer
                // cannot come before the waiter is there to hear it.
                reloadWaiters.append(ReloadWaiter(id: id, revision: revision, continuation: continuation))
            }
        } onCancel: {
            Task { await self.dropReloadWaiter(id) }
        }
    }

    private func dropReloadWaiter(_ id: Int) {
        guard let index = reloadWaiters.firstIndex(where: { $0.id == id }) else { return }
        reloadWaiters.remove(at: index).continuation.resume(returning: .notListening)
    }

    /// Tells the callers of ``reloadEngine()`` what has become of their request. `final` says that no pass is coming that could still
    /// change the answer: those left then hear that nothing is listening.
    private func answerReloadWaiters(final: Bool) {
        guard !reloadWaiters.isEmpty else { return }
        var waiting: [ReloadWaiter] = []
        for waiter in reloadWaiters {
            if loadedEngine != nil, loadedEngineInputsRevision >= waiter.revision {
                waiter.continuation.resume(returning: .loaded)
            } else if let failure = lastEngineLoadFailure, failure.revision >= waiter.revision {
                waiter.continuation.resume(returning: .failed(failure.message))
            } else if final {
                waiter.continuation.resume(returning: .notListening)
            } else {
                waiting.append(waiter)
            }
        }
        reloadWaiters = waiting
    }

    private func rebuildEngine() {
        guard started, !stopped else { return }
        engineInputsRevision += 1
        if case .error = machine.state {
            retryAttempt = 0
            cancelRetry()
            send(.retry)
        }
        scheduleReconcile()
    }

    /// Hands every microphone buffer to `tap` as it arrives, before any detection (nil: stop). It is how the app listens to
    /// the person while they teach it their voice; see ``WakeWordPipeline/setAudioTap(_:)`` for what the tap may and may not do.
    /// Safe from any thread.
    public nonisolated func setAudioTap(_ tap: WakeWordPipeline.AudioTap?) {
        pipeline.setAudioTap(tap)
    }

    /// Manual retry after a failure.
    public func retry() {
        guard started, !stopped else { return }
        guard case .error = machine.state else { return }
        retryAttempt = 0
        cancelRetry()
        send(.retry)
    }

    /// Re-reads the microphone permission (for example after a prompt or after the user returns from
    /// System Settings) and recovers or fails accordingly.
    public func microphonePermissionMayHaveChanged() {
        guard started, !stopped else { return }
        refreshMicrophoneAuthorization()
    }

    /// Developer aid: pushes a synthetic "Jarvis" detection through validation, the state machine
    /// and the assistant, exactly like a real one.
    public func simulateWakeWord() {
        pipeline.injectDetection(DetectionResult(keyword: .jarvis))
    }

    /// While anyone holds a claim, accepted detections are reported as events but do **not** activate the assistant, and the cooldown is the
    /// longest any holder asked for (seconds) — so a person repeating "Jarvis" every couple of seconds is counted correctly. Used by the
    /// accuracy tester and by the voice lesson. Each gives back its own claim with ``leaveAccuracyTestMode(_:)``; one finishing never ends
    /// the mode for another.
    public func enterAccuracyTestMode(cooldown: Double = 1.0) -> AccuracyTestLease {
        let lease = AccuracyTestLease(id: nextAccuracyLeaseID)
        nextAccuracyLeaseID += 1
        accuracyLeases[lease.id] = cooldown
        accuracyModeDidChange()
        return lease
    }

    /// Gives back a claim made with ``enterAccuracyTestMode(cooldown:)``. Giving back one twice does nothing.
    public func leaveAccuracyTestMode(_ lease: AccuracyTestLease) {
        guard accuracyLeases.removeValue(forKey: lease.id) != nil else { return }
        accuracyModeDidChange()
    }

    /// How many claims on the accuracy-test mode are held (tests ask: none must be left behind).
    var accuracyTestClaims: Int { accuracyLeases.count }

    private func accuracyModeDidChange() {
        pipeline.updateConfiguration(Self.pipelineConfiguration(settings: settings, preRoll: preRollDuration, accuracy: accuracyMode))
        // Test detections must not leave cooldown/debounce history that would suppress the first real
        // activation (or vice versa).
        pipeline.resetValidation()
        if accuracyMode == nil { pipeline.setGated(false) }
    }

    // MARK: - Mailbox

    private func handle(_ input: Input) {
        guard !stopped else { return }
        switch input {
        case .pipeline(let event): handlePipeline(event)
        case .session(let command): handleSession(command)
        case .capture(let event): handleCapture(event)
        case .devices(let change): handleDevices(change)
        case .system(let event): handleSystem(event)
        case .network(let online): handleNetwork(online)
        case .verification(let id, let outcome): handleVerification(id, outcome)
        }
    }

    private func handlePipeline(_ event: WakeWordPipeline.Event) {
        switch event {
        case .detection(let wake, let preRoll, let rate):
            emit(.detectionAccepted(wake))
            if accuracyMode != nil { return }
            pendingDetection = PendingDetection(preRoll: preRoll, sampleRate: rate)
            send(.detection(wake))
        case .suppressed(let keyword, let reason, let time):
            emit(.detectionSuppressed(keyword: keyword, reason: reason, at: time))
        case .engineFault(let error, let faulted):
            // A late report about an engine that has since been replaced or released says nothing about what is
            // running now — and must not overwrite whatever happened to it.
            guard let loaded = loadedEngine, ObjectIdentifier(loaded.instance) == faulted else { return }
            log.error("engine fault: \(error.localizedDescription, privacy: .public)")
            emit(.engineFailed(error))
            // Whatever state we are in — even paused — a faulted engine must not stay installed: the
            // pipeline has stopped feeding it, and a later resume would find "an engine already loaded"
            // and listen through one that never hears anything.
            releaseEngine()
            var failure = DetectorFailure.engine(error)
            failure.recovery = .retryAutomatically  // a fault mid-run is worth retrying with backoff
            fail(failure)
        }
    }

    private func handleSession(_ command: ActivationSession.Command) {
        switch command {
        case .beginCommand(let id):
            guard session?.info.id == id else { return }
            send(.commandSessionBegan(id: id))
        case .setPhase(let id, let phase):
            guard session?.info.id == id else { return }
            assistantPhase = phase
            publish()
        case .finish(let id, let outcome):
            guard let current = session, current.info.id == id else { return }
            endSession(current, outcome: outcome)
            send(.sessionEnded(id: id, outcome: outcome))
        }
    }

    private func handleCapture(_ event: AudioCaptureEvent) {
        switch event {
        case .configurationChanged:
            noteCaptureLost(reason: "audio configuration changed")
        case .interrupted(let reason):
            noteCaptureLost(reason: reason)
        }
    }

    private func handleDevices(_ change: AudioDeviceChange) {
        switch change {
        case .deviceListChanged:
            if pauseReasons.contains(.noInputDevice) {
                setPause(.noInputDevice, active: false)
            } else if case .device(let uid) = settings.input {
                let available = dependencies.devices.inputDevices().contains { $0.uid == uid }
                let usingIt = captureInfo?.deviceUID == uid
                // The preferred device came back (we were on a fallback) or the one in use vanished.
                if (available && !usingIt && microphoneNotice != nil) || (!available && usingIt) {
                    scheduleCaptureRestart()
                }
            }
        case .defaultInputChanged:
            if pauseReasons.contains(.noInputDevice) {
                setPause(.noInputDevice, active: false)
            } else if settings.input == .systemDefault {
                scheduleCaptureRestart()
            }
        }
    }

    private func handleSystem(_ event: SystemEvent) {
        switch event {
        case .willSleep:
            wakeTask?.cancel()
            setPause(.systemSleep, active: true)
        case .didWake:
            // Audio devices reappear a moment after wake; give them time before reopening.
            wakeTask?.cancel()
            let clock = dependencies.clock, delay = dependencies.timings.wakeSettleDelay
            wakeTask = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                await self?.finishWake()
            }
        case .userSessionDidResignActive:
            setPause(.userSessionInactive, active: true)
        case .userSessionDidBecomeActive:
            setPause(.userSessionInactive, active: false)
        case .applicationDidBecomeActive:
            refreshMicrophoneAuthorization()
        }
    }

    private func handleNetwork(_ online: Bool) {
        guard online else { return }
        // Connectivity is back: anything that failed because it was missing should not wait for its timer.
        if case .error(let failure) = machine.state, case .engine(let error) = failure.kind, case .networkUnavailable = error {
            // Only failures *caused by* missing connectivity. (Other automatically retried failures — an
            // audio configuration that keeps changing, say — keep their own back-off however often the
            // network flaps.)
            retryAttempt = 0
            cancelRetry()
            send(.retry)
        } else if engineNotice != nil {
            scheduleReconcile()   // a rebuild that could not be applied yet (for example a new sensitivity)
        }
    }

    private func finishWake() {
        wakeTask = nil
        setPause(.systemSleep, active: false)
    }

    private func handleVerification(_ wakeEventID: UUID, _ outcome: VerificationOutcome) {
        guard case .verifying(let wake) = machine.state, wake.id == wakeEventID else { return }
        switch outcome {
        case .accepted:
            send(.verificationPassed)
        case .rejected(let reason):
            emit(.verificationRejected(wake, reason: reason))
            send(.verificationRejected(reason: reason))
        }
    }

    // MARK: - State machine plumbing

    /// Feeds `event` to the state machine, publishes any state change, then carries out the effects
    /// it asks for. Every transition goes through here, so an effect can never be forgotten.
    private func send(_ event: ActivationEvent) {
        let before = machine.state
        let effects = machine.handle(event)
        let after = machine.state
        if before != after {
            log.info("state \(Self.name(of: before), privacy: .public) → \(Self.name(of: after), privacy: .public)")
            emit(.stateChanged(from: before, to: after))
            publish()
        }
        execute(effects)
    }

    private func execute(_ effects: [ActivationEffect]) {
        for effect in effects {
            switch effect {
            case .gateDetector:
                pipeline.setGated(true)
            case .ungateDetector(let holdoff):
                pipeline.setGated(false, holdoff: holdoff)
                scheduleReconcile()   // reopens the microphone if the session policy had closed it
            case .runVerifiers(let wake):
                startVerification(of: wake)
            case .dispatchActivation(let wake):
                dispatchActivation(wake)
            case .cancelSession(let id, let outcome):
                if let current = session, current.info.id == id { endSession(current, outcome: outcome) }
            case .releaseCapture:
                stopCapture()
            case .releaseEngine:
                releaseEngine()
            case .recordIgnoredDetection(let wake):
                emit(.detectionIgnored(wake))
                // The pipeline gated itself when it accepted this detection. If we are about to be
                // listening (a detection slipped in during start-up), do not leave it gated forever.
                if machine.state == .initializing || machine.state == .listening {
                    pipeline.setGated(false)
                }
            case .acquireResources:
                pipeline.setGated(false)
                scheduleReconcile()
            }
        }
    }

    private func setPause(_ reason: PauseReason, active: Bool) {
        let changed = active ? pauseReasons.insert(reason).inserted : (pauseReasons.remove(reason) != nil)
        guard changed else { return }
        generation += 1
        if let primary = pauseReasons.min() {
            cancelRetry()
            cancelPreferredInputRetry()
            healthyFor = nil   // time spent paused is not time spent healthy
            send(.pause(primary))
        } else {
            preferredInputAttempts = 0   // resuming reopens the microphone: the chosen one gets its full set of tries again
            send(.resume)
        }
        publish()
    }

    // MARK: - Verification and activation

    private func startVerification(of wake: WakeWordEvent) {
        let verifiers = dependencies.verifiers
        guard !verifiers.isEmpty else {
            send(.verificationPassed)
            return
        }
        let context = VerificationContext(
            event: wake, preRoll: pendingDetection?.preRoll, sampleRate: pendingDetection?.sampleRate ?? 16_000
        )
        pendingDetection = nil
        let mailbox = self.mailbox
        let clock = dependencies.clock, timeout = dependencies.timings.verifierTimeout
        Task {
            let outcome = await Self.verify(context, with: verifiers, timeout: timeout, clock: clock)
            mailbox.yield(.verification(wakeEventID: wake.id, outcome))
        }
    }

    /// Runs the verifiers against a hard deadline. The first of {verdict, time-out} wins; a verifier that
    /// ignores cancellation can keep running in the background, but it can no longer hold the detector
    /// gated past the time-out (a task group would wait for it).
    private static func verify(
        _ context: VerificationContext,
        with verifiers: [any DetectionVerifier],
        timeout: Duration,
        clock: any Clock<Duration>
    ) async -> VerificationOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<VerificationOutcome, Never>) in
            let race = VerificationRace(continuation)
            let worker = Task {
                for verifier in verifiers {
                    if case .reject(let reason) = await verifier.verify(context) {
                        race.finish(.rejected(reason))
                        return
                    }
                }
                race.finish(.accepted)
            }
            let timer = Task {
                do { try await clock.sleep(for: timeout) } catch { return }
                race.finish(.rejected("verification timed out"))
            }
            race.attach(worker: worker, timer: timer)
        }
    }

    /// First result wins; later ones are ignored. Cancels whatever is still running once decided.
    private final class VerificationRace: @unchecked Sendable {
        private let lock = UnfairLock()
        private var continuation: CheckedContinuation<VerificationOutcome, Never>?
        private var worker: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<VerificationOutcome, Never>) {
            self.continuation = continuation
        }

        func attach(worker: Task<Void, Never>, timer: Task<Void, Never>) {
            let alreadyDecided = lock.withLock { () -> Bool in
                self.worker = worker
                self.timer = timer
                return continuation == nil
            }
            if alreadyDecided {   // a very fast verifier finished before the tasks were registered
                worker.cancel()
                timer.cancel()
            }
        }

        func finish(_ outcome: VerificationOutcome) {
            let (pending, worker, timer) = lock.withLock { () -> (CheckedContinuation<VerificationOutcome, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
                let pending = continuation
                continuation = nil
                return (pending, self.worker, self.timer)
            }
            guard let pending else { return }
            pending.resume(returning: outcome)
            worker?.cancel()
            timer?.cancel()
        }
    }

    private func dispatchActivation(_ wake: WakeWordEvent) {
        pendingDetection = nil
        let info = ActivationSessionInfo(event: wake)
        let mailbox = self.mailbox
        let activation = ActivationSession(info: info) { command in mailbox.yield(.session(command)) }

        let assistant = dependencies.assistant
        let handlerTask = Task {
            await assistant.onWakeWordDetected(wake, session: activation)
            activation.finish(.completed)  // returning from the handler ends the session
        }
        let clock = dependencies.clock, limit = settings.maxSessionDuration
        let timeoutTask = Task {
            do { try await clock.sleep(for: .seconds(limit)) } catch { return }
            activation.finish(.timedOut)
        }
        session = ActiveSession(info: info, handlerTask: handlerTask, timeoutTask: timeoutTask)
        assistantPhase = nil

        if settings.sessionAudioPolicy == .releaseMicrophone {
            stopCapture()
            captureReleasedForSession = true
        }
        emit(.activationDispatched(wake, session: info.id, audioToDispatch: max(0, HostTime.now.seconds(since: wake.audioEndTime))))
        send(.activationDispatched(info))
    }

    private func endSession(_ active: ActiveSession, outcome: SessionOutcome) {
        active.timeoutTask.cancel()
        if outcome != .completed { active.handlerTask.cancel() }
        // The assistant no longer owns the microphone, however the session ended (finished, timed
        // out, or cancelled by a pause/failure). If it was closed for the session, the next
        // reconcile — now, or after a resume/retry — reopens it.
        captureReleasedForSession = false
        session = nil
        assistantPhase = nil
        emit(.sessionEnded(session: active.info.id, outcome: outcome))
        publish()
    }

    // MARK: - Reconciliation (slow, restartable work)

    private func scheduleReconcile() {
        guard started, !stopped else { return }
        reconcileRequested = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in await self?.runReconcileLoop() }
    }

    private func runReconcileLoop() async {
        while reconcileRequested, !stopped {
            reconcileRequested = false
            await reconcileOnce()
            answerReloadWaiters(final: !reconcileRequested)
        }
        reconcileTask = nil
        answerReloadWaiters(final: true)
    }

    private func reconcileOnce() async {
        guard pauseReasons.isEmpty else { return }
        switch machine.state {
        case .error, .paused: return                      // waiting for a retry or the user
        case .verifying, .wakeWordVerified, .activated, .commandSession:
            // A session is in progress; only an engine/sensitivity change needs work, and the
            // pipeline is gated, so it is safe to do it now.
            break
        case .initializing, .listening: break
        }
        let startGeneration = generation

        // 1. Microphone permission.
        var authorization = dependencies.permission.status()
        if authorization == .notDetermined {
            authorization = await dependencies.permission.request()
            guard generation == startGeneration, pauseReasons.isEmpty, !stopped else { return }
        }
        if microphone != authorization { microphone = authorization; publish() }
        guard authorization == .authorized else {
            fail(.microphone(authorization))
            return
        }

        // 2. Engine.
        guard await ensureEngine(generation: startGeneration) else { return }

        // 3. Microphone capture. (`ensureEngine` returns true only if nothing changed since this pass began: it
        // re-checks after its last suspension, and there is no suspension between that and here.)
        ensureCapture()

        // 4. Ready. The back-off is *not* reset here: an engine that loads and faults a moment later must keep
        // backing off. It starts over only after the detector has stayed healthy for a while (see `fail`).
        if machine.state == .initializing, captureInfo != nil {
            healthyFor = Self.stopwatch(on: dependencies.clock)
            send(.engineReady)
        }
    }

    /// Makes sure the engine the settings ask for is loaded and installed. Returns false when
    /// reconciliation should stop (a failure was reported, or the work was superseded).
    private func ensureEngine(generation startGeneration: Int) async -> Bool {
        let wantedID = settings.engineID
        let wantedSensitivity = settings.sensitivity

        guard let descriptor = dependencies.registry[wantedID] else {
            let error = WakeWordError.engineUnavailable("unknown engine “\(wantedID)”")
            lastEngineLoadFailure = (engineInputsRevision, error.localizedDescription)
            fail(.engine(error))
            return false
        }

        // An engine built before the latest credential (or engine-file) change is rebuilt whatever else matches. This is a comparison
        // of revisions, not a flag that is consumed up front: a rebuild that gets superseded (the lid closes while it
        // loads) leaves the engine stale, so the next pass still sees that it must be rebuilt.
        let revisionAtStart = engineInputsRevision
        let reload = loadedEngine != nil && loadedEngineInputsRevision != revisionAtStart
        if let loaded = loadedEngine, loaded.descriptor.id == wantedID, !reload {
            if loaded.sensitivity == wantedSensitivity {
                if engineNotice != nil {   // nothing is pending any more: the setting went back to what is loaded
                    engineNotice = nil
                    if case .error = machine.state {} else { cancelRetry() }
                    publish()
                }
                return true
            }
            do throws(WakeWordError) {
                try pipeline.updateSensitivity(wantedSensitivity)
                loadedEngine?.sensitivity = wantedSensitivity
                publish()
                return true
            } catch {
                // Cannot be applied in place (or failed): fall through and build a replacement.
            }
        }

        // Only a pure sensitivity change may fall back to the engine that is already listening. If the
        // rebuild was forced by new credentials, a failure must be shown — silently keeping an engine
        // built with the old key would hide that the new one is wrong.
        let keepingCurrent = !reload && loadedEngine?.descriptor.id == wantedID
        let environment = EngineEnvironment(
            keywords: [.jarvis], sensitivity: wantedSensitivity,
            credentials: dependencies.credentials, resources: dependencies.resources
        )
        let began = HostTime.now
        let wasOnline = dependencies.network.isOnline
        var created: (any WakeWordEngine)?
        let candidate: any WakeWordEngine
        do throws(WakeWordError) {
            let engine = try descriptor.makeEngine(environment)
            created = engine
            try await engine.initialize()
            candidate = engine
        } catch {
            // An engine that failed half-way may still hold what it allocated; shutdown() is idempotent.
            created?.shutdown()
            let error = reclassifiedIfOffline(error, wasOnline: wasOnline)
            emit(.engineFailed(error))
            log.error("engine \(wantedID, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            guard generation == startGeneration, pauseReasons.isEmpty, !stopped else { return false }
            if keepingCurrent {
                // A sensitivity change that could not be applied: keep listening with the old value.
                engineNotice = "Couldn’t apply the new sensitivity yet (\(error.localizedDescription)). Still using the previous value."
                if error.recovery == .retryAutomatically { scheduleRetryTimer() }
                publish()
                return true
            }
            lastEngineLoadFailure = (revisionAtStart, error.localizedDescription)
            fail(.engine(error))
            return false
        }

        // Superseded while loading (disabled, settings changed again, or stopped)? Discard it.
        guard generation == startGeneration, pauseReasons.isEmpty, !stopped else {
            candidate.shutdown()
            return false
        }
        if settings.engineID != wantedID || settings.sensitivity != wantedSensitivity {
            candidate.shutdown()
            scheduleReconcile()
            return false
        }

        do throws(WakeWordError) {
            let previous = try pipeline.install(candidate)
            previous?.shutdown()
        } catch {
            candidate.shutdown()
            lastEngineLoadFailure = (revisionAtStart, error.localizedDescription)
            fail(.engine(error))
            return false
        }
        loadedEngine = LoadedEngine(descriptor: descriptor, instance: candidate, sensitivity: wantedSensitivity)
        loadedEngineInputsRevision = revisionAtStart   // a change that arrived while it loaded leaves it stale, and it is rebuilt
        lastEngineLoadFailure = nil
        engineNotice = nil
        cancelRetry()
        emit(.engineLoaded(id: wantedID, duration: HostTime.now.seconds(since: began)))
        publish()
        return true
    }

    /// A licence check cannot succeed offline, and an engine cannot always tell "offline" from "rejected".
    /// If the Mac was offline at the start *or* the end of the attempt, such a failure is about connectivity —
    /// and is retried automatically — rather than telling the user their (possibly perfectly good) key is wrong.
    /// (Checking only the end would blame the key whenever Wi-Fi comes up while the check is failing.)
    private func reclassifiedIfOffline(_ error: WakeWordError, wasOnline: Bool) -> WakeWordError {
        guard !(wasOnline && dependencies.network.isOnline) else { return error }
        switch error {
        case .licenceCheckFailed: return .networkUnavailable("no internet connection")
        default: return error   // a malformed key, an internal fault, a licence limit: not about connectivity
        }
    }

    private func ensureCapture() {
        guard !captureReleasedForSession else { return }
        if dependencies.capture.isRunning, captureInfo != nil, captureSelection == settings.input, !captureRestartNeeded {
            return
        }
        stopCapture()
        captureRestartNeeded = false

        do throws(AudioCaptureError) {
            let info = try startCapture()
            captureInfo = info
            captureSelection = settings.input
            emit(.captureStarted(info))
            publish()
        } catch .noInputDevice {
            microphoneNotice = nil
            setPause(.noInputDevice, active: true)
        } catch .microphoneNotAuthorized(let status) {
            microphone = status
            fail(.microphone(status))
        } catch {
            fail(.audio(error))
        }
    }

    private func startCapture() throws(AudioCaptureError) -> AudioCaptureInfo {
        let pipeline = self.pipeline
        let handler: AudioChunkHandler = { samples, rate, time in
            pipeline.ingest(samples, sampleRate: rate, hostTime: time)
        }
        do throws(AudioCaptureError) {
            let info = try dependencies.capture.start(input: settings.input, handler: handler)
            microphoneNotice = nil
            preferredInputAttempts = 0
            cancelPreferredInputRetry()
            return info
        } catch {
            // The preferred microphone is missing, or cannot be opened (some input-only devices cannot share
            // the engine's I/O unit). Fall back to the system default — Jarvis keeps listening — and say so.
            guard settings.input != .systemDefault else { throw error }
            var retryChosenLater = false
            switch error {
            case .deviceUnavailable:
                microphoneNotice = "The selected microphone isn’t connected, so Jarvis is using the system default."
                cancelPreferredInputRetry()   // the device list says when it is back; there is nothing to poll
            case .engineFailed:
                microphoneNotice = "The selected microphone couldn’t be used, so Jarvis is using the system default."
                retryChosenLater = true       // it may only have been mid-switch (after wake, a Bluetooth profile change)
            default:
                throw error
            }
            emit(.notice(microphoneNotice ?? ""))
            let info = try dependencies.capture.start(input: .systemDefault, handler: handler)
            if retryChosenLater { schedulePreferredInputRetry() }
            return info
        }
    }

    private func stopCapture() {
        dependencies.capture.stop()
        if captureInfo != nil {
            captureInfo = nil
            captureSelection = nil
            emit(.captureStopped)
            publish()
        }
    }

    private func releaseEngine() {
        if let uninstalled = pipeline.uninstall() { uninstalled.shutdown() }
        if let loaded = loadedEngine {
            loaded.instance.shutdown()  // idempotent if already shut down above
            loadedEngine = nil
            publish()
        }
    }

    // MARK: - Failure and recovery

    private func fail(_ failure: DetectorFailure) {
        log.error("failure: \(failure.message, privacy: .public)")
        // Work that was in flight (an engine still loading, say) was started under a state that no longer
        // holds; it must discard its result rather than reopen the microphone behind the error.
        generation += 1
        // A failure after a long healthy run is a new incident, not another round of an old one; one that comes
        // straight after a (re)load continues the back-off, so an engine that faults at once is not rebuilt every 5 s.
        if let healthy = healthyFor?(), healthy >= dependencies.timings.stableAfter { retryAttempt = 0 }
        healthyFor = nil
        send(.failure(failure))
        guard case .error = machine.state else { return }
        if failure.recovery == .retryAutomatically { scheduleRetryTimer() }
        publish()
    }

    private func scheduleRetryTimer() {
        cancelRetry()
        let backoff = dependencies.timings.retryBackoff
        let delay = backoff.isEmpty ? .seconds(30) : backoff[min(retryAttempt, backoff.count - 1)]
        retryAttempt += 1
        let components = delay.components
        retryAt = Date().addingTimeInterval(Double(components.seconds) + Double(components.attoseconds) / 1e18)
        let clock = dependencies.clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.retryTimerFired()
        }
    }

    private func retryTimerFired() {
        retryTask = nil
        retryAt = nil
        if case .error = machine.state {
            send(.retry)
        } else {
            // Sensitivity re-apply retry while listening.
            scheduleReconcile()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        if retryAt != nil { retryAt = nil }
    }

    private func noteCaptureLost(reason: String) {
        // A source stops itself *before* it reports that capture was lost, so one that is running now was opened
        // after the session the news is about — this runtime already restarted it (a setting changed, a wake-up)
        // and what it has is healthy. Acting on the stale report would disown a working microphone in the
        // snapshot and restart it for nothing.
        guard !dependencies.capture.isRunning else {
            log.info("ignoring a capture notification about a session that was already replaced: \(reason, privacy: .public)")
            return
        }
        log.info("capture lost: \(reason, privacy: .public)")
        if captureInfo != nil {
            captureInfo = nil
            captureSelection = nil
            emit(.captureStopped)
            publish()   // the UI must stop naming a device that is gone, not wait out the debounce
        }
        scheduleCaptureRestart()
    }

    private func scheduleCaptureRestart() {
        guard started, !stopped, pauseReasons.isEmpty, !captureReleasedForSession else { return }
        switch machine.state {
        case .error, .paused: return
        default: break
        }
        captureRestartTask?.cancel()
        let clock = dependencies.clock, delay = dependencies.timings.captureRestartDebounce
        captureRestartTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.performCaptureRestart()
        }
    }

    private func performCaptureRestart() {
        captureRestartTask = nil
        guard !stopped, pauseReasons.isEmpty else { return }
        let now = HostTime.now
        let window = dependencies.timings.restartWindow.components.seconds
        restartLog = restartLog.filter { now.seconds(since: $0) < Double(window) }
        restartLog.append(now)
        if restartLog.count > dependencies.timings.maxRestartsInWindow {
            restartLog.removeAll()
            fail(DetectorFailure.audio(.engineFailed("the audio configuration keeps changing")))
            return
        }
        captureRestartNeeded = true
        preferredInputAttempts = 0   // something about the audio route changed: the chosen microphone deserves a fresh set of tries
        scheduleReconcile()
    }

    // MARK: - The chosen microphone, while another one is in use

    /// Arms the next try of the chosen microphone. Bounded by `RuntimeTimings.preferredInputRetry`: each try briefly
    /// interrupts listening, so a microphone that cannot work is not hammered forever.
    private func schedulePreferredInputRetry() {
        preferredInputTask?.cancel()
        preferredInputTask = nil
        let delays = dependencies.timings.preferredInputRetry
        guard preferredInputAttempts < delays.count else { return }
        let delay = delays[preferredInputAttempts]
        preferredInputAttempts += 1
        let clock = dependencies.clock
        preferredInputTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.preferredInputRetryFired()
        }
    }

    private func preferredInputRetryFired() {
        preferredInputTask = nil
        guard !stopped, pauseReasons.isEmpty, microphoneNotice != nil, captureInfo != nil, !captureReleasedForSession else { return }
        captureRestartNeeded = true   // reopening tries the chosen microphone first
        scheduleReconcile()
    }

    private func cancelPreferredInputRetry() {
        preferredInputTask?.cancel()
        preferredInputTask = nil
    }

    private func refreshMicrophoneAuthorization() {
        let status = dependencies.permission.status()
        guard status != microphone else { return }
        microphone = status
        if status.isAuthorized {
            if case .error(let failure) = machine.state, failure.isMicrophonePermissionFailure {
                retryAttempt = 0
                send(.retry)
            }
        } else if pauseReasons.isEmpty {
            switch machine.state {
            case .initializing, .listening, .verifying, .wakeWordVerified, .activated, .commandSession:
                fail(.microphone(status))
            default: break
            }
        }
        publish()
    }

    // MARK: - Publishing

    private func emit(_ event: RuntimeEvent) {
        eventBroadcaster.send(event)
    }

    private func publish() {
        guard !stopped else { return }
        snapshotBroadcaster.send(makeSnapshot(advancing: true))
    }

    /// What the user is told in the menu: both notices, if both apply.
    private var visibleNotice: String? {
        let parts = [engineNotice, microphoneNotice].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func makeSnapshot(advancing: Bool = false) -> RuntimeSnapshot {
        if advancing { revision += 1 }
        return RuntimeSnapshot(
            state: machine.state,
            settings: settings,
            microphone: microphone,
            engine: loadedEngine.map { ActiveEngine(id: $0.descriptor.id, displayName: $0.descriptor.displayName, sensitivity: $0.sensitivity) },
            capture: captureInfo,
            assistantPhase: assistantPhase,
            notice: visibleNotice,
            retryAt: retryAt,
            revision: revision
        )
    }

    private static func pipelineConfiguration(
        settings: RuntimeSettings, preRoll: Double, accuracy: AccuracyMode?
    ) -> WakeWordPipeline.Configuration {
        .init(
            validation: .init(
                cooldown: accuracy?.cooldown ?? settings.cooldown,
                debounceWindow: settings.debounceWindow,
                acceptedKeywords: [WakeKeyword.jarvis.id]
            ),
            gateOnAcceptedDetection: accuracy == nil,
            preRollDuration: preRoll
        )
    }

    /// A stopwatch on the injected clock (so tests control it). Generic so the clock's `Instant` type stays hidden.
    private static func stopwatch<C: Clock>(on clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    private static func name(of state: ActivationState) -> String {
        switch state {
        case .initializing: "initializing"
        case .listening: "listening"
        case .verifying: "verifying"
        case .wakeWordVerified: "wakeWordVerified"
        case .activated: "activated"
        case .commandSession: "commandSession"
        case .paused(let reason): "paused(\(reason))"
        case .error: "error"
        }
    }
}
