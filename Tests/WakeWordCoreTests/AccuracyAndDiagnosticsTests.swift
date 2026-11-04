import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

@Suite(.timeLimit(.minutes(1)))
struct AccuracyTestRunnerTests {
    static let context = AccuracyContext(engineID: "alpha", engineName: "Alpha", sensitivity: 0.5, inputDevice: "Synthetic")

    /// A runner on its own manual clock, so each response window and rest period is stepped explicitly.
    struct Rig {
        let harness: Harness
        let runner: AccuracyTestRunner
        let clock: ManualClock
        let engine: MockWakeWordEngine

        static func make() async throws -> Rig {
            let harness = Harness.make()
            try await harness.startListening()
            let clock = ManualClock()
            let engine = try #require(harness.factory.latest("alpha"))
            return Rig(harness: harness, runner: AccuracyTestRunner(runtime: harness.runtime, clock: clock), clock: clock, engine: engine)
        }

        /// Makes the engine report one detection now and waits until the runner has seen it.
        func say() async throws {
            // Audio time must advance between utterances, as it does with a real microphone, or the
            // debounce window (which runs on the audio timeline) would rightly merge them.
            harness.capture.push(seconds: 1.0)
            engine.trigger()
            try await harness.feedFrames(1, engine: engine)
            try await Task.sleep(for: .milliseconds(40))   // let the event travel runtime → runner
        }

