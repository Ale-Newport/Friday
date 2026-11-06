import Foundation
import WakeWordKit

// MARK: - Plans

/// Conditions to record next to a result, so runs can be compared ("quiet / 30 cm / US accent" vs
/// "TV on / 2 m / Spanish accent").
public struct AccuracyConditions: Codable, Equatable, Sendable {
    public enum Distance: String, Codable, CaseIterable, Sendable {
        case near = "Near (≈30 cm)", arm = "Arm’s length (≈1 m)", room = "Across the room (≈3 m)"
    }
    public enum Noise: String, Codable, CaseIterable, Sendable {
        case quiet = "Quiet", moderate = "Background noise or music", loud = "Loud (TV, traffic, crowd)"
    }

    public var distance: Distance
    public var noise: Noise
    /// Free text: "US accent", "Spanish accent, slow", "fast", …
    public var pronunciation: String
    public var notes: String

    public init(distance: Distance = .arm, noise: Noise = .quiet, pronunciation: String = "", notes: String = "") {
        self.distance = distance
        self.noise = noise
        self.pronunciation = pronunciation
        self.notes = notes
    }
}

public struct AccuracyTrial: Codable, Hashable, Sendable {
    public var prompt: String
    /// True: the person says “Jarvis” and a detection is expected. False: a decoy; none is expected.
    public var expectsDetection: Bool

    public init(prompt: String, expectsDetection: Bool) {
        self.prompt = prompt
        self.expectsDetection = expectsDetection
    }
}

/// A scripted accuracy test. No audio is recorded or stored — only counts and timings.
public struct AccuracyPlan: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// One prompt after another; each has a response window followed by a rest period.
        case prompted([AccuracyTrial])
        /// Count every detection over `duration` seconds as a false activation (normal speech, TV,
        /// music, background noise).
        case freeRun(duration: Double)
    }

    public var id: String
    public var title: String
    public var instructions: String
    public var kind: Kind
    /// Seconds each prompted trial listens for a detection.
    public var windowSeconds: Double
    /// Seconds between trials; a detection here counts as unprompted (false).
    public var restSeconds: Double
    /// Cooldown used during the test, short so a person repeating the word quickly is still counted.
    public var cooldownSeconds: Double

    public init(
        id: String, title: String, instructions: String, kind: Kind,
        windowSeconds: Double = 3, restSeconds: Double = 1.5, cooldownSeconds: Double = 1.0
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.kind = kind
        self.windowSeconds = windowSeconds
        self.restSeconds = restSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    public var trialCount: Int {
        if case .prompted(let trials) = kind { trials.count } else { 0 }
    }

    /// Words that sound like “Jarvis”, to measure false accepts.
    public static let decoys = [
        "Harvest", "Travis", "Service", "Jarvik", "Gervais", "Marvis", "Nervous", "Carvis", "Charles", "Jealous",
    ]

    public static let sayJarvis20 = AccuracyPlan(
        id: "say-20", title: "Say “Jarvis” 20 times",
        instructions: "Say “Jarvis” once each time the prompt appears, at your normal speaking volume.",
        kind: .prompted((1...20).map { AccuracyTrial(prompt: "Say “Jarvis” (\($0) of 20)", expectsDetection: true) })
    )

    public static let similarSounds = AccuracyPlan(
        id: "decoys", title: "Similar-sounding words",
        instructions: "Say each word shown. None of them should activate Friday.",
        kind: .prompted(decoys.map { AccuracyTrial(prompt: "Say “\($0)”", expectsDetection: false) })
    )

    public static let mixed = AccuracyPlan(
        id: "mixed", title: "Mixed: Jarvis and decoys",
        instructions: "Say whichever word is shown. “Jarvis” should activate; the others should not.",
        kind: .prompted(
            (0..<24).map { index in
                index % 3 == 2
                    ? AccuracyTrial(prompt: "Say “\(decoys[(index / 3) % decoys.count])”", expectsDetection: false)
                    : AccuracyTrial(prompt: "Say “Jarvis”", expectsDetection: true)
            }
        )
    )

    public static let normalSpeech = AccuracyPlan(
        id: "speech-120", title: "Normal conversation (2 min)",
        instructions: "Talk, read aloud or play a podcast without saying “Jarvis”. Every detection is a false activation.",
        kind: .freeRun(duration: 120)
    )

    public static let backgroundNoise = AccuracyPlan(
        id: "noise-300", title: "Background noise (5 min)",
        instructions: "Play TV, music or noise. Do not say “Jarvis”. Every detection is a false activation.",
        kind: .freeRun(duration: 300)
    )

    public static let presets: [AccuracyPlan] = [.sayJarvis20, .similarSounds, .mixed, .normalSpeech, .backgroundNoise]
}

