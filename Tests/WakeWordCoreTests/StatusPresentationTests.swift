import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

struct StatusPresentationTests {
    static func snapshot(
        _ state: ActivationState,
        microphone: MicrophoneAuthorization = .authorized,
        engine: String? = "Test Engine",
        device: String? = "MacBook Pro Microphone",
        phase: AssistantPhase? = nil,
        retryAt: Date? = nil
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: state,
            settings: RuntimeSettings(engineID: "test"),
            microphone: microphone,
            engine: engine.map { ActiveEngine(id: "test", displayName: $0, sensitivity: 0.5) },
            capture: device.map { AudioCaptureInfo(deviceName: $0, deviceUID: nil, sampleRate: 48_000, channelCount: 1) },
            assistantPhase: phase, notice: nil, retryAt: retryAt, revision: 1
        )
    }

    static let session = ActivationSessionInfo(event: ActivationStateMachineTests.wake())

    @Test func listeningNamesTheWakeWordTheMicrophoneAndTheEngine() {
        let presentation = StatusPresentation(Self.snapshot(.listening))
        #expect(presentation.title == "Listening for “Jarvis”")
        #expect(presentation.detail == "MacBook Pro Microphone · Test Engine")
        #expect(presentation.tone == .active && presentation.isMicrophoneOpen)
        #expect(presentation.action == .none)
    }

    @Test func startupExplainsThePermissionPromptWhenThatIsWhatWeAreWaitingFor() {
        let waiting = StatusPresentation(Self.snapshot(.initializing, microphone: .notDetermined, engine: nil, device: nil))
        #expect(waiting.title == "Waiting for microphone access")
        #expect(!waiting.isMicrophoneOpen)
        let loading = StatusPresentation(Self.snapshot(.initializing, engine: "Test Engine", device: nil))
        #expect(loading.title == "Starting…" && loading.detail == "Loading Test Engine")
    }

    @Test func activationStatesShowTheAssistantsPhase() {
        let activated = StatusPresentation(Self.snapshot(.activated(Self.session)))
        #expect(activated.title == "Friday activated" && activated.tone == .busy)
        let thinking = StatusPresentation(Self.snapshot(.commandSession(Self.session), phase: .thinking))
        #expect(thinking.title == "Friday is working" && thinking.detail == "Thinking…")
    }

    @Test func eachPauseReasonHasItsOwnExplanationAndOnlyUserDisabledOffersAButton() {
        func presentation(_ reason: PauseReason) -> StatusPresentation { StatusPresentation(Self.snapshot(.paused(reason), device: nil)) }
        #expect(presentation(.userDisabled).title == "Wake word is off")
        #expect(presentation(.userDisabled).action == .enable)
        #expect(presentation(.systemSleep).title.contains("sleeps"))
        #expect(presentation(.userSessionInactive).title.contains("another user"))
        #expect(presentation(.noInputDevice).tone == .attention)
        for reason in [PauseReason.systemSleep, .userSessionInactive, .noInputDevice] {
            #expect(presentation(reason).action == .none)
        }
        for reason in [PauseReason.userDisabled, .systemSleep, .userSessionInactive, .noInputDevice] {
            #expect(!presentation(reason).isMicrophoneOpen, "the microphone is closed in every paused state")
        }
    }

    @Test func permissionProblemsPointToTheRightPlace() {
        let denied = StatusPresentation(Self.snapshot(.error(.microphone(.denied)), microphone: .denied))
        #expect(denied.title == "Microphone access needed")
        #expect(denied.action == .openMicrophoneSettings)
        let undetermined = StatusPresentation(Self.snapshot(.error(.microphone(.notDetermined)), microphone: .notDetermined))
        #expect(undetermined.action == .requestMicrophoneAccess)
    }

    @Test func credentialProblemsOpenEngineSettingsWithoutNamingAnyEngine() {
        let key = CredentialKey(engineID: "e", name: "k")
        for error in [WakeWordError.credentialMissing(key), .credentialRejected(key, detail: "bad"), .licenceLimit("limit")] {
            let presentation = StatusPresentation(Self.snapshot(.error(.engine(error))))
            #expect(presentation.title == "Setup needed")
            #expect(presentation.action == .editEngineSettings)
            #expect(presentation.tone == .attention)
        }
        let missing = StatusPresentation(Self.snapshot(.error(.engine(.engineUnavailable("files missing")))))
        #expect(missing.title == "Engine not installed" && missing.detail.contains("files missing"))
    }

    @Test func transientFailuresOfferRetryOnlyWhenNoAutomaticRetryIsScheduled() {
        let failure = DetectorFailure.audio(.engineFailed("HAL"))
        let scheduled = StatusPresentation(Self.snapshot(.error(failure), retryAt: Date().addingTimeInterval(5)))
        #expect(scheduled.action == .none)
        let manual = StatusPresentation(Self.snapshot(.error(.engine(.internalFailure("x")))))
        #expect(manual.action == .retry && manual.actionTitle == "Try Again")
    }

    @Test func everyStateProducesNonEmptyText() {
        let session = Self.session
        let states: [ActivationState] = [
            .initializing, .listening, .verifying(session.event), .wakeWordVerified(session.event), .activated(session),
            .commandSession(session), .paused(.userDisabled), .paused(.systemSleep), .paused(.userSessionInactive),
            .paused(.noInputDevice), .error(.microphone(.denied)), .error(.engine(.processingFailed("x"))),
        ]
        for state in states {
            let presentation = StatusPresentation(Self.snapshot(state))
            #expect(!presentation.title.isEmpty && !presentation.detail.isEmpty && !presentation.symbol.isEmpty, "\(state.label)")
        }
    }

    @Test func sensitivityIsDescribedInPlainLanguage() {
        #expect(SensitivityDescription.label(for: 0.1) == "Strict")
        #expect(SensitivityDescription.label(for: 0.5) == "Balanced")
        #expect(SensitivityDescription.label(for: 0.95) == "Very responsive")
        #expect(SensitivityDescription.explanation(for: 0.8).contains("accented"))
        let labels = stride(from: Float(0), through: 1, by: 0.05).map(SensitivityDescription.label(for:))
        #expect(Set(labels).count == 5)
    }

    @Test func authorizationNamesAreHumanReadable() {
        #expect(MicrophoneAuthorization.authorized.displayName == "Allowed")
        #expect(MicrophoneAuthorization.denied.displayName == "Not allowed")
    }
}