        func waitFor(_ what: String, _ predicate: @escaping @Sendable (AccuracyProgress) -> Bool) async throws -> AccuracyProgress {
            let stream = await runner.progressUpdates()
            return try await withThrowingTaskGroup(of: AccuracyProgress.self) { group in
                group.addTask {
                    for await progress in stream where predicate(progress) { return progress }
                    throw TimedOut(what: what)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw TimedOut(what: what)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }

        func advance(_ seconds: Double) async throws {
            try await eventually("runner sleeping") { clock.sleeperCount >= 1 }
            clock.advance(by: .milliseconds(Int(seconds * 1000)))
        }
    }

    static func plan(_ trials: [AccuracyTrial]) -> AccuracyPlan {
        AccuracyPlan(id: "t", title: "Test", instructions: "", kind: .prompted(trials), windowSeconds: 3, restSeconds: 1.5, cooldownSeconds: 0.2)
    }

    @Test func twoStartsAtOnceBeginOneRun_andLeaveNoClaimOnDetectionBehind() async throws {
        let rig = try await Rig.make()
        let plan = Self.plan([AccuracyTrial(prompt: "Say Jarvis", expectsDetection: true)])
        async let first: Void = rig.runner.start(plan, conditions: AccuracyConditions(), context: Self.context)
        async let second: Void = rig.runner.start(plan, conditions: AccuracyConditions(), context: Self.context)
        _ = await (first, second)
        #expect(await rig.harness.runtime.accuracyTestClaims == 1, "one run, one claim")

        await rig.runner.stop()
        #expect(await rig.harness.runtime.accuracyTestClaims == 0, "the run gave back what it took")
        await rig.harness.runtime.stop()
    }

    @Test func scoresHitsMissesCorrectRejectionsFalseAcceptsAndUnpromptedDetections() async throws {
        let rig = try await Rig.make()
        let trials = [
            AccuracyTrial(prompt: "Say Jarvis", expectsDetection: true),    // 1: hit
            AccuracyTrial(prompt: "Say Jarvis", expectsDetection: true),    // 2: miss
            AccuracyTrial(prompt: "Say Harvest", expectsDetection: false),  // 3: correct rejection
            AccuracyTrial(prompt: "Say Travis", expectsDetection: false),   // 4: false accept
            AccuracyTrial(prompt: "Say Jarvis", expectsDetection: true),    // 5: hit with a duplicate trigger
        ]
        await rig.runner.start(Self.plan(trials), conditions: AccuracyConditions(), context: Self.context)

        _ = try await rig.waitFor("trial 1") { if case .prompting(_, 1, _) = $0.phase { true } else { false } }
        try await rig.say()
        try await rig.advance(3)                                            // window 1 ends
        _ = try await rig.waitFor("rest 1") { if case .resting(1, _) = $0.phase { true } else { false } }
        try await rig.advance(1.5)

        _ = try await rig.waitFor("trial 2") { if case .prompting(_, 2, _) = $0.phase { true } else { false } }
        try await rig.advance(3)                                            // nobody says it: a miss
        try await rig.advance(1.5)

        _ = try await rig.waitFor("trial 3") { if case .prompting(_, 3, _) = $0.phase { true } else { false } }
        try await rig.advance(3)                                            // decoy ignored
        _ = try await rig.waitFor("rest 3") { if case .resting(3, _) = $0.phase { true } else { false } }
        try await rig.say()                                                 // detection during REST → unprompted
        try await rig.advance(1.5)

        _ = try await rig.waitFor("trial 4") { if case .prompting(_, 4, _) = $0.phase { true } else { false } }
        try await rig.say()                                                 // decoy triggers → false accept
        try await rig.advance(3)
        try await rig.advance(1.5)

        _ = try await rig.waitFor("trial 5") { if case .prompting(_, 5, _) = $0.phase { true } else { false } }
        try await rig.say()
        // Second detection > cooldown (0.2 s) later but inside the same window → a duplicate trigger.
        try await rig.harness.feedFrames(20, engine: rig.engine)
        try await rig.say()
        try await rig.advance(3)
        try await rig.advance(1.5)

        let finished = try await rig.waitFor("finished") { $0.phase == .finished }
        let result = try #require(finished.result)

        #expect(result.completed)
        #expect(result.positiveTrials == 3 && result.hits == 2 && result.misses == 1)
        #expect(result.negativeTrials == 2 && result.correctRejections == 1 && result.falseAccepts == 1)
        #expect(result.unpromptedDetections == 1)
        #expect(result.duplicateDetections == 1)
        #expect(result.falseActivations == 2)
        #expect(abs((result.hitRate ?? 0) - 2.0 / 3.0) < 1e-9)
        #expect(abs((result.rejectionRate ?? 0) - 0.5) < 1e-9)
        #expect(result.responseTimes.count == 2)
        #expect(result.meanDetectionLatencyMs != nil)
        #expect(result.engineID == "alpha" && result.sensitivity == 0.5)

        // The assistant was never activated by a test, and normal operation is restored.
        #expect(rig.harness.assistant.calls.isEmpty)
        try await rig.harness.triggerDetection()
        try await eventually("real activation after the test") { rig.harness.assistant.calls.count == 1 }
        await rig.harness.runtime.stop()
    }

    @Test func aFreeRunCountsEveryDetectionAsAFalseActivation() async throws {
        let rig = try await Rig.make()
        let plan = AccuracyPlan(id: "free", title: "Free", instructions: "", kind: .freeRun(duration: 3600), cooldownSeconds: 0.2)
        await rig.runner.start(plan, conditions: AccuracyConditions(noise: .loud), context: Self.context)
        _ = try await rig.waitFor("free run") { if case .freeRun = $0.phase { true } else { false } }

        try await rig.say()
        try await rig.harness.feedFrames(40, engine: rig.engine)
        try await rig.say()
        for _ in 0..<3600 where await rig.runner.isRunning {   // run the whole hour of manual time
            try await eventually("sleeping") { rig.clock.sleeperCount >= 1 }
            rig.clock.advance(by: .seconds(1))
            await Task.yield()
        }
        let finished = try await rig.waitFor("finished") { $0.phase == .finished }
        let result = try #require(finished.result)
        #expect(result.positiveTrials == 0 && result.negativeTrials == 0)
        #expect(result.unpromptedDetections == 2)
        #expect(result.conditions.noise == .loud)
        await rig.harness.runtime.stop()
    }

    @Test func stoppingEarlyKeepsTheCountsSoFarAndMarksTheRunIncomplete() async throws {
        let rig = try await Rig.make()
        await rig.runner.start(Self.plan((1...5).map { _ in AccuracyTrial(prompt: "Say Jarvis", expectsDetection: true) }),
                               conditions: AccuracyConditions(), context: Self.context)
        _ = try await rig.waitFor("trial 1") { if case .prompting = $0.phase { true } else { false } }
        try await rig.say()
        try await rig.advance(3)
        _ = try await rig.waitFor("rest") { if case .resting = $0.phase { true } else { false } }

        await rig.runner.stop()
        let progress = await rig.runner.currentProgress()
        #expect(progress.phase == .finished)
        let result = try #require(progress.result)
        #expect(!result.completed)
        #expect(result.hits == 1 && result.positiveTrials == 1)
        #expect(await rig.runner.isRunning == false)
        await rig.harness.runtime.stop()
    }

    @Test func aSecondStartWhileRunningIsIgnored() async throws {
        let rig = try await Rig.make()
        await rig.runner.start(Self.plan([AccuracyTrial(prompt: "a", expectsDetection: true)]), conditions: AccuracyConditions(), context: Self.context)
        _ = try await rig.waitFor("running") { if case .prompting = $0.phase { true } else { false } }
        await rig.runner.start(Self.plan([AccuracyTrial(prompt: "b", expectsDetection: true)]), conditions: AccuracyConditions(), context: Self.context)
        let progress = await rig.runner.currentProgress()
        if case .prompting(let prompt, _, _) = progress.phase { #expect(prompt == "a") } else { Issue.record("unexpected phase") }
        await rig.runner.stop()
        await rig.harness.runtime.stop()
    }
}

struct AccuracyResultTests {
    static func result(title: String = "Say “Jarvis” 20 times", hits: Int = 18) -> AccuracyRunResult {
        var result = AccuracyRunResult(
            date: Date(timeIntervalSince1970: 1_800_000_000), title: title,
            conditions: AccuracyConditions(distance: .room, noise: .moderate, pronunciation: "Spanish accent, \"fast\"", notes: "TV on"),
            engineID: "engine-x", engineName: "Example Engine", sensitivity: 0.65, inputDevice: "MacBook Pro Microphone",
            durationSeconds: 120
        )
        result.positiveTrials = 20
        result.hits = hits
        result.misses = 20 - hits
        result.unpromptedDetections = 1
        result.meanDetectionLatencyMs = 212.5
        return result
    }

    @Test func derivedMetrics() {
        let result = Self.result()
        #expect(result.hitRate == 0.9)
        #expect(result.falseActivations == 1)
        #expect(abs((result.falseActivationsPerHour ?? 0) - 30) < 1e-9)   // 1 in 120 s
        #expect(result.rejectionRate == nil)
    }

    @Test func csvQuotesFieldsAndKeepsColumnsAligned() {
        let csv = AccuracyRunResult.csv([Self.result()])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("date,test,engine,sensitivity"))
        #expect(lines[1].contains("\"Spanish accent, \"\"fast\"\"\""), "embedded quotes are doubled")
        #expect(lines[1].contains(",0.65,"))
        #expect(lines[1].contains("0.900"))

        // Count columns by parsing quotes.
        func columns(_ line: String) -> Int {
            var count = 1, inQuotes = false
            for character in line {
                if character == "\"" { inQuotes.toggle() } else if character == ",", !inQuotes { count += 1 }
            }
            return count
        }
        #expect(columns(lines[0]) == columns(lines[1]))
    }

    @Test func storePersistsAndClearsResultsWithoutAnyAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString)/results.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AccuracyResultStore(url: url)
        #expect(store.load().isEmpty)
        let first = Self.result(hits: 18)
        try store.append(first)
        try store.append(Self.result(title: "Second", hits: 20))
        let loaded = store.load()
        #expect(loaded.map(\.title) == ["Say “Jarvis” 20 times", "Second"])
        #expect(loaded[0] == first, "a Codable round trip must be lossless")
        try store.clear()
        #expect(store.load().isEmpty)
    }

