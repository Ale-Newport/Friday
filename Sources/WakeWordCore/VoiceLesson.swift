import Foundation
import WakeWordKit
import os

// MARK: - State

/// Everything a screen needs to guide a person through teaching the app their voice, as one value.
public struct VoiceLessonState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Checking that the app is listening.
        case starting
        /// Listening to the room, to know what counts as speech.
        case calibrating
        /// A step of the script is under way (``stepIndex``).
        case recording
        /// Everything was said; the analysis has not begun.
        case readyToLearn
        /// The engine is working on the recordings (minutes).
        case learning
        /// The analysis is done (see ``report``).
        case finished
        case installing
        case installed
        case failed(String)
        case cancelled
    }

    /// A short word to the person while they speak.
    public struct Hint: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case tooQuiet, tooLoud, tooLong, noisyRoom, cannotHear }
        public var kind: Kind
        public var message: String
        /// Increases with every hint, so a screen can tell a repeated one from the one it already showed.
        public var sequence: Int

        public init(kind: Kind, message: String, sequence: Int) {
            self.kind = kind
            self.message = message
            self.sequence = sequence
        }
    }

    public var phase: Phase = .idle
    public var stepIndex = 0
    public var stepCount = 0
    /// Phrases counted in the current step, and how many it asks for.
    public var heard = 0
    public var required = 0
    /// What to say now.
    public var prompt = ""
    /// The step has what it needs and is about to give way to the next.
    public var stepComplete = false
    /// A reading's progress, in seconds of speech.
    public var speechSeconds = 0.0
    public var targetSeconds = 0.0
    public var minimumSeconds = 0.0
    /// Whether the person may go on without finishing the step.
    public var canFinishStep = false
    /// The sound of the room right now, 0…1 for a meter.
    public var level: Float = 0
    public var calibration = 0.0
    public var hint: Hint?
    /// Phrases counted in all; changes with each, so a screen can react to the moment.
    public var acceptedCount = 0
    public var learning: VoiceTrainingProgress?
    public var report: VoiceTrainingReport?
    public var change: VoiceProfileChange?
    /// Something the person should know about the screen they are on (why a button did nothing, what happened to what they saved).
    public var notice: String?

    public init(stepCount: Int = 0) {
        self.stepCount = stepCount
    }

    public var isRecording: Bool {
        switch phase {
        case .starting, .calibrating, .recording: true
        default: false
        }
    }
}

// MARK: - The lesson