// MARK: - Results

public struct AccuracyRunResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var conditions: AccuracyConditions
    public var engineID: String
    public var engineName: String
    public var sensitivity: Float
    public var inputDevice: String
    public var durationSeconds: Double
    /// False when the run was stopped before every trial finished.
    public var completed: Bool

    public var positiveTrials = 0
    public var hits = 0
    public var misses = 0
    public var negativeTrials = 0
    public var correctRejections = 0
    /// A decoy word activated Jarvis.
    public var falseAccepts = 0
    /// Detections outside any response window (or during a free run).
    public var unpromptedDetections = 0
    /// Extra detections of one spoken word (several activations from a single utterance).
    public var duplicateDetections = 0
    /// Mean delay between the end of the audio and the engine reporting a detection (milliseconds).
    public var meanDetectionLatencyMs: Double?
    /// Seconds from the prompt appearing to the detection, per hit (dominated by human reaction time).
    public var responseTimes: [Double] = []

    /// Fraction of expected detections that happened.
    public var hitRate: Double? { positiveTrials > 0 ? Double(hits) / Double(positiveTrials) : nil }
    /// Decoys that were (correctly) ignored.
    public var rejectionRate: Double? { negativeTrials > 0 ? Double(correctRejections) / Double(negativeTrials) : nil }
    public var falseActivations: Int { falseAccepts + unpromptedDetections }
    public var falseActivationsPerHour: Double? {
        durationSeconds > 0 ? Double(falseActivations) / (durationSeconds / 3600) : nil
    }

    public init(
        id: UUID = UUID(), date: Date, title: String, conditions: AccuracyConditions,
        engineID: String, engineName: String, sensitivity: Float, inputDevice: String,
        durationSeconds: Double = 0, completed: Bool = true
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.conditions = conditions
        self.engineID = engineID
        self.engineName = engineName
        self.sensitivity = sensitivity
        self.inputDevice = inputDevice
        self.durationSeconds = durationSeconds
        self.completed = completed
    }

    public static let csvHeader = [
        "date", "test", "engine", "sensitivity", "input", "distance", "noise", "pronunciation", "notes",
        "duration_s", "completed", "positive_trials", "hits", "misses", "hit_rate",
        "negative_trials", "correct_rejections", "false_accepts", "unprompted", "duplicates",
        "false_activations_per_hour", "mean_detection_latency_ms",
    ].joined(separator: ",")

    public var csvRow: String {
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func number(_ value: Double?, digits: Int = 3) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "" }
        return [
            ISO8601DateFormatter().string(from: date), quote(title), quote(engineID), String(format: "%.2f", sensitivity),
            quote(inputDevice), quote(conditions.distance.rawValue), quote(conditions.noise.rawValue),
            quote(conditions.pronunciation), quote(conditions.notes),
            number(durationSeconds, digits: 1), completed ? "yes" : "no",
            "\(positiveTrials)", "\(hits)", "\(misses)", number(hitRate),
            "\(negativeTrials)", "\(correctRejections)", "\(falseAccepts)", "\(unpromptedDetections)", "\(duplicateDetections)",
            number(falseActivationsPerHour, digits: 2), number(meanDetectionLatencyMs, digits: 1),
        ].joined(separator: ",")
    }

    public static func csv(_ results: [AccuracyRunResult]) -> String {
        ([csvHeader] + results.map(\.csvRow)).joined(separator: "\n") + "\n"
    }
}

