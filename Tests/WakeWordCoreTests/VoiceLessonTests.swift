import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

// MARK: - A trainer that does nothing but say what it was given

final class FakeTrainer: @unchecked Sendable {
    struct State {
        var learned: [VoiceRecordings] = []
        var installed: [VoiceTrainingReport] = []
        var removals = 0
        var reverts: [VoiceProfileChange] = []
        /// What the next install says it kept of the profile that was there.
        var keptPrevious: String?
        /// Sensitivities the analysis was asked to work at.
        var environments: [Float] = []
        var profile: VoiceProfile?
        var report = VoiceTrainingReport(
            verdict: .improved, heldBack: 10, heardBefore: 1, heardAfter: 9, total: 28, totalHeardBefore: 8, totalHeardAfter: 26,
            silenceChecks: 186, falseAlarms: 0, payload: Data("profile".utf8)
        )
        var progress: [VoiceTrainingProgress] = []
        var learnFailure: VoiceTrainingError?
        var installFailure: String?
        /// Wait (until cancelled) instead of answering.
        var hangs = false
    }

    struct Boom: Error, LocalizedError { var errorDescription: String? { "the disk is full" } }

    let state = Protected(State())

    func configure(_ change: (inout State) -> Void) { state.withLock(change) }
    var learned: [VoiceRecordings] { state.get().learned }
    var installed: [VoiceTrainingReport] { state.get().installed }
    var removals: Int { state.get().removals }
    var reverts: [VoiceProfileChange] { state.get().reverts }

    var trainer: VoiceTrainer {
        VoiceTrainer(
            learn: { [state] recordings, environment, progress in
                let script = state.withLock { state -> (progress: [VoiceTrainingProgress], failure: VoiceTrainingError?, hangs: Bool, report: VoiceTrainingReport) in
                    state.learned.append(recordings)
                    state.environments.append(environment.sensitivity)
                    return (state.progress, state.learnFailure, state.hangs, state.report)
                }
                for step in script.progress { progress(step) }
                if script.hangs { try await Task.sleep(for: .seconds(600)) }
                if let failure = script.failure { throw failure }
                return script.report
            },
            install: { [state] report in
                try state.withLock { state in
                    if let failure = state.installFailure { _ = failure; throw Boom() }
                    state.installed.append(report)
                    state.profile = VoiceProfile(summary: "3 ways of saying it")
                    return VoiceProfileChange(keptPrevious: state.keptPrevious)
                }
            },
            revert: { [state] change in
                state.withLock { state in
                    state.reverts.append(change)
                    state.profile = change.keptPrevious.map { _ in VoiceProfile(summary: "the earlier one") }
                }
            },
            currentProfile: { [state] in state.withLock { $0.profile } },
            removeProfile: { [state] in
                state.withLock { state in
                    state.removals += 1
                    state.profile = nil
                }
                return VoiceProfileChange(keptPrevious: "profile.previous")
            }
        )
    }
}

// MARK: - The rig

@MainActor
struct LessonRig {
    let harness: Harness
    let factory: EngineFactory
    let fake: FakeTrainer
    let lesson: VoiceLesson

    /// Three short steps: the name ×3, "hey" ×2, and 3 seconds of talk.
    static let script = VoiceLessonScript(
        steps: [
            .init(id: "jarvis", title: "Say Jarvis", instruction: "", prompts: ["Jarvis"], kind: .phrases(count: 3, maximumSeconds: 3)),
            .init(id: "hey-jarvis", title: "Call it", instruction: "", prompts: ["Hey Jarvis", "Oye Jarvis"], kind: .phrases(count: 2, maximumSeconds: 4)),
            .init(id: "talk", title: "Talk", instruction: "", prompts: ["Read this."], kind: .reading(targetSeconds: 3, minimumSeconds: 2)),
        ],
        calibrationSeconds: 1
    )

    static func make(
        script: VoiceLessonScript = LessonRig.script, factory: EngineFactory = EngineFactory(), engineBehavior: (@Sendable () -> MockWakeWordEngine.Behavior)? = nil
    ) async throws -> LessonRig {
        let descriptor = engineBehavior.map { factory.descriptor(id: "alpha", behavior: $0) } ?? factory.descriptor(id: "alpha")
        let harness = Harness.make(engines: [descriptor], factory: factory)
        let fake = FakeTrainer()
        let lesson = VoiceLesson(
            script: script, runtime: harness.runtime, trainer: fake.trainer, environment: { EngineEnvironment() }, clock: harness.clock
        )
        return LessonRig(harness: harness, factory: factory, fake: fake, lesson: lesson)
    }

