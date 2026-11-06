import Foundation
import FridayAudio
import WakeWordKit

/// Turns a ``RuntimeSnapshot`` into what the user sees: one headline, one line of detail, a symbol,
/// a tone and (when something is wrong) the single most useful action. Kept free of UI frameworks
/// so it is unit-tested and so no view ever has to know about engines, errors or pause reasons.
public struct StatusPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Working as intended.
        case active
        /// Briefly busy (starting up, assistant at work).
        case busy
        /// Intentionally or temporarily not listening.
        case idle
        /// Needs the user.
        case attention
    }

    /// What the primary button should do when the state needs the user.
    public enum Action: Equatable, Sendable {
        case none
        case openMicrophoneSettings
        case requestMicrophoneAccess
        case editEngineSettings
        case retry
        case enable
    }

    public var title: String
    public var detail: String
    /// An SF Symbol name.
    public var symbol: String
    public var tone: Tone
    public var action: Action
    public var actionTitle: String?
    /// Whether the microphone is open and being analysed right now.
    public var isMicrophoneOpen: Bool

    public init(_ snapshot: RuntimeSnapshot) {
        let engine = snapshot.engine?.displayName
        let device = snapshot.capture?.deviceName
        switch snapshot.state {
        case .initializing:
            if snapshot.microphone == .notDetermined {
                self.init(
                    "Waiting for microphone access", "Choose “Allow” in the system prompt so Friday can hear its wake word.",
                    "mic", .busy, mic: false
                )
            } else {
                self.init("Starting…", engine.map { "Loading \($0)" } ?? "Preparing the wake-word engine", "ellipsis", .busy, mic: false)
            }

        case .listening:
            let source = [device, engine].compactMap { $0 }.joined(separator: " · ")
            self.init(
                "Listening for “Jarvis”",
                source.isEmpty ? "The microphone is on and analysed on this Mac." : source,
                "waveform", .active, mic: true
            )

        case .verifying, .wakeWordVerified:
            self.init("Friday heard you", "Checking…", "waveform.circle.fill", .busy, mic: true)

        case .activated:
            self.init("Friday activated", snapshot.assistantPhase?.displayText ?? "Here", "waveform.circle.fill", .busy, mic: true)

        case .commandSession:
            self.init("Friday is working", snapshot.assistantPhase?.displayText ?? "Listening for your request…", "waveform.circle.fill", .busy, mic: true)

        case .paused(let reason):
            switch reason {
            case .userDisabled:
                self.init("Wake word is off", "Friday isn’t listening. The microphone is closed.", "mic.slash", .idle, mic: false, action: .enable, actionTitle: "Turn On")
            case .systemSleep:
                self.init("Paused while your Mac sleeps", "Listening resumes automatically when it wakes.", "moon.zzz", .idle, mic: false)
            case .userSessionInactive:
                self.init("Paused — another user is active", "Listening resumes when you switch back.", "person.2", .idle, mic: false)
            case .noInputDevice:
                self.init("No microphone found", "Connect a microphone and Friday will start listening.", "mic.slash", .attention, mic: false)
            }

        case .error(let failure):
            switch failure.kind {
            case .microphonePermission(let status):
                let needsPrompt = status == .notDetermined
                self.init(
                    "Microphone access needed", failure.message, "mic.slash", .attention, mic: false,
                    action: needsPrompt ? .requestMicrophoneAccess : .openMicrophoneSettings,
                    actionTitle: needsPrompt ? "Allow Microphone" : "Open Privacy Settings"
                )
            case .engine(.licenceCheckFailed):
                // The key may be fine — the licence server can be slow or down — so the first thing to offer is another try.
                self.init(
                    "Can’t verify the licence", failure.message, "exclamationmark.triangle", .attention, mic: false,
                    action: .retry, actionTitle: "Try Again"
                )
            case .engine(let error) where error.isCredentialProblem:
                self.init("Setup needed", failure.message, "key", .attention, mic: false, action: .editEngineSettings, actionTitle: "Open Engine Settings")
            case .engine(.engineUnavailable):
                self.init("Engine not installed", failure.message, "exclamationmark.triangle", .attention, mic: false, action: .editEngineSettings, actionTitle: "Open Engine Settings")
            case .engine, .audio:
                let willRetry = snapshot.retryAt != nil
                self.init(
                    "Can’t listen right now", failure.message, "exclamationmark.triangle", .attention, mic: false,
                    action: willRetry ? .none : .retry, actionTitle: willRetry ? nil : "Try Again"
                )
            }
        }
    }

    private init(
        _ title: String, _ detail: String, _ symbol: String, _ tone: Tone, mic: Bool,
        action: Action = .none, actionTitle: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tone = tone
        self.isMicrophoneOpen = mic
        self.action = action
        self.actionTitle = actionTitle
    }
}

/// Microphone permission, as a short label for settings screens.
public extension MicrophoneAuthorization {
    var displayName: String {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        case .restricted: "Restricted by your administrator"
        case .notDetermined: "Not requested yet"
        }
    }
}

/// How sensitivity is described to the user, independent of any engine's native scale.
public enum SensitivityDescription {
    public static func label(for value: Float) -> String {
        switch value {
        case ..<0.25: "Strict"
        case ..<0.45: "Cautious"
        case ..<0.65: "Balanced"
        case ..<0.85: "Responsive"
        default: "Very responsive"
        }
    }

    public static func explanation(for value: Float) -> String {
        switch value {
        case ..<0.45: "Fewer accidental activations, but you may need to say “Jarvis” more clearly or closer to the microphone."
        case ..<0.65: "A good starting point for most voices and rooms."
        default: "Catches quieter or accented “Jarvis”, with more risk of activating on similar-sounding words."
        }
    }
}
