import Foundation
import FridayCore

/// What the assistant is doing, for the HUD, the menu bar and the chat window.
public enum AssistantPhase: Sendable, Hashable {
    case idle
    case listening(partial: String)
    case thinking
    case acting(String)
    case speaking(String)
    case waiting(String)
    case error(String)

    public var isBusy: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}

/// One line of the transcript shown in the chat window.
public struct TranscriptItem: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable { case user, assistant, system, step }
    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    public var source: String
    public var response: EngineResponse?
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), source: String = "app", response: EngineResponse? = nil, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.source = source
        self.response = response
        self.isStreaming = isStreaming
    }
}

/// A question the user must answer (confirmation, clarification, browser approval).
public struct PendingPrompt: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case confirmation(destructive: Bool), clarification, browserApproval, browserManual }
    public var id: UUID
    public var kind: Kind
    public var question: String
    public var options: [String]
    public var token: String?
    public init(id: UUID = UUID(), kind: Kind, question: String, options: [String] = [], token: String? = nil) {
        self.id = id
        self.kind = kind
        self.question = question
        self.options = options
        self.token = token
    }
}

public struct AssistantSnapshot: Sendable, Hashable {
    public var phase: AssistantPhase = .idle
    public var transcript: [TranscriptItem] = []
    public var pending: PendingPrompt?
    public var inConversation = false
    /// True from the wake word until the voice session ends (phases can be shared with concurrent typed commands).
    public var inVoiceSession = false
    public var currentSteps: [String] = []
    public var browserStatusLine: String?
    public var lastLatency: LatencyReport?
    public var revision = 0
    public init() {}
}

public struct LatencyReport: Sendable, Hashable, Codable {
    public var wakeToListenMs: Int?
    /// Time spent transcribing the audio around the wake word (only with `VoiceSettings.verifyWakeWord`).
    public var wakeVerificationMs: Int?
    public var speechEndToTranscriptMs: Int?
    public var routingMs: Int?
    public var planningMs: Int?
    public var firstTokenMs: Int?
    public var toolsMs: Int?
    public var firstAudioMs: Int?
    public var totalMs: Int?
    public var path: String?
    public var provider: String?
    public var model: String?
    public init() {}
}
