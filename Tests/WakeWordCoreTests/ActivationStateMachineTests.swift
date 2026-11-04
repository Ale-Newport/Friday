import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

struct ActivationStateMachineTests {
    static func wake(_ n: Int = 0) -> WakeWordEvent {
        WakeWordEvent(
            keyword: .jarvis, engineID: "test", confidence: nil, frameSequence: UInt64(n),
            audioEndTime: HostTime(seconds: Double(n)), engineReturnTime: HostTime(seconds: Double(n) + 0.01)
        )
    }

    static func machine(_ state: ActivationState = .listening, holdoff: Double = 1.0) -> ActivationStateMachine {
        ActivationStateMachine(state: state, configuration: .init(postSessionHoldoff: holdoff))
    }

    static let failure = DetectorFailure.microphone(.denied)
    static let engineFailure = DetectorFailure.engine(.processingFailed("x"))

    // MARK: - The documented flow

    @Test func fullActivationCycleFollowsTheSpecifiedDiagram() {
        var machine = Self.machine(.initializing, holdoff: 1.5)
        let event = Self.wake(1)

        #expect(machine.handle(.engineReady) == [])
        #expect(machine.state == .listening)

        #expect(machine.handle(.detection(event)) == [.gateDetector, .runVerifiers(event)])
        #expect(machine.state == .verifying(event))

        #expect(machine.handle(.verificationPassed) == [.dispatchActivation(event)])
        #expect(machine.state == .wakeWordVerified(event))

        let session = ActivationSessionInfo(event: event)
        #expect(machine.handle(.activationDispatched(session)) == [])
        #expect(machine.state == .activated(session))

        #expect(machine.handle(.commandSessionBegan(id: session.id)) == [])
        #expect(machine.state == .commandSession(session))

        #expect(machine.handle(.sessionEnded(id: session.id, outcome: .completed)) == [.ungateDetector(holdoff: 1.5)])
        #expect(machine.state == .listening, "the machine returns to idle by itself")
    }

    @Test func aSessionThatEndsBeforeTheCommandPhaseStillReturnsToIdle() {
        var machine = Self.machine(.activated(ActivationSessionInfo(event: Self.wake())))
        let id = machine.state.session!.id
        #expect(machine.handle(.sessionEnded(id: id, outcome: .completed)) == [.ungateDetector(holdoff: 1.0)])
        #expect(machine.state == .listening)
    }

    @Test func aRejectedVerificationReturnsToListeningWithoutActivating() {
        var machine = Self.machine(.verifying(Self.wake()))
        #expect(machine.handle(.verificationRejected(reason: "not the owner")) == [.ungateDetector(holdoff: 0)])
        #expect(machine.state == .listening)
    }

    // MARK: - No repeated activation

    @Test(arguments: [
        ActivationState.initializing,
        .verifying(ActivationStateMachineTests.wake(1)),
        .wakeWordVerified(ActivationStateMachineTests.wake(1)),
        .activated(ActivationSessionInfo(event: ActivationStateMachineTests.wake(1))),
        .commandSession(ActivationSessionInfo(event: ActivationStateMachineTests.wake(1))),
        .paused(.userDisabled),
        .error(ActivationStateMachineTests.failure),
    ])
    func detectionsAreIgnoredInEveryStateExceptListening(state: ActivationState) {
        var machine = Self.machine(state)
        let intruder = Self.wake(2)
        #expect(machine.handle(.detection(intruder)) == [.recordIgnoredDetection(intruder)])
        #expect(machine.state == state)
    }

    @Test func staleOrForeignSessionEndsAreIgnored() {
        let current = ActivationSessionInfo(event: Self.wake(1))
        var machine = Self.machine(.commandSession(current))
        #expect(machine.handle(.sessionEnded(id: UUID(), outcome: .completed)) == [])
        #expect(machine.state == .commandSession(current))
        #expect(machine.handle(.commandSessionBegan(id: UUID())) == [])
        #expect(machine.state == .commandSession(current))
    }

    @Test func aLateSessionEndAfterAPauseDoesNotResurrectListening() {
        let session = ActivationSessionInfo(event: Self.wake())
        var machine = Self.machine(.commandSession(session))
        machine.handle(.pause(.userDisabled))
        #expect(machine.handle(.sessionEnded(id: session.id, outcome: .completed)) == [])
        #expect(machine.state == .paused(.userDisabled))
    }