    func startListening() async throws { try await harness.startListening() }

    // The room and the voice, as the microphone would deliver them.
    func room(_ seconds: Double, amplitude: Float = 0.001) {
        harness.capture.setSignal(.whiteNoise(amplitude: amplitude))
        harness.capture.push(seconds: seconds)
    }

    func voice(_ seconds: Double, amplitude: Float = 0.2) {
        harness.capture.setSignal(.tone(frequency: 220, amplitude: amplitude))
        harness.capture.push(seconds: seconds)
    }

    /// Says something for `seconds`, then leaves `pause` of quiet, and lets the lesson look.
    func say(_ seconds: Double = 0.7, amplitude: Float = 0.2, pause: Double = 0.9) async {
        voice(seconds, amplitude: amplitude)
        room(pause)
        await lesson.tick()
    }

    /// Calibrates (a second of room) and enters the first step.
    func begin() async {
        await lesson.begin()
        room(1.2)
        await lesson.tick()
    }

    /// Lets the "step done" pause run out.
    func finishHold() async {
        for _ in 0..<10 {
            room(0.1)
            await lesson.tick()
        }
    }

    func state() async -> VoiceLessonState { await lesson.currentState() }

    func stop() async {
        await lesson.cancel()
        await harness.runtime.stop()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VoiceLessonTests {
    // MARK: Starting

    @Test func aLessonNeedsTheAppToBeListening() async throws {
        let rig = try await LessonRig.make()
        await rig.lesson.begin()                       // the runtime was never started
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected a failure"); return }
        #expect(message.contains("listening"), "\(message)")
        await rig.stop()
    }

    @Test func itListensToTheRoomBeforeAskingAnything() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        #expect(await rig.state().phase == .calibrating)
        rig.room(0.5)
        await rig.lesson.tick()
        let half = await rig.state()
        #expect(half.phase == .calibrating && half.calibration > 0.3 && half.calibration < 0.7, "\(half.calibration)")
        rig.room(0.7)
        await rig.lesson.tick()
        let started = await rig.state()
        #expect(started.phase == .recording && started.stepIndex == 0 && started.prompt == "Jarvis" && started.required == 3)
        #expect(started.hint == nil)
        await rig.stop()
    }

    @Test func aNoisyRoomIsMentioned_butDoesNotStopTheLesson() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        rig.room(1.2, amplitude: 0.02)                 // a fan, a street: about −37 dBFS
        await rig.lesson.tick()
        let state = await rig.state()
        #expect(state.phase == .recording && state.hint?.kind == .noisyRoom)
        await rig.stop()
    }