    @Test func presetsMatchTheTestsTheSpecificationAsksFor() {
        let presets = Dictionary(uniqueKeysWithValues: AccuracyPlan.presets.map { ($0.id, $0) })
        #expect(presets["say-20"]?.trialCount == 20)
        #expect(presets["decoys"]?.trialCount == AccuracyPlan.decoys.count)
        #expect(presets["decoys"].map { if case .prompted(let t) = $0.kind { t.allSatisfy { !$0.expectsDetection } } else { false } } == true)
        if case .freeRun(let seconds)? = presets["speech-120"]?.kind { #expect(seconds == 120) } else { Issue.record("missing free run") }
        #expect(presets["noise-300"] != nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DiagnosticsRecorderTests {
    @Test func countsEventsAndKeepsTheLogBounded() {
        let recorder = DiagnosticsRecorder(now: { Date(timeIntervalSince1970: 0) })
        let wake = ActivationStateMachineTests.wake(1)
        recorder.record(.detectionAccepted(wake))
        recorder.record(.detectionSuppressed(keyword: .jarvis, reason: .cooldown(remaining: 1), at: .zero))
        recorder.record(.detectionSuppressed(keyword: .jarvis, reason: .cooldown(remaining: 1), at: .zero))
        recorder.record(.detectionSuppressed(keyword: .jarvis, reason: .debounced, at: .zero))
        recorder.record(.detectionIgnored(wake))
        recorder.record(.verificationRejected(wake, reason: "no"))
        recorder.record(.activationDispatched(wake, session: UUID(), audioToDispatch: 0.25))
        recorder.record(.engineLoaded(id: "alpha", duration: 0.04))
        recorder.record(.engineFailed(.processingFailed("x")))

        var summary = recorder.summary()
        #expect(summary.detectionsAccepted == 1 && summary.detectionsSuppressed == 3 && summary.detectionsIgnored == 1)
        #expect(summary.suppressedByReason["cooldown"] == 2 && summary.suppressedByReason["duplicate of the same utterance"] == 1)
        #expect(summary.activations == 1 && summary.verificationRejections == 1 && summary.engineFailures == 1)
        #expect(summary.audioToDispatch.count == 1 && abs(summary.audioToDispatch.averageSeconds - 0.25) < 1e-9)
        #expect(summary.lastEngineLoadSeconds == 0.04)

        for _ in 0..<(DiagnosticsRecorder.maximumEntries + 50) { recorder.record(.notice("n")) }
        summary = recorder.summary()
        #expect(summary.entries.count == DiagnosticsRecorder.maximumEntries)
        #expect(summary.entries.map(\.id) == summary.entries.map(\.id).sorted(), "oldest entries are dropped first")

        recorder.reset()
        #expect(recorder.summary().entries.isEmpty && recorder.summary().detectionsAccepted == 0)
    }

    @Test func recordsALiveRuntimeSession() async throws {
        let harness = Harness.make()
        let recorder = DiagnosticsRecorder()
        await recorder.attach(to: harness.runtime)
        try await harness.startListening()
        try await harness.activate()
        try await eventually("activation recorded") { recorder.summary().activations == 1 }
        let summary = recorder.summary()
        #expect(summary.detectionsAccepted == 1)
        #expect(summary.entries.contains { $0.kind == .activation })
        #expect(summary.entries.contains { $0.text.contains("Listening") })
        #expect(summary.captureToDetection.count == 1)
        #expect(summary.lastEngineLoadSeconds != nil)
        await harness.runtime.stop()
    }

    @Test func logEntriesNeverContainSecrets() {
        let recorder = DiagnosticsRecorder()
        let key = CredentialKey(engineID: "e", name: "k")
        recorder.record(.engineFailed(.credentialRejected(key, detail: "AccessKey rejected")))
        let text = recorder.summary().entries.map(\.text).joined()
        #expect(!text.contains("AbCdEf"))   // errors arrive pre-redacted from the engines
        #expect(text.contains("rejected"))
    }
}

struct SettingsStoreTests {
    static func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "jarvis.tests.\(UUID().uuidString)")!)
    }

    @Test func freshInstallsGetSensibleDefaults() {
        let settings = Self.store().load(defaultEngineID: "engine-x")
        #expect(settings == RuntimeSettings(engineID: "engine-x"))
        #expect(settings.isEnabled && settings.sensitivity == 0.5 && settings.input == .systemDefault)
        #expect(settings.cooldown == 2 && settings.sessionAudioPolicy == .gateDetector && !settings.developerMode)
    }

    @Test func settingsRoundTrip() {
        let store = Self.store()
        var settings = RuntimeSettings(engineID: "mock")
        settings.isEnabled = false
        settings.sensitivity = 0.73
        settings.input = .device(uid: "BuiltInMicrophoneDevice")
        settings.cooldown = 3.5
        settings.postSessionHoldoff = 2
        settings.maxSessionDuration = 120
        settings.sessionAudioPolicy = .releaseMicrophone
        settings.developerMode = true
        store.save(settings)
        #expect(store.load(defaultEngineID: "ignored") == settings)

        settings.input = .systemDefault
        store.save(settings)
        #expect(store.load(defaultEngineID: "x").input == .systemDefault, "the stored device is forgotten")
    }

    @Test func storedValuesOutsideTheSupportedRangeAreClamped() {
        let suite = "jarvis.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(9.0, forKey: SettingsStore.Key.sensitivity)
        defaults.set(-4.0, forKey: SettingsStore.Key.cooldown)
        defaults.set(10_000.0, forKey: SettingsStore.Key.maxSessionDuration)
        defaults.set("nonsense", forKey: SettingsStore.Key.sessionAudioPolicy)
        let settings = SettingsStore(defaults: defaults).load(defaultEngineID: "x")
        #expect(settings.sensitivity == 1)
        #expect(settings.cooldown == SettingsStore.cooldownRange.lowerBound)
        #expect(settings.maxSessionDuration == SettingsStore.sessionDurationRange.upperBound)
        #expect(settings.sessionAudioPolicy == .gateDetector)
    }

    @Test func theWelcomeFlagPersistsSeparately() {
        let store = Self.store()
        #expect(!store.hasSeenWelcome)
        store.hasSeenWelcome = true
        #expect(store.hasSeenWelcome)
    }
}