    @Test func irrelevantEventsAreNoOps() {
        var machine = Self.machine(.listening)
        #expect(machine.handle(.engineReady) == [])
        #expect(machine.handle(.verificationPassed) == [])
        #expect(machine.handle(.resume) == [])
        #expect(machine.handle(.retry) == [])
        #expect(machine.state == .listening)
    }

    // MARK: - Pausing

    @Test func pausingWhileListeningReleasesTheMicrophoneAndKeepsOrReleasesTheEngine() {
        var disabled = Self.machine(.listening)
        #expect(disabled.handle(.pause(.userDisabled)) == [.releaseCapture, .releaseEngine])
        #expect(disabled.state == .paused(.userDisabled))

        var sleeping = Self.machine(.listening)
        #expect(sleeping.handle(.pause(.systemSleep)) == [.releaseCapture], "sleep keeps the engine loaded")
        #expect(sleeping.state == .paused(.systemSleep))
    }

    @Test func pausingDuringASessionCancelsTheAssistantFirst() {
        let session = ActivationSessionInfo(event: Self.wake())
        for state in [ActivationState.activated(session), .commandSession(session)] {
            var machine = Self.machine(state)
            #expect(machine.handle(.pause(.userDisabled)) == [
                .cancelSession(id: session.id, outcome: .cancelled), .releaseCapture, .releaseEngine,
            ])
        }
    }

    @Test func pausingWhileAlreadyPausedChangesTheReasonAndStillMakesSureTheMicrophoneIsReleased() {
        // In-flight work can reopen the microphone behind a pause, so every pause re-releases it. Releasing
        // twice is harmless; leaving the microphone open while "paused" is not.
        var machine = Self.machine(.paused(.systemSleep))
        #expect(machine.handle(.pause(.userDisabled)) == [.releaseCapture, .releaseEngine])
        #expect(machine.state == .paused(.userDisabled))
        #expect(machine.handle(.pause(.noInputDevice)) == [.releaseCapture])
    }

    @Test func pausingFromAnErrorStateAlsoReleasesTheMicrophone() {
        var machine = Self.machine(.error(Self.failure))
        #expect(machine.handle(.pause(.systemSleep)) == [.releaseCapture])
        #expect(machine.state == .paused(.systemSleep))
    }

    @Test func resumingStartsFromScratch() {
        var machine = Self.machine(.paused(.systemSleep))
        #expect(machine.handle(.resume) == [.acquireResources])
        #expect(machine.state == .initializing)
    }

    // MARK: - Failures

    @Test func failuresMoveToErrorAndReleaseWhatNeedsReleasing() {
        var micFailure = Self.machine(.listening)
        #expect(micFailure.handle(.failure(Self.failure)) == [.releaseCapture])
        #expect(micFailure.state == .error(Self.failure))

        var engineBroken = Self.machine(.listening)
        #expect(engineBroken.handle(.failure(Self.engineFailure)) == [.releaseCapture, .releaseEngine])
    }

    @Test func aFailureDuringASessionCancelsIt() {
        let session = ActivationSessionInfo(event: Self.wake())
        var machine = Self.machine(.commandSession(session))
        #expect(machine.handle(.failure(Self.engineFailure)) == [
            .cancelSession(id: session.id, outcome: .cancelled), .releaseCapture, .releaseEngine,
        ])
    }

    @Test func aFailureArrivingWhilePausedIsIgnored() {
        var machine = Self.machine(.paused(.userDisabled))
        #expect(machine.handle(.failure(Self.failure)) == [])
        #expect(machine.state == .paused(.userDisabled))
    }

    @Test func aLaterFailureReplacesTheDisplayedOne() {
        var machine = Self.machine(.error(Self.failure))
        #expect(machine.handle(.failure(Self.engineFailure)) == [.releaseEngine])
        #expect(machine.state == .error(Self.engineFailure))
    }

    @Test func retryLeavesTheErrorState() {
        var machine = Self.machine(.error(Self.failure))
        #expect(machine.handle(.retry) == [.acquireResources])
        #expect(machine.state == .initializing)
    }

    // MARK: - Accessors

    @Test func stateAccessorsDescribeProgress() {
        let session = ActivationSessionInfo(event: Self.wake())
        #expect(ActivationState.listening.isListening)
        #expect(!ActivationState.listening.isActivationInProgress)
        #expect(ActivationState.verifying(Self.wake()).isActivationInProgress)
        #expect(ActivationState.commandSession(session).isActivationInProgress)
        #expect(ActivationState.commandSession(session).session == session)
        #expect(ActivationState.paused(.userDisabled).session == nil)
    }

    @Test func pauseReasonsKnowWhichOnesUnloadTheEngine() {
        #expect(PauseReason.userDisabled.releasesEngine)
        #expect(!PauseReason.systemSleep.releasesEngine)
        #expect(!PauseReason.noInputDevice.releasesEngine)
        #expect(PauseReason.userDisabled < PauseReason.systemSleep, "user intent outranks system conditions")
    }
}

