import Foundation
import WakeWordKit

/// A bounded in-memory record of what the runtime has done, for the diagnostics window.
///
/// Contains **no audio and no secrets**: only state names, detection metadata (keyword, engine,
/// timings) and already-redacted error text. It lives in memory only and is gone when the app quits.
public struct DiagnosticsSummary: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case state, detection, suppressed, activation, engine, audio, notice }
        public let id: Int
        public let date: Date
        public let kind: Kind
        public let text: String
    }

    public var startedAt: Date
    public var detectionsAccepted = 0
    public var detectionsSuppressed = 0
    public var detectionsIgnored = 0
    public var activations = 0
    public var verificationRejections = 0
    public var captureRestarts = 0
    public var engineFailures = 0
    public var suppressedByReason: [String: Int] = [:]
    /// End of the audio that completed the keyword → the engine reporting it.
    public var captureToDetection = DurationStatistics()
    /// End of that audio → the assistant being notified.
    public var audioToDispatch = DurationStatistics()
    public var lastEngineLoadSeconds: Double?
    public var entries: [Entry] = []

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }
}

public final class DiagnosticsRecorder: @unchecked Sendable {
    public static let maximumEntries = 300

    private let state: Protected<DiagnosticsSummary>
    private let changes = Broadcaster<Void>()
    private var task: Task<Void, Never>?
    private var nextID = 0
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.state = Protected(DiagnosticsSummary(startedAt: now()))
    }

    deinit { task?.cancel() }

    /// Starts recording the runtime's events. Safe to call once.
    public func attach(to runtime: WakeWordRuntime) async {
        guard task == nil else { return }
        let stream = await runtime.events()
        task = Task { [weak self] in
            for await event in stream { self?.record(event) }
        }
    }

    public func summary() -> DiagnosticsSummary { state.get() }

    /// Fires (with no payload) whenever the summary changed. Coalesce on the receiving side.
    public func changeStream() -> AsyncStream<Void> {
        changes.stream(bufferingPolicy: .bufferingNewest(1))
    }

    public func reset() {
        state.withLock { $0 = DiagnosticsSummary(startedAt: now()) }
        changes.send(())
    }

    func record(_ event: RuntimeEvent) {
        let date = now()
        state.withLock { summary in
            func add(_ kind: DiagnosticsSummary.Entry.Kind, _ text: String) {
                nextID += 1
                summary.entries.append(.init(id: nextID, date: date, kind: kind, text: text))
                if summary.entries.count > Self.maximumEntries {
                    summary.entries.removeFirst(summary.entries.count - Self.maximumEntries)
                }
            }
            switch event {
            case .stateChanged(let from, let to):
                add(.state, "\(Self.label(from)) → \(Self.label(to))")
            case .detectionAccepted(let wake):
                summary.detectionsAccepted += 1
                summary.captureToDetection.record(wake.captureToDetectionLatency)
                let latency = Int((wake.captureToDetectionLatency * 1000).rounded())
                add(.detection, "“\(wake.keyword.displayName)” detected by \(wake.engineID) (\(latency) ms after the audio ended)")
            case .detectionSuppressed(let keyword, let reason, _):
                summary.detectionsSuppressed += 1
                let name = Self.describe(reason)
                summary.suppressedByReason[name, default: 0] += 1
                add(.suppressed, "“\(keyword.displayName)” ignored: \(name)")
            case .detectionIgnored(let wake):
                summary.detectionsIgnored += 1
                add(.suppressed, "“\(wake.keyword.displayName)” ignored: Friday was not listening")
            case .verificationRejected(_, let reason):
                summary.verificationRejections += 1
                add(.suppressed, "Detection rejected by verification: \(reason)")
            case .activationDispatched(_, _, let latency):
                summary.activations += 1
                summary.audioToDispatch.record(latency)
                add(.activation, "Assistant notified (\(Int((latency * 1000).rounded())) ms after the audio ended)")
            case .sessionEnded(_, let outcome):
                add(.activation, "Session ended: \(Self.describe(outcome))")
            case .engineLoaded(let id, let duration):
                summary.lastEngineLoadSeconds = duration
                add(.engine, "Engine “\(id)” ready in \(Int((duration * 1000).rounded())) ms")
            case .engineFailed(let error):
                summary.engineFailures += 1
                add(.engine, "Engine problem: \(error.errorDescription ?? "\(error)")")
            case .captureStarted(let info):
                add(.audio, "Microphone “\(info.deviceName)” opened at \(Int(info.sampleRate)) Hz")
            case .captureStopped:
                summary.captureRestarts += 1
                add(.audio, "Microphone closed")
            case .notice(let text):
                add(.notice, text)
            }
        }
        changes.send(())
    }

    static func label(_ state: ActivationState) -> String {
        switch state {
        case .initializing: "Starting"
        case .listening: "Listening"
        case .verifying: "Verifying"
        case .wakeWordVerified: "Verified"
        case .activated: "Activated"
        case .commandSession: "Assistant working"
        case .paused(let reason): "Paused (\(reason))"
        case .error(let failure): "Error: \(failure.message)"
        }
    }

    static func describe(_ rejection: DetectionValidator.Rejection) -> String {
        switch rejection {
        case .unexpectedKeyword(let id): "other keyword “\(id)”"
        case .lowConfidence: "low confidence"
        case .holdoff: "post-session holdoff"
        case .debounced: "duplicate of the same utterance"
        case .cooldown: "cooldown"
        }
    }

    static func describe(_ outcome: SessionOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .timedOut: "timed out"
        case .failed(let reason): "failed (\(reason))"
        }
    }
}