/// A guided session in which a person teaches the app their voice: the app listens (through the runtime's audio tap, while detection
/// goes on without activating anything), asks for phrase after phrase, notices by itself when each has been said, then hands the
/// recordings to the engine's ``VoiceTrainer``, shows what it found, and — if the person agrees — installs it and reloads the engine.
///
/// Audio is kept in memory only, for as long as the lesson lasts. A lesson is used once; start another with a new instance.
public actor VoiceLesson {
    public let script: VoiceLessonScript

    private let runtime: WakeWordRuntime
    private let trainer: VoiceTrainer
    /// The engine's environment as it is when the analysis begins (the sensitivity may have moved since the window opened).
    private let environment: @Sendable () async -> EngineEnvironment
    /// Called whenever the profile on disk has changed (installed, or put back), wherever the window has got to.
    private let profileDidChange: @Sendable () -> Void
    private let clock: any Clock<Duration>
    private let broadcaster = Broadcaster<VoiceLessonState>()
    private let tickInterval: Duration

    private var state: VoiceLessonState
    private var capture: VoiceCapture?
    private var loop: Task<Void, Never>?
    private var learnTask: Task<Void, Never>?
    private var recordingAttached = false
    /// The claim on detection's test mode, and the giving-back of it that ``release()`` has started and nobody has waited for yet.
    private var accuracyLease: AccuracyTestLease?
    private var leaving: Task<Void, Never>?

    // Recording bookkeeping.
    private var roomFloor: Float = -70
    /// The first frame not yet judged: everything before it is accounted for.
    private var cursor = 0
    /// Where each step began in the recording, and where it ended (the recording's end for the step in progress).
    private var stepStarts: [Int]
    private var stepEnds: [Int]
    private var accepted: [[VoiceRecordings.Utterance]]
    private var holdTicks = 0
    private var hintTicks = 0
    private var hintSequence = 0
    private var lastFrameCount = 0
    private var stalledTicks = 0
    private var quietTicks = 0
    private var notListeningChecks = 0
    private var recordings: VoiceRecordings?

    private static let tooQuietPeak: Float = 0.004      // about −48 dBFS: what the level stage can still work with
    private static let clippingPeak: Float = 0.995
    private static let holdAfterStepTicks = 8
    private static let hintTicks = 30
    private static let cannotHearAfterTicks = 100
    private static let stalledAfterTicks = 30

    public init(
        script: VoiceLessonScript = .standard, runtime: WakeWordRuntime, trainer: VoiceTrainer,
        environment: @escaping @Sendable () async -> EngineEnvironment, profileDidChange: @escaping @Sendable () -> Void = {},
        clock: any Clock<Duration> = ContinuousClock(), tickInterval: Duration = .milliseconds(100)
    ) {
        self.script = script
        self.runtime = runtime
        self.trainer = trainer
        self.environment = environment
        self.profileDidChange = profileDidChange
        self.clock = clock
        self.tickInterval = tickInterval
        self.state = VoiceLessonState(stepCount: script.steps.count)
        self.accepted = Array(repeating: [], count: script.steps.count)
        self.stepStarts = Array(repeating: 0, count: script.steps.count)
        self.stepEnds = Array(repeating: 0, count: script.steps.count)
    }

    deinit {
        // A lesson that was dropped without being cancelled still gives back its claim on detection's test mode: otherwise the assistant
        // would never wake again.
        if let lease = accuracyLease {
            let runtime = self.runtime
            Task { await runtime.leaveAccuracyTestMode(lease) }
        }
    }

    public func currentState() -> VoiceLessonState { state }

    /// The state now and every change after it.
    public func stateUpdates() -> AsyncStream<VoiceLessonState> {
        broadcaster.stream(bufferingPolicy: .bufferingNewest(1), initial: state)
    }

    // MARK: Starting and stopping

    /// Begins listening. Needs the app to be listening already (the microphone is open and an engine is loaded); says so if not.
    public func begin() async {
        guard state.phase == .idle else { return }
        guard !script.steps.isEmpty else { fail("There is nothing to ask for in this lesson."); return }
        set(.starting)
        let snapshot = await runtime.snapshot()
        guard state.phase == .starting else { return }   // cancelled while asking
        guard snapshot.state == .listening else {
            fail("Friday has to be listening to hear you. Turn on “Listen for Jarvis” (and check the microphone) and try again.")
            return
        }
        let capture = VoiceCapture(maximumSeconds: script.maximumSeconds)
        self.capture = capture
        // Detections are counted but never activate the assistant, however many times the name is said.
        let lease = await runtime.enterAccuracyTestMode(cooldown: 1)
        guard state.phase == .starting else {
            await runtime.leaveAccuracyTestMode(lease)
            return
        }
        accuracyLease = lease
        runtime.setAudioTap { samples, rate in capture.append(samples, sampleRate: rate) }
        recordingAttached = true
        set(.calibrating)
        let interval = tickInterval, clock = self.clock
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                do { try await clock.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Stops whatever is going on and lets go of the microphone tap and the detection test mode. Anything installed stays.
    public func cancel() async {
        switch state.phase {
        case .installed, .cancelled, .failed:
            // (A lesson that failed gave back detection's test mode in the background; whoever cancels it can count on that being done.)
            await leaving?.value
            return
        // A changeover is not interrupted halfway: it ends by itself within seconds, with the new profile in use or the old one back.
        case .installing: return
        default: break
        }
        loop?.cancel()
        learnTask?.cancel()
        recordings = nil
        accepted = Array(repeating: [], count: script.steps.count)
        set(.cancelled)
        await stopRecording()
    }

    // MARK: Steps

    /// Throws away what was heard in the current step and starts it again.
    public func redoStep() {
        guard state.phase == .recording, let capture else { return }
        accepted[state.stepIndex] = []
        cursor = capture.frameCount
        beginStep(state.stepIndex)
    }

    /// Goes on to the next step without waiting for the rest of this one, if it has enough.
    public func finishStep() {
        guard state.phase == .recording, state.canFinishStep, !state.stepComplete else { return }
        state.stepComplete = true
        holdTicks = Self.holdAfterStepTicks
        publish()
    }

    // MARK: Learning

    /// Hands the recordings to the engine. Takes minutes; ``stateUpdates()`` reports the progress.
    public func startLearning() {
        guard state.phase == .readyToLearn, let recordings else { return }
        state.learning = VoiceTrainingProgress(message: "Getting ready…", fraction: 0)
        set(.learning)
        let trainer = self.trainer, environment = self.environment
        learnTask = Task { [weak self] in
            guard let lesson = self else { return }
            do {
                let report = try await trainer.learn(recordings, await environment()) { progress in
                    Task { await lesson.noteProgress(progress) }
                }
                await lesson.learned(report)
            } catch let error as VoiceTrainingError {
                await lesson.learningEnded(error)
            } catch is CancellationError {
                await lesson.learningEnded(.cancelled)
            } catch {
                await lesson.learningEnded(.failed(error.localizedDescription))
            }
        }
    }

    private func noteProgress(_ progress: VoiceTrainingProgress) {
        guard state.phase == .learning else { return }
        let fraction = max(progress.fraction, state.learning?.fraction ?? 0)
        state.learning = VoiceTrainingProgress(message: progress.message, fraction: fraction)
        publish()
    }

    private static let logger = Logger(subsystem: "com.alejandro.friday", category: "voice-lesson")

    private func learned(_ report: VoiceTrainingReport) {
        guard state.phase == .learning else { return }
        // No audio, no words: only what was found, so a lesson that installed nothing can be understood afterwards.
        let verdict: String
        switch report.verdict {
        case .improved: verdict = "improved"
        case .notImproved(let reason): verdict = "not improved — " + reason
        case .notEnoughSpeech(let reason): verdict = "not enough speech — " + reason
        }
        Self.logger.info("lesson learned: \(verdict, privacy: .public); held back \(report.heardBefore, privacy: .public)→\(report.heardAfter, privacy: .public) of \(report.heldBack, privacy: .public); all \(report.totalHeardBefore, privacy: .public)→\(report.totalHeardAfter, privacy: .public) of \(report.total, privacy: .public); false alarms \(report.falseAlarms, privacy: .public) of \(report.silenceChecks, privacy: .public)")
        for note in report.notes.prefix(20) { Self.logger.debug("lesson note: \(note, privacy: .public)") }
        recordings = nil   // the lesson's audio is not needed any more
        state.report = report
        set(.finished)
    }

    private func learningEnded(_ error: VoiceTrainingError) {
        guard state.phase == .learning else { return }
        recordings = nil
        switch error {
        case .cancelled: set(.cancelled)
        case .unavailable(let reason), .failed(let reason):
            Self.logger.error("lesson failed: \(reason, privacy: .public)")
            fail(reason)
        }
    }

    // MARK: Installing

    /// Keeps what was learned and rebuilds the engine with it. If the engine cannot start with it, everything goes back as it was.
    public func install() async {
        guard state.phase == .finished, let report = state.report, report.isImprovement else { return }
        state.notice = nil
        // The app has to be listening: that is how it is known that the engine starts with what was learned. (Nothing is written
        // otherwise, so there is nothing to undo.)
        let listening = await runtime.snapshot().state == .listening
        guard state.phase == .finished else { return }   // cancelled while asking, or installing already
        guard listening else {
            state.notice = "Turn on “Listen for Jarvis” (and check the microphone) first, then press “Use my voice” again."
            publish()
            return
        }
        set(.installing)
        let change: VoiceProfileChange
        do {
            change = try trainer.install(report)
        } catch {
            fail("Couldn’t save what Friday learned: \(error.localizedDescription)")
            return
        }
        profileDidChange()
        switch await reloadEngine() {
        case .loaded:
            state.change = change
            set(.installed)
        case .notListening:
            // Listening stopped while it was being saved, so nothing could be rebuilt yet. The profile was checked with the real engine
            // during the analysis, and the engine is built from it as soon as listening resumes.
            state.change = change
            state.notice = "Friday will use it as soon as it is listening again."
            set(.installed)
        case .failed(let reason):
            await putBack(change, because: reason)
        case nil:
            await putBack(change, because: "it took too long")
        }
    }

    /// The engine could not start with the new profile: the one that was in force before is back (or the engine's own settings), and the
    /// engine is rebuilt from it.
    private func putBack(_ change: VoiceProfileChange, because reason: String) async {
        let outcome = "Friday couldn’t start with what it learned (\(reason))"
        do {
            try trainer.revert(change)
        } catch {
            profileDidChange()
            fail("\(outcome), and the earlier settings couldn’t be put back (\(error.localizedDescription)). Settings ▸ Detection can go back to Friday’s own.")
            return
        }
        profileDidChange()
        switch await reloadEngine() {
        case .loaded, .notListening: fail("\(outcome), so it went back to how it was.")
        case .failed(let again): fail("\(outcome), and it couldn’t start with the earlier settings either (\(again)). Settings ▸ Detection can go back to Friday’s own.")
        case nil: fail("\(outcome), so it went back to how it was. (Friday is slow to restart; check the menu bar.)")
        }
    }

    /// Rebuilds the engine from its files and says how that went; nil if the runtime did not answer within 30 seconds.
    private func reloadEngine() async -> EngineReload? {
        let runtime = self.runtime, clock = self.clock
        return await withTaskGroup(of: EngineReload?.self) { group in
            group.addTask { await runtime.reloadEngine() }
            group.addTask {
                do { try await clock.sleep(for: .seconds(30)) } catch { return nil }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()   // the one still waiting lets go at once: a cancelled reload stops waiting, not rebuilding
            return first
        }
    }

    // MARK: The recording loop

    /// One look at what has been recorded since the last one. Called every `tickInterval`; tests call it by hand.
    func tick() async {
        guard let capture else { return }
        switch state.phase {
        case .calibrating: calibrate(capture)
        case .recording: record(capture)
        default: return
        }
        if state.isRecording {
            state.level = Self.meter(capture.latestLevelDecibels)
            if hintTicks > 0 {
                hintTicks -= 1
                if hintTicks == 0 { state.hint = nil }
            }
            await checkListening(capture)
            publish()
        }
    }

    /// 0…1 for a meter: −70 dBFS and below is nothing, −10 dBFS and above is full.
    static func meter(_ decibels: Float) -> Float {
        min(1, max(0, (decibels + 70) / 60))
    }

    private func calibrate(_ capture: VoiceCapture) {
        let needed = Int(script.calibrationSeconds * Double(UtteranceSplitter.framesPerSecond))
        let frames = capture.frameCount
        state.calibration = needed > 0 ? min(1, Double(frames) / Double(needed)) : 1
        guard frames >= needed else { return }
        let levels = capture.levels()
        if (levels.max() ?? -120) < -100 {
            fail("No sound is reaching Friday from the microphone. Check that it is the one you mean to use and that it isn’t muted.")
            return
        }
        roomFloor = UtteranceSplitter.noiseFloor(of: levels)
        cursor = frames
        if roomFloor > -45 {
            showHint(.noisyRoom, "It’s quite noisy here. A quieter spot will teach Friday more.")
        }
        beginStep(0)
    }

    private func beginStep(_ index: Int) {
        let step = script.steps[index]
        stepStarts[index] = cursor
        quietTicks = 0
        holdTicks = 0
        state.phase = .recording
        state.stepIndex = index
        state.heard = 0
        state.required = step.requiredCount
        state.prompt = step.prompt(after: 0)
        state.stepComplete = false
        state.speechSeconds = 0
        state.canFinishStep = false
        if case .reading(let target, let minimum) = step.kind {
            state.targetSeconds = target
            state.minimumSeconds = minimum
        } else {
            state.targetSeconds = 0
            state.minimumSeconds = 0
        }
    }

    private func record(_ capture: VoiceCapture) {
        let step = script.steps[state.stepIndex]
        if state.stepComplete {
            holdTicks -= 1
            if holdTicks <= 0 { advance(capture) }
            return
        }
        switch step.kind {
        case .phrases(_, let maximumSeconds): listenForPhrases(step, maximumSeconds: maximumSeconds, capture)
        case .reading(let target, let minimum): listenToReading(target: target, minimum: minimum, capture)
        }
    }

    private func listenForPhrases(_ step: VoiceLessonScript.Step, maximumSeconds: Double, _ capture: VoiceCapture) {
        let gap = Int(script.pause * Double(UtteranceSplitter.framesPerSecond))
        var judged = false
        while !state.stepComplete {
            let levels = capture.levels(from: cursor)
            // The first stretch that ended at least a pause ago is a finished phrase.
            guard
                let range = UtteranceSplitter.ranges(levels: levels, floor: roomFloor, pause: script.pause, shortest: script.shortest).first,
                levels.count - range.upperBound > gap
            else { break }
            judged = true
            judge(range.lowerBound + cursor..<range.upperBound + cursor, step: step, maximumSeconds: maximumSeconds, capture)
            cursor += range.upperBound
        }
        if judged {
            quietTicks = 0
        } else {
            let threshold = UtteranceSplitter.threshold(floor: roomFloor)
            if capture.latestLevelDecibels > threshold { quietTicks = 0 } else { quietTicks += 1 }
            if quietTicks == Self.cannotHearAfterTicks {
                showHint(.cannotHear, "I can’t hear you. Speak a little louder or closer to the microphone.")
            }
        }
    }

    private func judge(_ frames: Range<Int>, step: VoiceLessonScript.Step, maximumSeconds: Double, _ capture: VoiceCapture) {
        let seconds = Double(frames.count) / Double(UtteranceSplitter.framesPerSecond)
        let peak = capture.peak(frames: frames)
        if seconds > maximumSeconds {
            showHint(.tooLong, "That was a bit long — say just what’s shown, then stop.")
            return
        }
        if peak < Self.tooQuietPeak {
            showHint(.tooQuiet, "I barely heard that. Speak up a little or move closer.")
            return
        }
        if peak >= Self.clippingPeak {
            showHint(.tooLoud, "That was too loud for the microphone. Back off a little.")
            return
        }
        let before = Int(UtteranceSplitter.marginBefore * Double(UtteranceSplitter.framesPerSecond))
        let after = Int(UtteranceSplitter.marginAfter * Double(UtteranceSplitter.framesPerSecond))
        let samples = capture.samples(frames: max(0, frames.lowerBound - before)..<(frames.upperBound + after))
        accepted[state.stepIndex].append(VoiceRecordings.Utterance(samples: samples, source: step.id))
        state.heard += 1
        state.acceptedCount += 1
        state.hint = nil
        state.prompt = step.prompt(after: state.heard)
        state.canFinishStep = state.heard >= step.minimumCount
        if state.heard >= step.requiredCount {
            state.stepComplete = true
            holdTicks = Self.holdAfterStepTicks
        }
    }

    private func listenToReading(target: Double, minimum: Double, _ capture: VoiceCapture) {
        let threshold = UtteranceSplitter.threshold(floor: roomFloor)
        let voiced = capture.levels(from: cursor).reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        let seconds = Double(voiced) / Double(UtteranceSplitter.framesPerSecond)
        if seconds > state.speechSeconds { quietTicks = 0 } else { quietTicks += 1 }
        state.speechSeconds = seconds
        state.canFinishStep = seconds >= minimum
        if quietTicks == Self.cannotHearAfterTicks, seconds < minimum {
            showHint(.cannotHear, "I can’t hear you. Speak a little louder or closer to the microphone.")
        }
        if seconds >= target {
            state.stepComplete = true
            holdTicks = Self.holdAfterStepTicks
        }
    }

    private func advance(_ capture: VoiceCapture) {
        stepEnds[state.stepIndex] = capture.frameCount
        let next = state.stepIndex + 1
        if next < script.steps.count {
            beginStep(next)
        } else {
            finishRecording(capture)
        }
    }

    private func finishRecording(_ capture: VoiceCapture) {
        // The reading is the last step: its audio, from where it began to now, is what ordinary talk sounds like.
        var talk: [[Float]] = []
        var utterances: [VoiceRecordings.Utterance] = []
        for (index, step) in script.steps.enumerated() {
            if step.isReading {
                let window = 20 * UtteranceSplitter.framesPerSecond
                let end = index == script.steps.count - 1 ? capture.frameCount : stepEnds[index]
                var start = stepStarts[index]
                while start < end {
                    let clip = capture.samples(frames: start..<min(end, start + window))
                    if clip.count >= VoiceCapture.sampleRate { talk.append(clip) }
                    start += window
                }
            } else {
                utterances.append(contentsOf: accepted[index])
            }
        }
        recordings = VoiceRecordings(utterances: utterances, ordinaryTalk: talk)
        accepted = Array(repeating: [], count: script.steps.count)
        loop?.cancel()
        set(.readyToLearn)
        release()
    }

    /// Notices a microphone that went away in the middle of the lesson.
    private func checkListening(_ capture: VoiceCapture) async {
        let frames = capture.frameCount
        if frames == lastFrameCount { stalledTicks += 1 } else { stalledTicks = 0 }
        lastFrameCount = frames
        if capture.isFull {
            fail("That took longer than a lesson should. Please start again.")
            return
        }
        guard stalledTicks == Self.stalledAfterTicks else { return }
        let snapshot = await runtime.snapshot()
        if snapshot.state != .listening || frames == capture.frameCount && stalledTicks >= Self.stalledAfterTicks {
            fail("Friday stopped hearing the microphone. Check that it is connected and try again.")
        }
    }

    // MARK: Plumbing

    private func showHint(_ kind: VoiceLessonState.Hint.Kind, _ message: String) {
        hintSequence += 1
        state.hint = VoiceLessonState.Hint(kind: kind, message: message, sequence: hintSequence)
        hintTicks = Self.hintTicks
    }

    private func set(_ phase: VoiceLessonState.Phase) {
        state.phase = phase
        publish()
    }

    private func fail(_ message: String) {
        loop?.cancel()
        learnTask?.cancel()
        recordings = nil
        accepted = Array(repeating: [], count: script.steps.count)
        set(.failed(message))
        release()
    }

    /// Lets go of the microphone tap *now* (so that a lesson started a moment later cannot have its own tap taken away by this one's
    /// late clean-up), and of detection's test mode and the recorded audio as soon as the runtime has been asked. Idempotent.
    private func release() {
        capture?.close()
        capture = nil
        guard recordingAttached else { return }
        recordingAttached = false
        runtime.setAudioTap(nil)
        guard let lease = accuracyLease else { return }
        accuracyLease = nil
        // Only this lesson's own claim is given back, so it does not matter when this reaches the runtime relative to anything else.
        let runtime = self.runtime, earlier = leaving
        leaving = Task {
            await earlier?.value
            await runtime.leaveAccuracyTestMode(lease)
        }
    }

    /// ``release()`` for callers that can wait until detection is back to normal.
    private func stopRecording() async {
        release()
        await leaving?.value
    }

    private func publish() {
        broadcaster.send(state)
    }
}