// MARK: - Progress

public struct AccuracyProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the person to respond to `prompt`.
        case prompting(prompt: String, trial: Int, of: Int)
        /// Resting between trials.
        case resting(trial: Int, of: Int)
        /// A free run counting false activations.
        case freeRun(secondsRemaining: Double)
        case finished
    }

    public var phase: Phase = .idle
    public var hits = 0
    public var misses = 0
    public var falseActivations = 0
    public var result: AccuracyRunResult?

    public init() {}
}

/// Who and what is being measured, captured when a run starts.
public struct AccuracyContext: Sendable {
    public var engineID: String
    public var engineName: String
    public var sensitivity: Float
    public var inputDevice: String
    public init(engineID: String, engineName: String, sensitivity: Float, inputDevice: String) {
        self.engineID = engineID
        self.engineName = engineName
        self.sensitivity = sensitivity
        self.inputDevice = inputDevice
    }
}

// MARK: - Runner

/// Runs an ``AccuracyPlan`` against a live runtime.
///
/// While a run is active the runtime reports detections without activating the assistant (and with
/// a short cooldown), so a test never opens the HUD or talks to the assistant. Everything is
/// counted; nothing about the audio itself is kept.
public actor AccuracyTestRunner {
    private let runtime: WakeWordRuntime
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let progressBroadcaster = Broadcaster<AccuracyProgress>()

    private var progress = AccuracyProgress()
    private var runTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var testModeLease: AccuracyTestLease?
    /// A run is being set up (this actor can be re-entered while the runtime is asked for the test mode): a second start must not begin another.
    private var isStarting = false

    // Run-scoped counters.
    private var window: WindowState?
    private var result: AccuracyRunResult?
    private var latencies: [Double] = []

    private struct WindowState {
        var windowStart: HostTime
        var detections: Int
        var firstDetectionAt: HostTime?
    }

    public init(runtime: WakeWordRuntime, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runtime = runtime
        self.clock = clock
        self.now = now
    }

    public var isRunning: Bool { runTask != nil || isStarting }

    public func currentProgress() -> AccuracyProgress { progress }

    public func progressUpdates() -> AsyncStream<AccuracyProgress> {
        progressBroadcaster.stream(bufferingPolicy: .bufferingNewest(1), initial: progress)
    }

    /// Begins `plan`. Does nothing if a run is already active.
    public func start(_ plan: AccuracyPlan, conditions: AccuracyConditions, context: AccuracyContext) async {
        guard runTask == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        progress = AccuracyProgress()
        latencies = []
        result = AccuracyRunResult(
            date: now(), title: plan.title, conditions: conditions, engineID: context.engineID,
            engineName: context.engineName, sensitivity: context.sensitivity, inputDevice: context.inputDevice
        )
        testModeLease = await runtime.enterAccuracyTestMode(cooldown: plan.cooldownSeconds)

        let stream = await runtime.events()
        listenerTask = Task { [weak self] in
            for await event in stream {
                if case .detectionAccepted(let wake) = event { await self?.record(wake) }
            }
        }
        runTask = Task { [weak self] in await self?.execute(plan) }
    }

    /// Ends the run early; the partial result is marked incomplete.
    public func stop() async {
        guard let task = runTask else { return }
        task.cancel()
        await task.value
    }

    // MARK: Execution

    private func execute(_ plan: AccuracyPlan) async {
        let started = HostTime.now
        var completed = true

        switch plan.kind {
        case .prompted(let trials):
            for (index, trial) in trials.enumerated() {
                if Task.isCancelled { completed = false; break }
                guard await prompt(trial, number: index + 1, of: trials.count, plan: plan) else { completed = false; break }
            }
        case .freeRun(let duration):
            window = nil
            var remaining = duration
            while remaining > 0 {
                publish(phase: .freeRun(secondsRemaining: remaining))
                let step = min(1, remaining)
                do { try await clock.sleep(for: .seconds(step)) } catch { completed = false; break }
                remaining -= step
            }
        }
        await finish(started: started, completed: completed)
    }

    /// Returns false when cancelled.
    private func prompt(_ trial: AccuracyTrial, number: Int, of total: Int, plan: AccuracyPlan) async -> Bool {
        window = WindowState(windowStart: .now, detections: 0, firstDetectionAt: nil)
        publish(phase: .prompting(prompt: trial.prompt, trial: number, of: total))
        do { try await clock.sleep(for: .seconds(plan.windowSeconds)) } catch { window = nil; return false }

        let state = window ?? WindowState(windowStart: .now, detections: 0, firstDetectionAt: nil)
        window = nil
        if trial.expectsDetection {
            result?.positiveTrials += 1
            if state.detections > 0 {
                result?.hits += 1
                result?.duplicateDetections += state.detections - 1
                if let first = state.firstDetectionAt { result?.responseTimes.append(first.seconds(since: state.windowStart)) }
            } else {
                result?.misses += 1
            }
        } else {
            result?.negativeTrials += 1
            if state.detections > 0 {
                result?.falseAccepts += 1
                result?.duplicateDetections += state.detections - 1
            } else {
                result?.correctRejections += 1
            }
        }
        publishCounters()

        publish(phase: .resting(trial: number, of: total))
        do { try await clock.sleep(for: .seconds(plan.restSeconds)) } catch { return false }
        return true
    }

    private func finish(started: HostTime, completed: Bool) async {
        if let lease = testModeLease {
            testModeLease = nil
            await runtime.leaveAccuracyTestMode(lease)
        }
        listenerTask?.cancel()
        listenerTask = nil
        window = nil
        if var finished = result {
            finished.durationSeconds = HostTime.now.seconds(since: started)
            finished.completed = completed
            finished.meanDetectionLatencyMs = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count) * 1000
            result = finished
            progress.result = finished
        }
        progress.phase = .finished
        progressBroadcaster.send(progress)
        runTask = nil
    }

    // MARK: Detections

    private func record(_ wake: WakeWordEvent) {
        latencies.append(wake.captureToDetectionLatency)
        if var state = window {
            state.detections += 1
            if state.firstDetectionAt == nil { state.firstDetectionAt = .now }
            window = state
            return
        }
        // Outside any response window: nobody was supposed to say it.
        result?.unpromptedDetections += 1
        publishCounters()
    }

    private func publishCounters() {
        progress.hits = result?.hits ?? 0
        progress.misses = result?.misses ?? 0
        progress.falseActivations = (result?.falseAccepts ?? 0) + (result?.unpromptedDetections ?? 0)
        progressBroadcaster.send(progress)
    }

    private func publish(phase: AccuracyProgress.Phase) {
        progress.phase = phase
        progressBroadcaster.send(progress)
    }
}

// MARK: - Storage

/// Persists accuracy results as JSON in Application Support. No audio is ever involved.
public final class AccuracyResultStore: @unchecked Sendable {
    private let url: URL
    private let lock = UnfairLock()

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(appName: String = "Friday") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("accuracy-results.json")
    }

    public func load() -> [AccuracyRunResult] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AccuracyRunResult].self, from: data)) ?? []
        }
    }

    public func append(_ result: AccuracyRunResult) throws {
        try lock.withLock {
            var all = loadUnlocked()
            all.append(result)
            try write(all)
        }
    }

    public func clear() throws {
        try lock.withLock { try write([]) }
    }

    private func loadUnlocked() -> [AccuracyRunResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AccuracyRunResult].self, from: data)) ?? []
    }

    private func write(_ results: [AccuracyRunResult]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: url, options: .atomic)
    }
}