    @Test func aMicrophoneThatDeliversNothingIsReported() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        rig.harness.capture.setSignal(.silence)
        rig.harness.capture.push(seconds: 1.2)
        await rig.lesson.tick()
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected a failure"); return }
        #expect(message.contains("No sound"), "\(message)")
        await rig.stop()
    }

    @Test func listeningToTheRoomForALongTimeIsNotMistakenForADeadMicrophone() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        for _ in 0..<45 {                              // four and a half seconds of looking, 0.8 s of audio: the room is slow to arrive
            rig.room(0.018)
            await rig.lesson.tick()
        }
        #expect(await rig.state().phase == .calibrating, "audio is arriving; it is just not enough yet")
        rig.room(0.4)
        await rig.lesson.tick()
        #expect(await rig.state().phase == .recording)
        await rig.stop()
    }

    @Test func aLessonWithNothingToAskForDoesNotStart() async throws {
        let empty = VoiceLessonScript(steps: [], calibrationSeconds: 1)
        let rig = try await LessonRig.make(script: empty)
        try await rig.startListening()
        await rig.lesson.begin()
        guard case .failed = await rig.state().phase else { Issue.record("expected a failure"); return }
        await rig.stop()
    }

    @Test func aFailedLessonLetsGoOfTheMicrophoneAtOnce_soTheNextOneKeepsItsOwn() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        rig.harness.capture.setSignal(.silence)
        rig.harness.capture.push(seconds: 1.2)
        await rig.lesson.tick()                        // a silent microphone: the first lesson fails
        guard case .failed = await rig.state().phase else { Issue.record("expected a failure"); return }

        // A second lesson on the same runtime, started straight away, is not robbed of its tap by the first one's clean-up.
        let second = VoiceLesson(script: LessonRig.script, runtime: rig.harness.runtime, trainer: rig.fake.trainer, environment: { EngineEnvironment() }, clock: rig.harness.clock)
        await second.begin()
        rig.room(1.2)
        await second.tick()
        #expect(await second.currentState().phase == .recording, "the second lesson hears the room")
        await second.cancel()
        await rig.stop()
    }

    @Test func theTalkIsWhatWasSaidDuringTheReadingAndNothingElse() async throws {
        let script = VoiceLessonScript(
            steps: [
                .init(id: "talk", title: "Talk", instruction: "", prompts: ["Read this."], kind: .reading(targetSeconds: 2, minimumSeconds: 1)),
                .init(id: "jarvis", title: "Say Jarvis", instruction: "", prompts: ["Jarvis"], kind: .phrases(count: 2, maximumSeconds: 3)),
            ],
            calibrationSeconds: 1
        )
        let rig = try await LessonRig.make(script: script)
        try await rig.startListening()
        await rig.begin()
        rig.voice(2.2); rig.room(0.2); await rig.lesson.tick()      // the reading: enough speech
        await rig.finishHold()
        await rig.say(); await rig.say()                            // then two phrases
        await rig.finishHold()
        #expect(await rig.state().phase == .readyToLearn)
        await rig.lesson.startLearning()
        try await eventually("handed over") { rig.fake.learned.count == 1 }
        let recordings = rig.fake.learned[0]
        let talked = Double(recordings.ordinaryTalk.reduce(0) { $0 + $1.count }) / Double(VoiceRecordings.sampleRate)
        #expect(talked > 2 && talked < 3.9, "the reading (and its pause) only, not the room before it nor the two phrases after it: \(talked) s")
        #expect(recordings.utterances.map(\.source) == ["jarvis", "jarvis"])
        await rig.stop()
    }

    @Test func beginningTwiceDoesNothingTheSecondTime() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        await rig.lesson.begin()
        #expect(await rig.state().phase == .calibrating)
        await rig.stop()
    }

    // MARK: Phrases

    @Test func eachPhraseIsCountedWhenThePersonPausesAfterIt() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()

        await rig.say()
        #expect(await rig.state().heard == 1)
        await rig.say()
        let two = await rig.state()
        #expect(two.heard == 2 && two.acceptedCount == 2 && !two.stepComplete)
        await rig.say()
        let three = await rig.state()
        #expect(three.heard == 3 && three.stepComplete, "the step is complete and about to give way")
        await rig.stop()
    }

    @Test func aPhraseIsNotCountedBeforeTheQuietThatEndsIt() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()

        rig.voice(0.7)
        rig.room(0.2)
        await rig.lesson.tick()
        #expect(await rig.state().heard == 0, "still might be going on")
        rig.room(0.4)
        await rig.lesson.tick()
        #expect(await rig.state().heard == 1)
        await rig.stop()
    }

    @Test func aWordLongerThanTheStepAllowsIsNotCounted_andThePersonIsToldWhy() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(4)                               // the step allows 3 s
        let state = await rig.state()
        #expect(state.heard == 0 && state.hint?.kind == .tooLong)
        await rig.say()                                // and the next, right one counts
        #expect(await rig.state().heard == 1)
        await rig.stop()
    }

    @Test func aWhisperIsNotCounted_andThePersonIsToldWhy() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(0.7, amplitude: 0.003)           // above the room, but only just: −53 dBFS
        let state = await rig.state()
        #expect(state.heard == 0 && state.hint?.kind == .tooQuiet, "\(state.heard) \(String(describing: state.hint))")
        await rig.stop()
    }

    @Test func aShoutThatClipsIsNotCounted() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(0.7, amplitude: 1.0)
        let state = await rig.state()
        #expect(state.heard == 0 && state.hint?.kind == .tooLoud)
        await rig.stop()
    }

    @Test func aSoundShorterThanAWordIsNotAPhrase() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(0.1)                             // a cough, a tap on the desk
        let state = await rig.state()
        #expect(state.heard == 0 && state.hint == nil)
        await rig.stop()
    }

    @Test func aHintFadesAfterAWhile() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(4)
        #expect(await rig.state().hint != nil)
        for _ in 0..<35 {
            rig.room(0.1)
            await rig.lesson.tick()
        }
        #expect(await rig.state().hint == nil)
        await rig.stop()
    }

    @Test func silenceForAWhileMakesItAskTheWayHeardIsNotGood() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<105 {
            rig.room(0.1)
            await rig.lesson.tick()
        }
        #expect(await rig.state().hint?.kind == .cannotHear)
        await rig.stop()
    }

    // MARK: Moving through the steps

    @Test func whenAStepIsCompleteTheNextBeginsAfterAShortPause_andTheNextPromptChanges() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<3 { await rig.say() }
        await rig.finishHold()
        let second = await rig.state()
        #expect(second.stepIndex == 1 && second.heard == 0 && second.required == 2 && second.prompt == "Hey Jarvis" && !second.stepComplete)
        await rig.say()
        #expect(await rig.state().prompt == "Oye Jarvis", "the example changes with each phrase")
        await rig.stop()
    }

    @Test func aPhraseSaidDuringThePauseBetweenStepsIsNotLost() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<2 { await rig.say() }
        rig.voice(0.7)                                 // the person already says the last one…
        rig.room(0.9)
        await rig.lesson.tick()                        // …counted, and the step is complete
        #expect(await rig.state().stepComplete)
        rig.voice(0.7)                                 // …and starts the next step's phrase before the screen has changed
        rig.room(0.9)
        await rig.lesson.tick()
        await rig.finishHold()
        let next = await rig.state()
        #expect(next.stepIndex == 1 && next.heard == 1, "it counts for the next step")
        await rig.stop()
    }

    @Test func aStepCanBeDoneAgain() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say(); await rig.say()
        #expect(await rig.state().heard == 2)
        await rig.lesson.redoStep()
        let again = await rig.state()
        #expect(again.heard == 0 && again.prompt == "Jarvis")
        for _ in 0..<3 { await rig.say() }
        await rig.finishHold()
        await rig.say(); await rig.say()
        await rig.finishHold()
        rig.voice(3.5); rig.room(0.2); await rig.lesson.tick(); await rig.finishHold()
        #expect(await rig.state().phase == .readyToLearn)
        await rig.lesson.startLearning()
        try await eventually("learning handed over") { rig.fake.learned.count == 1 }
        #expect(rig.fake.learned[0].utterances.filter { $0.source == "jarvis" }.count == 3, "only the repeat counts, not the two before it")
        await rig.stop()
    }

    @Test func aStepCanBeLeftEarlyOnlyOnceItHasEnough() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say()
        await rig.lesson.finishStep()
        #expect(await rig.state().stepComplete == false, "one of three is too few")
        await rig.say()                                // two of three is enough to go on
        #expect(await rig.state().canFinishStep)
        await rig.lesson.finishStep()
        await rig.finishHold()
        #expect(await rig.state().stepIndex == 1)
        await rig.stop()
    }

    // MARK: Reading

    @Test func theReadingCountsSecondsOfSpeechAndEnds() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<3 { await rig.say() }
        await rig.finishHold()
        for _ in 0..<2 { await rig.say() }
        await rig.finishHold()
        #expect(await rig.state().stepIndex == 2)

        rig.voice(1.0); await rig.lesson.tick()
        let some = await rig.state()
        #expect(abs(some.speechSeconds - 1) < 0.2 && !some.canFinishStep && some.targetSeconds == 3 && some.minimumSeconds == 2)
        rig.voice(1.2); await rig.lesson.tick()
        #expect(await rig.state().canFinishStep, "enough to stop if they want")
        rig.voice(1.0); await rig.lesson.tick()
        #expect(await rig.state().stepComplete)
        await rig.finishHold()
        #expect(await rig.state().phase == .readyToLearn)
        await rig.stop()
    }

    @Test func theRecordingsHandedOverAreWhatWasSaid() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<3 { await rig.say() }
        await rig.finishHold()
        for _ in 0..<2 { await rig.say() }
        await rig.finishHold()
        rig.voice(3.2); rig.room(0.3); await rig.lesson.tick(); await rig.finishHold()
        await rig.lesson.startLearning()
        try await eventually("handed over") { rig.fake.learned.count == 1 }

        let recordings = rig.fake.learned[0]
        #expect(recordings.utterances.map(\.source) == ["jarvis", "jarvis", "jarvis", "hey-jarvis", "hey-jarvis"])
        for utterance in recordings.utterances {
            let seconds = Double(utterance.samples.count) / Double(VoiceRecordings.sampleRate)
            #expect(seconds > 1.0 && seconds < 2.0, "0.7 s of voice with 0.3 s before and 0.4 s after: \(seconds)")
        }
        let talked = Double(recordings.ordinaryTalk.reduce(0) { $0 + $1.count }) / Double(VoiceRecordings.sampleRate)
        #expect(talked > 2 && talked < 9, "the talk itself — 3.2 s of voice and the pauses around it — and not the phrases before it (they would make it 14 s): \(talked) s")
        await rig.stop()
    }

    // MARK: Learning

    private func recordEverything(_ rig: LessonRig) async throws {
        try await rig.startListening()
        await rig.begin()
        for _ in 0..<3 { await rig.say() }
        await rig.finishHold()
        for _ in 0..<2 { await rig.say() }
        await rig.finishHold()
        rig.voice(3.2); rig.room(0.3); await rig.lesson.tick(); await rig.finishHold()
    }

    @Test func learningShowsItsProgress_andEndsWithTheReport() async throws {
        let rig = try await LessonRig.make()
        rig.fake.configure { $0.progress = [.init(message: "Listening", fraction: 0.2), .init(message: "Trying", fraction: 0.6), .init(message: "Back?", fraction: 0.4)] }
        try await recordEverything(rig)
        let updates = await rig.lesson.stateUpdates()
        await rig.lesson.startLearning()

        var fractions: [Double] = []
        var final: VoiceLessonState?
        for await state in updates {
            if let learning = state.learning, state.phase == .learning, fractions.last != learning.fraction { fractions.append(learning.fraction) }
            if state.phase == .finished { final = state; break }
        }
        #expect(fractions == fractions.sorted(), "the bar never goes back: \(fractions)")
        #expect(final?.report?.heardAfter == 9 && final?.report?.isImprovement == true)
        await rig.stop()
    }

    @Test func learningThatFailsSaysSo() async throws {
        let rig = try await LessonRig.make()
        rig.fake.configure { $0.learnFailure = .unavailable("The model files are missing.") }
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("failure") { if case .failed = await rig.state().phase { true } else { false } }
        guard case .failed(let message) = await rig.state().phase else { return }
        #expect(message == "The model files are missing.")
        await rig.stop()
    }

    @Test func learningCanBeCancelled() async throws {
        let rig = try await LessonRig.make()
        rig.fake.configure { $0.hangs = true }
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("learning") { rig.fake.learned.count == 1 }
        await rig.lesson.cancel()
        try await eventually("cancelled") { await rig.state().phase == .cancelled }
        await rig.harness.runtime.stop()
    }

    @Test func learningIsOnlyStartedOnceTheRecordingIsDone() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.startLearning()
        await rig.begin()
        await rig.lesson.startLearning()
        #expect(rig.fake.learned.isEmpty)
        await rig.stop()
    }

    // MARK: Installing

    @Test func installingKeepsTheProfileAndRebuildsTheEngine() async throws {
        let rig = try await LessonRig.make()
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }
        let first = try #require(rig.factory.latest("alpha"))

        await rig.lesson.install()
        #expect(await rig.state().phase == .installed)
        #expect(rig.fake.installed.count == 1 && rig.fake.installed[0].payload == Data("profile".utf8))
        try await eventually("a second engine was built") { rig.factory.engines(id: "alpha").count == 2 && first.isShutDown }
        #expect(rig.harness.capture.isRunning)
        await rig.harness.runtime.stop()
    }

    @Test func aProfileTheEngineCannotLoadIsTakenBack() async throws {
        let builds = Protected(0)
        let rig = try await LessonRig.make(engineBehavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build == 2 { behavior.initializeError = .invalidConfiguration("the pronunciation file cannot be used") }
            return behavior
        })
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        await rig.lesson.install()
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected the install to be refused"); return }
        #expect(message.contains("went back to how it was"), "\(message)")
        #expect(rig.fake.reverts.count == 1 && rig.fake.removals == 0, "the install was undone, not merely switched off")
        try await rig.harness.runtime.waitForState("listening again") { $0 == .listening }
        try await eventually("rebuilt without it") { builds.get() == 3 }
        await rig.harness.runtime.stop()
    }

    @Test func installingNeedsTheAppToBeListening_andWritesNothingUntilItIs() async throws {
        let rig = try await LessonRig.make()
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        var settings = await rig.harness.runtime.snapshot().settings
        settings.isEnabled = false                     // the person switched listening off during the minutes of analysis
        await rig.harness.runtime.apply(settings)
        try await rig.harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }

        await rig.lesson.install()
        let waiting = await rig.state()
        #expect(waiting.phase == .finished, "the offer stands")
        #expect(waiting.notice?.contains("Listen for Jarvis") == true, "\(String(describing: waiting.notice))")
        #expect(rig.fake.installed.isEmpty && rig.fake.reverts.isEmpty && rig.fake.removals == 0, "nothing was written, so nothing needs undoing")

        settings.isEnabled = true
        await rig.harness.runtime.apply(settings)
        try await rig.harness.runtime.waitForState("listening") { $0 == .listening }
        await rig.lesson.install()
        let done = await rig.state()
        #expect(done.phase == .installed && done.notice == nil && rig.fake.installed.count == 1)
        await rig.harness.runtime.stop()
    }

    @Test func ifListeningStopsWhileTheProfileIsBeingSavedTheProfileStays() async throws {
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        let fake = FakeTrainer()
        let runtime = harness.runtime
        let base = fake.trainer
        // Listening is switched off at the very moment the profile is written: nothing can be rebuilt, and nothing is wrong either.
        let pausing = VoiceTrainer(
            learn: base.learn,
            install: { report in
                let change = try base.install(report)
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    var settings = await runtime.snapshot().settings
                    settings.isEnabled = false
                    await runtime.apply(settings)
                    done.signal()
                }
                done.wait()
                return change
            },
            revert: base.revert, currentProfile: base.currentProfile, removeProfile: base.removeProfile
        )
        let lesson = VoiceLesson(script: LessonRig.script, runtime: runtime, trainer: pausing, environment: { EngineEnvironment() }, clock: harness.clock)
        let rig = LessonRig(harness: harness, factory: factory, fake: fake, lesson: lesson)
        try await recordEverything(rig)
        await lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        await lesson.install()
        let state = await rig.state()
        #expect(state.phase == .installed)
        #expect(state.notice?.contains("as soon as it is listening again") == true, "\(String(describing: state.notice))")
        #expect(fake.installed.count == 1 && fake.reverts.isEmpty && fake.removals == 0, "the profile stays")
        await runtime.stop()
    }

    @Test func aChangeoverIsNotInterruptedByCancelling() async throws {
        let builds = Protected(0)
        let rig = try await LessonRig.make(engineBehavior: {
            var behavior = MockWakeWordEngine.Behavior()
            if builds.withLock({ value -> Int in value += 1; return value }) == 2 { behavior.initializeDelay = .milliseconds(400) }
            return behavior
        })
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        let installing = Task { await rig.lesson.install() }
        try await eventually("the changeover to begin") { await rig.state().phase == .installing }
        await rig.lesson.cancel()
        #expect(await rig.state().phase == .installing, "the window closing does not stop it halfway")
        await installing.value
        #expect(await rig.state().phase == .installed, "it finished what it had begun")
        #expect(rig.fake.installed.count == 1 && rig.fake.reverts.isEmpty)
        await rig.harness.runtime.stop()
    }

    @Test func aChangeoverThatTakesTooLongIsUndone() async throws {
        let builds = Protected(0)
        let rig = try await LessonRig.make(engineBehavior: {
            var behavior = MockWakeWordEngine.Behavior()
            if builds.withLock({ value -> Int in value += 1; return value }) == 2 { behavior.initializeDelay = .milliseconds(1_500) }
            return behavior
        })
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        let installing = Task { await rig.lesson.install() }
        try await eventually("the lesson to wait for the engine") { rig.harness.clock.sleeperCount >= 1 && builds.get() == 2 }
        rig.harness.clock.advance(by: .seconds(31))
        await installing.value
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected the changeover to be undone"); return }
        #expect(message.contains("took too long") && message.contains("went back to how it was"), "\(message)")
        #expect(rig.fake.reverts.count == 1)
        try await rig.harness.runtime.waitForState("listening again") { $0 == .listening }
        await rig.harness.runtime.stop()
    }

    @Test func whenTheNewProfileFailsTheEarlierOneIsPutBack() async throws {
        let builds = Protected(0)
        let rig = try await LessonRig.make(engineBehavior: {
            var behavior = MockWakeWordEngine.Behavior()
            if builds.withLock({ value -> Int in value += 1; return value }) == 2 { behavior.initializeError = .invalidConfiguration("the pronunciation file cannot be used") }
            return behavior
        })
        rig.fake.configure { $0.keptPrevious = "jarvis_pronunciations.txt.previous" }   // the person already had a file of their own
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }

        await rig.lesson.install()
        #expect(rig.fake.reverts == [VoiceProfileChange(keptPrevious: "jarvis_pronunciations.txt.previous")], "what undoes the install knows what to restore")
        #expect(rig.fake.removals == 0)
        try await rig.harness.runtime.waitForState("listening again") { $0 == .listening }
        #expect(builds.get() == 3, "and the engine was rebuilt from it")
        await rig.harness.runtime.stop()
    }

    @Test func theAppIsToldWhenTheProfileOnDiskChanges_whateverBecomesOfTheWindow() async throws {
        let changes = Protected(0)
        let builds = Protected(0)
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            if builds.withLock({ value -> Int in value += 1; return value }) == 2 { behavior.initializeError = .invalidConfiguration("no") }
            return behavior
        })], factory: factory)
        let fake = FakeTrainer()
        let lesson = VoiceLesson(
            script: LessonRig.script, runtime: harness.runtime, trainer: fake.trainer, environment: { EngineEnvironment() },
            profileDidChange: { changes.withLock { $0 += 1 } }, clock: harness.clock
        )
        let rig = LessonRig(harness: harness, factory: factory, fake: fake, lesson: lesson)
        try await recordEverything(rig)
        await lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }
        await lesson.install()                         // written (1), failed to load, put back (2)
        #expect(changes.get() == 2)
        await harness.runtime.stop()
    }

    @Test func theAnalysisWorksAtTheSensitivityOfTheMomentItBegins() async throws {
        let sensitivity = Protected<Float>(0.3)
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        let fake = FakeTrainer()
        let lesson = VoiceLesson(
            script: LessonRig.script, runtime: harness.runtime, trainer: fake.trainer,
            environment: { EngineEnvironment(sensitivity: sensitivity.get()) }, clock: harness.clock
        )
        let rig = LessonRig(harness: harness, factory: factory, fake: fake, lesson: lesson)
        try await recordEverything(rig)
        sensitivity.withLock { $0 = 0.9 }              // the slider moved while the person was talking
        await lesson.startLearning()
        try await eventually("handed over") { !fake.state.get().environments.isEmpty }
        #expect(fake.state.get().environments == [0.9])
        await rig.stop()
    }

    @Test func afterAFailureCancellingWaitsUntilDetectionIsBackToNormal() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        rig.harness.capture.setSignal(.silence)
        rig.harness.capture.push(seconds: 1.2)
        await rig.lesson.tick()                        // a silent microphone: the lesson fails, and gives detection back in the background
        guard case .failed = await rig.state().phase else { Issue.record("expected a failure"); return }
        await rig.lesson.cancel()                      // returns only once that is done
        #expect(await rig.harness.runtime.accuracyTestClaims == 0, "detection is back to normal")
        await rig.harness.runtime.simulateWakeWord()
        try await eventually("the assistant is woken") { !rig.harness.assistant.calls.isEmpty }
        await rig.harness.runtime.stop()
    }

    @Test func aProfileThatCouldNotBeSavedIsNotInstalled() async throws {
        let rig = try await LessonRig.make()
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }
        rig.fake.configure { $0.installFailure = "disk" }
        await rig.lesson.install()
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected failure"); return }
        #expect(message.contains("the disk is full"))
        #expect(rig.factory.engines(id: "alpha").count == 1, "the engine was left alone")
        await rig.stop()
    }

    @Test func aResultThatIsNotAnImprovementCannotBeInstalled() async throws {
        let rig = try await LessonRig.make()
        rig.fake.configure { $0.report = VoiceTrainingReport(verdict: .notImproved(reason: "no better")) }
        try await recordEverything(rig)
        await rig.lesson.startLearning()
        try await eventually("finished") { await rig.state().phase == .finished }
        await rig.lesson.install()
        #expect(await rig.state().phase == .finished && rig.fake.installed.isEmpty)
        await rig.stop()
    }

    // MARK: Letting go

    @Test func whileItListensTheNameDoesNotActivateTheAssistant_andAfterwardsItDoes() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.lesson.begin()
        await rig.harness.runtime.simulateWakeWord()
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.harness.assistant.calls.isEmpty, "a lesson must not wake the assistant, however often the name is said")

        await rig.lesson.cancel()
        await rig.harness.runtime.simulateWakeWord()
        try await eventually("the assistant is woken again") { !rig.harness.assistant.calls.isEmpty }
        await rig.harness.runtime.stop()
    }

    @Test func cancellingStopsTheRecording() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        await rig.say()
        await rig.lesson.cancel()
        #expect(await rig.state().phase == .cancelled)
        let before = await rig.state().acceptedCount
        await rig.say()
        #expect(await rig.state().acceptedCount == before)
        await rig.harness.runtime.stop()
    }

    @Test func aMicrophoneThatDisappearsEndsTheLessonInsteadOfWaitingForever() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        await rig.begin()
        rig.harness.capture.simulateInterruption("unplugged")
        for _ in 0..<40 { await rig.lesson.tick() }
        guard case .failed(let message) = await rig.state().phase else { Issue.record("expected a failure"); return }
        #expect(message.contains("stopped hearing"), "\(message)")
        await rig.harness.runtime.stop()
    }

    @Test func theStateStreamFollowsTheLesson() async throws {
        let rig = try await LessonRig.make()
        try await rig.startListening()
        let updates = await rig.lesson.stateUpdates()
        let followed = Task { () -> VoiceLessonState? in
            var last: VoiceLessonState?
            for await state in updates {
                last = state
                if state.heard >= 1 { break }
            }
            return last
        }
        await rig.begin()
        await rig.say()
        let last = await followed.value
        #expect(last?.phase == .recording && last?.heard == 1, "\(String(describing: last))")
        await rig.stop()
    }

    @Test func theMeterMapsDecibelsToZeroToOne() {
        #expect(VoiceLesson.meter(-120) == 0 && VoiceLesson.meter(-70) == 0)
        #expect(VoiceLesson.meter(-40) == 0.5 && VoiceLesson.meter(-10) == 1 && VoiceLesson.meter(0) == 1)
    }

    @Test func theReadingIncludesTheSpanishPhrasesThatTripTheEngine() {
        // "ya había" sounds, to a network that hears English, like the name (docs/TESTING_AND_ACCURACY.md §2, Spanish): the person's own
        // way of saying it is part of what a learned list must stay silent on.
        let reading = VoiceLessonScript.standard.steps.last?.prompts.joined(separator: " ") ?? ""
        #expect(reading.contains("ya había") && reading.contains("ya habían"))
        #expect(!reading.localizedCaseInsensitiveContains("jarvis"))
    }

    @Test func theStandardScriptAsksForWhatTheLearnerNeeds() {
        let script = VoiceLessonScript.standard
        #expect(script.steps.map(\.id) == ["jarvis", "hey-jarvis", "commands", "talk"])
        #expect(script.phraseCount == 28, "enough that a third can be held back and still be 9 or more")
        #expect(script.steps.last?.isReading == true && script.steps.last?.prompts.count == 3)
        #expect(!script.steps.flatMap(\.prompts).contains { $0.localizedCaseInsensitiveContains("jarvis") && script.steps.last!.prompts.contains($0) },
                "the talk never says the name")
        #expect(script.steps[0].minimumCount == 8 && script.steps[2].minimumCount == 4)
        #expect(script.steps[1].prompt(after: 4) == "Oye Jarvis" && script.steps[1].prompt(after: 3) == "Hey Jarvis")
    }
}