// MARK: - Model-based fuzzing

/// Throws thousands of random (valid and invalid) events at the machine and checks, after every
/// step, the invariants that make "Jarvis can never activate twice at once" true by construction.
struct ActivationStateMachineInvariantTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func noEventSequenceCanProduceTwoSimultaneousActivations(seed: UInt64) {
        var random = Generator(state: seed)
        var machine = ActivationStateMachine(state: .initializing)
        var liveSessions: Set<UUID> = []      // sessions the assistant has been told about and not yet cancelled/ended
        var knownSessions: [ActivationSessionInfo] = []
        var dispatches = 0

        for step in 0..<20_000 {
            let event = Self.randomEvent(&random, machine: machine, knownSessions: knownSessions, step: step)
            let before = machine.state
            let effects = machine.handle(event)

            for effect in effects {
                switch effect {
                case .dispatchActivation:
                    dispatches += 1
                    #expect(liveSessions.isEmpty, "a second activation was dispatched while one was still live (step \(step))")
                    // The supervisor now creates a session; emulate that by queueing the dispatched event.
                case .cancelSession(let id, _):
                    liveSessions.remove(id)
                default: break
                }
            }
            // Only a session the machine actually adopted is live; ignored (stale) events must not count.
            if case .activationDispatched(let info) = event,
               machine.state.session?.id == info.id, before.session?.id != info.id {
                liveSessions.insert(info.id)
                knownSessions.append(info)
            }
            if case .sessionEnded(let id, _) = event, before.session?.id == id {
                liveSessions.remove(id)
            }

            // Invariants.
            if let session = machine.state.session {
                #expect(liveSessions.contains(session.id), "state shows a session the assistant is not running (step \(step))")
            }
            #expect(liveSessions.count <= 1)
            switch machine.state {
            case .paused, .error, .initializing, .listening:
                #expect(liveSessions.isEmpty, "a session survived into \(machine.state) (step \(step))")
            default: break
            }
        }
        #expect(dispatches > 50, "the fuzzer should reach the activation path often (got \(dispatches))")
    }

    static func randomEvent(
        _ random: inout Generator, machine: ActivationStateMachine, knownSessions: [ActivationSessionInfo], step: Int
    ) -> ActivationEvent {
        let wake = ActivationStateMachineTests.wake(step)
        // Bias towards the interesting path: whatever the machine is waiting for.
        let advance = Int.random(in: 0..<10, using: &random) < 6
        if advance {
            switch machine.state {
            case .initializing: return .engineReady
            case .listening: return .detection(wake)
            case .verifying: return .verificationPassed
            case .wakeWordVerified(let event): return .activationDispatched(ActivationSessionInfo(event: event))
            case .activated(let session): return .commandSessionBegan(id: session.id)
            case .commandSession(let session): return .sessionEnded(id: session.id, outcome: .completed)
            case .paused: return .resume
            case .error: return .retry
            }
        }
        switch Int.random(in: 0..<10, using: &random) {
        case 0: return .detection(wake)
        case 1: return .pause([PauseReason.userDisabled, .systemSleep, .noInputDevice].randomElement(using: &random)!)
        case 2: return .failure(ActivationStateMachineTests.failure)
        case 3: return .failure(ActivationStateMachineTests.engineFailure)
        case 4: return .verificationRejected(reason: "no")
        case 5: return .sessionEnded(id: knownSessions.randomElement(using: &random)?.id ?? UUID(), outcome: .timedOut)
        case 6: return .commandSessionBegan(id: knownSessions.randomElement(using: &random)?.id ?? UUID())
        case 7: return .resume
        case 8: return .activationDispatched(ActivationSessionInfo(event: wake))
        default: return .retry
        }
    }
}
