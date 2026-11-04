import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// Hammers the verification race (first of {verdict, deadline} wins) with verifiers that answer before, around and
/// after a 5 ms deadline, ignore cancellation, or throw cancellation away — on the real clock. Whatever the timing,
/// every detection gets exactly one verdict, the detector is never left gated (deaf) afterwards, and
/// accepted = rejected + dispatched. (Found by an independent reviewer; more rounds: `STRESS_ROUNDS=1500`.)
struct StressVerifier: DetectionVerifier {
    var requiredPreRoll: Double { 0 }
    func verify(_ context: VerificationContext) async -> VerificationDecision {
        switch Int(context.event.frameSequence % 7) {
        case 0: return .accept
        case 1: return .reject(reason: "r1")
        case 2: try? await Task.sleep(for: .milliseconds(2)); return .accept                // swallows cancellation
        case 3:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in        // ignores cancellation, slower than the deadline
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.012) { c.resume() }
            }
            return .accept
        case 4: await Task.yield(); return .reject(reason: "r4")
        case 5: try? await Task.sleep(for: .milliseconds(5)); return .accept                // right at the deadline
        default: try? await Task.sleep(for: .milliseconds(50)); return .reject(reason: "late")
        }
    }
}

@Suite(.timeLimit(.minutes(10)))
struct VerificationRaceStressTests {
    @Test func theVerificationRaceNeverLosesAnOutcomeOrLeavesTheDetectorGated() async throws {
        let factory = EngineFactory()
        var settings = RuntimeSettings(engineID: "alpha")
        settings.cooldown = 0
        settings.debounceWindow = 0
        settings.postSessionHoldoff = 0
        let assistant = RecordingAssistant(.immediate)
        var timings = Harness.fastTimings
        timings.verifierTimeout = .milliseconds(5)
        let capture = SyntheticAudioSource()
        let runtime = WakeWordRuntime(
            settings: settings,
            dependencies: RuntimeDependencies(
                registry: WakeWordEngineRegistry([factory.descriptor(id: "alpha")]), credentials: InMemoryCredentialStore(),
                capture: capture, devices: FakeDevices(), permission: FakePermission(), assistant: assistant,
                verifiers: [StressVerifier()], clock: ContinuousClock(), timings: timings
            )
        )
        let log = await EventLog(runtime)
        await runtime.start()
        try await runtime.waitForState("listening") { $0 == .listening }
        let engine = try #require(factory.latest("alpha"))

        let rounds = Int(ProcessInfo.processInfo.environment["STRESS_ROUNDS"] ?? "150") ?? 150
        for round in 0..<rounds {
            let before = log.acceptedDetections.count
            engine.trigger()
            let deadline = ContinuousClock.now + .seconds(3)
            while log.acceptedDetections.count == before, ContinuousClock.now < deadline {
                capture.push(seconds: 0.1)
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(log.acceptedDetections.count > before, "round \(round): the detection was never accepted")
            // Wait for the verdict and the return to idle.
            do {
                try await runtime.waitForState("idle again (round \(round))", timeout: .seconds(3)) { $0 == .listening }
            } catch {
                let snapshot = await runtime.snapshot()
                Issue.record("round \(round): stuck in \(snapshot.state.label) — \(error)")
                break
            }
            let stats = await runtime.pipelineStatistics()
            if stats.isGated {
                // Idle but gated would be a deaf detector — allow the (instant) ungate to land first.
                try await Task.sleep(for: .milliseconds(20))
                let again = await runtime.pipelineStatistics()
                #expect(!again.isGated, "round \(round): listening, but the detector is still gated")
                if again.isGated { break }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let accepted = log.acceptedDetections.count
        let rejected = log.events.filter { if case .verificationRejected = $0 { true } else { false } }.count
        let dispatched = assistant.calls.count
        #expect(accepted == rejected + dispatched, "accepted \(accepted) = rejected \(rejected) + dispatched \(dispatched)")
        await runtime.stop()
    }
}
