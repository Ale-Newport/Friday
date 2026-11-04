import Foundation
import FridayCore

/// Everything about listening and speaking. Persisted by the app; read per interaction.
public struct VoiceSettings: Codable, Sendable, Hashable {
    public var wakeWordEnabled = true
    public var wakeWord = "Jarvis"
    /// Keep listening for follow-ups after answering, without the wake word.
    public var conversationMode = true
    public var conversationTimeoutSeconds: Double = 8
    /// Seconds of silence that end an utterance.
    public var endpointSilenceSeconds: Double = 0.8
    /// Give up when nothing is said after the wake word.
    public var noSpeechTimeoutSeconds: Double = 6
    public var maxUtteranceSeconds: Double = 25
    /// `apple` (SpeechAnalyzer) or `whisper` (sidecar, optional).
    public var recognizerID = "apple"
    /// `auto` detects per utterance; otherwise a fixed language.
    public var spokenLanguage: LanguagePreference = .automatic
    public var customVocabulary: [String] = []
    /// `kokoro` or `apple`.
    public var ttsEngineID = "kokoro"
    public var englishVoiceID: String?
    public var spanishVoiceID: String?
    public var speakingRate: Float = 1.0
    public var speakingVolume: Float = 1.0
    public var speakResponses = true
    public var speakTypedResponses = false
    /// Short chime instead of a spoken "Yes?" on activation.
    public var acknowledgementStyle: Acknowledgement = .chime
    public var bargeInEnabled = true
    /// Clear the detector's microphone when Friday speaks so its own voice cannot be heard as a command.
    public var muteWhileSpeaking = true

    public enum Acknowledgement: String, Codable, Sendable, CaseIterable { case chime, spoken, silent }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case wakeWordEnabled, wakeWord, conversationMode, conversationTimeoutSeconds, endpointSilenceSeconds, noSpeechTimeoutSeconds
        case maxUtteranceSeconds, recognizerID, spokenLanguage, customVocabulary, ttsEngineID, englishVoiceID, spanishVoiceID
        case speakingRate, speakingVolume, speakResponses, speakTypedResponses, acknowledgementStyle, bargeInEnabled, muteWhileSpeaking
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceSettings()
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? d.wakeWordEnabled
        wakeWord = try c.decodeIfPresent(String.self, forKey: .wakeWord) ?? d.wakeWord
        conversationMode = try c.decodeIfPresent(Bool.self, forKey: .conversationMode) ?? d.conversationMode
        conversationTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .conversationTimeoutSeconds) ?? d.conversationTimeoutSeconds
        endpointSilenceSeconds = try c.decodeIfPresent(Double.self, forKey: .endpointSilenceSeconds) ?? d.endpointSilenceSeconds
        noSpeechTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .noSpeechTimeoutSeconds) ?? d.noSpeechTimeoutSeconds
        maxUtteranceSeconds = try c.decodeIfPresent(Double.self, forKey: .maxUtteranceSeconds) ?? d.maxUtteranceSeconds
        recognizerID = try c.decodeIfPresent(String.self, forKey: .recognizerID) ?? d.recognizerID
        spokenLanguage = try c.decodeIfPresent(LanguagePreference.self, forKey: .spokenLanguage) ?? d.spokenLanguage
        customVocabulary = try c.decodeIfPresent([String].self, forKey: .customVocabulary) ?? d.customVocabulary
        ttsEngineID = try c.decodeIfPresent(String.self, forKey: .ttsEngineID) ?? d.ttsEngineID
        englishVoiceID = try c.decodeIfPresent(String.self, forKey: .englishVoiceID)
        spanishVoiceID = try c.decodeIfPresent(String.self, forKey: .spanishVoiceID)
        speakingRate = try c.decodeIfPresent(Float.self, forKey: .speakingRate) ?? d.speakingRate
        speakingVolume = try c.decodeIfPresent(Float.self, forKey: .speakingVolume) ?? d.speakingVolume
        speakResponses = try c.decodeIfPresent(Bool.self, forKey: .speakResponses) ?? d.speakResponses
        speakTypedResponses = try c.decodeIfPresent(Bool.self, forKey: .speakTypedResponses) ?? d.speakTypedResponses
        acknowledgementStyle = try c.decodeIfPresent(Acknowledgement.self, forKey: .acknowledgementStyle) ?? d.acknowledgementStyle
        bargeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? d.bargeInEnabled
        muteWhileSpeaking = try c.decodeIfPresent(Bool.self, forKey: .muteWhileSpeaking) ?? d.muteWhileSpeaking
    }
}
