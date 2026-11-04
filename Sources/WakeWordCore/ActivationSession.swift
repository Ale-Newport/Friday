import Foundation
import WakeWordKit

/// What the assistant is doing, for display only (the confirmation HUD shows it). The detector
/// does not interpret it.
public enum AssistantPhase: String, Equatable, Sendable, CaseIterable {
    case listening, thinking, acting, speaking

    public var displayText: String {
        switch self {
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .acting: "Working…"
        case .speaking: "Speaking…"
        }
    }
}

/// How the microphone is handled while the assistant works.
public enum SessionAudioPolicy: String, Equatable, Sendable, CaseIterable {
    /// Keep the capture running but discard its audio before it reaches the engine. Fastest to
    /// resume; the assistant can share the open microphone.
    case gateDetector
    /// Close the microphone for the duration of the session and reopen it afterwards. For
    /// assistants that need exclusive use of the input device.
    case releaseMicrophone
}

/// The assistant's handle on one interaction. Everything here is fire-and-forget and safe to call
/// from any thread; calls are applied in order.
public final class ActivationSession: Sendable {
    enum Command: Sendable {
        case beginCommand(UUID)
        case setPhase(UUID, AssistantPhase)
        case finish(UUID, SessionOutcome)
    }

    public let info: ActivationSessionInfo
    private let send: @Sendable (Command) -> Void

    init(info: ActivationSessionInfo, send: @escaping @Sendable (Command) -> Void) {
        self.info = info
        self.send = send
    }

    public var id: UUID { info.id }
    public var event: WakeWordEvent { info.event }

    /// The assistant has started working on the command (state: *activated* → *command session*).
    /// Optional: returning from the handler ends the session either way.
    public func beginCommand() { send(.beginCommand(id)) }

    /// Reports progress for the confirmation UI.
    public func setPhase(_ phase: AssistantPhase) { send(.setPhase(id, phase)) }

    /// Ends the interaction early (the handler returning does the same with `.completed`). The
    /// detector resumes after the post-session holdoff.
    public func finish(_ outcome: SessionOutcome = .completed) { send(.finish(id, outcome)) }
}

/// **The integration point for the Jarvis assistant.**
///
/// The runtime calls `onWakeWordDetected` exactly once per accepted wake word, on a background
/// task. Until the call returns (or `session.finish()` is called, or the maximum session duration
/// elapses) the wake-word detector is gated, so the assistant's own synthesised speech can never
/// retrigger it, and no second activation can start.
///
/// A typical implementation:
///
///     func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {
///         session.beginCommand()
///         session.setPhase(.listening)
///         let command = await speechToText.listen()          // your STT
///         session.setPhase(.thinking)
///         let reply = await llm.respond(to: command)          // your reasoning
///         session.setPhase(.speaking)
///         await tts.speak(reply)                              // your TTS
///     }                                                       // returning ends the session
///
/// The task is cancelled when detection is disabled, the app quits or the session times out;
/// check `Task.isCancelled` in long-running work.
public protocol AssistantActivationHandler: Sendable {
    func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async
}

/// Does nothing. Useful default for tools and tests.
public struct NoopAssistant: AssistantActivationHandler {
    public init() {}
    public func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {}
}
